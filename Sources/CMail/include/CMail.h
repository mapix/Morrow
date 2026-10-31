#ifndef CMAIL_H
#define CMAIL_H
#include <stdlib.h>
#include <stdint.h>
#include <sqlite3.h>
typedef struct { unsigned char *data; size_t length; char *headers; char *error; int code; } SMResponse;
SMResponse sm_request(const char *url, const char *username, const char *password,
 const char *command, const unsigned char *upload, size_t upload_length,
 const char *from, const char * const *recipients, int recipient_count, int starttls, int test_only, int oauth);
void sm_response_free(SMResponse *response);
// Bounded raw DEFLATE for Office ZIP extraction on native mobile.
int sm_inflate_raw(const unsigned char *input, size_t length, unsigned char *output, size_t capacity, size_t *written);
typedef struct SMNativeSocket SMNativeSocket;
SMNativeSocket *sm_native_open(const char *host, int port, int *error);
int sm_native_start_tls(SMNativeSocket *socket, const char *host);
int sm_native_write(SMNativeSocket *socket, const unsigned char *bytes, size_t length);
int sm_native_read(SMNativeSocket *socket, unsigned char *bytes, size_t capacity, size_t *written);
void sm_native_close(SMNativeSocket *socket);
#endif
