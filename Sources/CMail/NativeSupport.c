#include "CMail.h"
#include <zlib.h>
#include <Security/SecureTransport.h>
#include <sys/socket.h>
#include <netdb.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>

int sm_inflate_raw(const unsigned char *input, size_t length, unsigned char *output, size_t capacity, size_t *written) {
    if (length > UINT_MAX || capacity > UINT_MAX) return -1;
    z_stream stream = {0}; stream.next_in = (Bytef *)input; stream.avail_in = (uInt)length;
    stream.next_out = output; stream.avail_out = (uInt)capacity;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -1;
    int status = inflate(&stream, Z_FINISH); *written = stream.total_out;
    inflateEnd(&stream); return status == Z_STREAM_END ? 0 : -1;
}

struct SMNativeSocket { int fd; SSLContextRef tls; short waitFor; };
static int wait_socket(SMNativeSocket *socket, int timeout) { struct pollfd event = {socket->fd, socket->waitFor, 0}; return poll(&event, 1, timeout) > 0 ? 0 : -1; }
static OSStatus socket_read(SSLConnectionRef reference, void *bytes, size_t *length) {
    SMNativeSocket *socket = (SMNativeSocket *)reference;
    size_t requested = *length;
    ssize_t result = recv(socket->fd, bytes, requested, 0);
    if (result > 0) { *length = (size_t)result; socket->waitFor = POLLIN; return *length == requested ? noErr : errSSLWouldBlock; }
    *length = 0;
    if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { socket->waitFor = POLLIN; return errSSLWouldBlock; }
    return result == 0 ? errSSLClosedGraceful : errSSLClosedAbort;
}
static OSStatus socket_write(SSLConnectionRef reference, const void *bytes, size_t *length) {
    SMNativeSocket *socket = (SMNativeSocket *)reference;
    size_t requested = *length;
    ssize_t result = send(socket->fd, bytes, requested, 0);
    if (result >= 0) { *length = (size_t)result; socket->waitFor = POLLOUT; return *length == requested ? noErr : errSSLWouldBlock; }
    *length = 0;
    if (errno == EAGAIN || errno == EWOULDBLOCK) { socket->waitFor = POLLOUT; return errSSLWouldBlock; }
    return errSSLClosedAbort;
}
SMNativeSocket *sm_native_open(const char *host, int port, int *error) {
    *error = -1; if (port < 1 || port > 65535) return NULL;
    struct addrinfo hints = {0}, *addresses = NULL; hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    char service[8]; snprintf(service, sizeof(service), "%d", port);
    if (getaddrinfo(host, service, &hints, &addresses) != 0) return NULL;
    int descriptor = -1;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        descriptor = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (descriptor < 0) continue;
        int flags = fcntl(descriptor, F_GETFL, 0); fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
        int status = connect(descriptor, address->ai_addr, address->ai_addrlen);
        if (status != 0 && errno == EINPROGRESS) {
            struct pollfd event = {descriptor, POLLOUT, 0}; status = poll(&event, 1, 20000);
            int socketError = 0; socklen_t size = sizeof(socketError);
            if (status > 0 && getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 && socketError == 0) status = 0; else status = -1;
        }
        if (status == 0) { fcntl(descriptor, F_SETFL, flags); break; }
        close(descriptor); descriptor = -1;
    }
    freeaddrinfo(addresses); if (descriptor < 0) return NULL;
    struct timeval timeout = {90, 0}; setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)); setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int noSignal = 1; setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    SMNativeSocket *result = calloc(1, sizeof(*result)); if (!result) { close(descriptor); return NULL; }
    result->fd = descriptor; *error = 0; return result;
}
int sm_native_start_tls(SMNativeSocket *socket, const char *host) {
    if (!socket || socket->tls) return -1;
    socket->tls = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
    if (!socket->tls) return -1;
    // SecureTransport keeps certificate-chain verification enabled. Peer domain
    // checking is mandatory; no trust override or plaintext downgrade exists.
    OSStatus result = SSLSetIOFuncs(socket->tls, socket_read, socket_write);
    if (result == noErr) result = SSLSetConnection(socket->tls, socket);
    if (result == noErr) result = SSLSetPeerDomainName(socket->tls, host, strlen(host));
    if (result == noErr) result = SSLSetProtocolVersionMin(socket->tls, kTLSProtocol12);
    if (result == noErr) {
        fcntl(socket->fd, F_SETFL, fcntl(socket->fd, F_GETFL, 0) | O_NONBLOCK);
        do { result = SSLHandshake(socket->tls); if (result == errSSLWouldBlock && wait_socket(socket, 20000) != 0) return -1; } while (result == errSSLWouldBlock);
    }
    return (int)result;
}
int sm_native_write(SMNativeSocket *socket, const unsigned char *bytes, size_t length) {
    while (length) {
        size_t written = 0;
        if (socket->tls) {
            OSStatus status = SSLWrite(socket->tls, bytes, length, &written);
            if (status == errSSLWouldBlock) { if (wait_socket(socket, 90000) != 0) return -1; }
            else if (status != noErr) return (int)status;
            if (!written) continue;
        }
        else { ssize_t count = send(socket->fd, bytes, length, 0); if (count <= 0) return -1; written = (size_t)count; }
        if (!written) return -1; bytes += written; length -= written;
    }
    return 0;
}
int sm_native_read(SMNativeSocket *socket, unsigned char *bytes, size_t capacity, size_t *written) {
    *written = 0;
    if (socket->tls) {
        while (1) {
            OSStatus status = SSLRead(socket->tls, bytes, capacity, written);
            if (*written > 0 && (status == noErr || status == errSSLWouldBlock)) return 0;
            if (status != errSSLWouldBlock) return (int)status;
            if (wait_socket(socket, 90000) != 0) return -1;
        }
    }
    ssize_t result = recv(socket->fd, bytes, capacity, 0); if (result <= 0) return -1; *written = (size_t)result; return 0;
}
void sm_native_close(SMNativeSocket *socket) { if (!socket) return; if (socket->tls) CFRelease(socket->tls); close(socket->fd); free(socket); }
