#include "CMail.h"
#include <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#include <curl/curl.h>
#include <pthread.h>
#include <string.h>

typedef struct { unsigned char *data; size_t size; } Buffer;
typedef struct { const unsigned char *data; size_t size; size_t offset; } Reader;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static size_t append(char *data, size_t size, size_t count, void *user) {
    Buffer *b = user; size_t n = size * count;
    if (b->size + n > 64 * 1024 * 1024) return 0;
    unsigned char *p = realloc(b->data, b->size + n + 1);
    if (!p) return 0;
    b->data = p; memcpy(b->data + b->size, data, n); b->size += n; b->data[b->size] = 0; return n;
}
static size_t read_upload(char *data, size_t size, size_t count, void *user) {
    Reader *r = user; size_t n = size * count;
    if (n > r->size - r->offset) n = r->size - r->offset;
    memcpy(data, r->data + r->offset, n); r->offset += n; return n;
}
SMResponse sm_request(const char *url, const char *username, const char *password,
 const char *command, const unsigned char *upload, size_t upload_length,
 const char *from, const char * const *recipients, int recipient_count, int starttls, int test_only, int oauth) {
    pthread_once(&once, initialize);
    SMResponse result = {0}; Buffer body = {0}, headers = {0}; Reader reader = {upload, upload_length, 0};
    CURL *c = curl_easy_init(); char err[CURL_ERROR_SIZE] = {0};
    if (!c) { result.code = -1; result.error = strdup("Transport initialization failed"); return result; }
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_USERNAME, username);
    if (oauth) { curl_easy_setopt(c, CURLOPT_XOAUTH2_BEARER, password); curl_easy_setopt(c, CURLOPT_LOGIN_OPTIONS, "AUTH=XOAUTH2"); }
    else curl_easy_setopt(c, CURLOPT_PASSWORD, password);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 90L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_ERRORBUFFER, err);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, append);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &body);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, append);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &headers);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "imap,imaps,smtp,smtps,pop3,pop3s");
    if (starttls) curl_easy_setopt(c, CURLOPT_USE_SSL, CURLUSESSL_ALL);
    if (command && command[0]) curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, command);
    struct curl_slist *list = NULL;
    if (upload) {
        curl_easy_setopt(c, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(c, CURLOPT_READFUNCTION, read_upload);
        curl_easy_setopt(c, CURLOPT_READDATA, &reader);
        curl_easy_setopt(c, CURLOPT_INFILESIZE_LARGE, (curl_off_t)upload_length);
        if (from) curl_easy_setopt(c, CURLOPT_MAIL_FROM, from);
        for (int i = 0; i < recipient_count; i++) list = curl_slist_append(list, recipients[i]);
        if (list) curl_easy_setopt(c, CURLOPT_MAIL_RCPT, list);
    }
    if (test_only) curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    CURLcode code = curl_easy_perform(c);
    result.data = body.data; result.length = body.size; result.headers = (char *)headers.data;
    result.code = (int)code;
    if (code) result.error = strdup(err[0] ? err : curl_easy_strerror(code));
    curl_slist_free_all(list); curl_easy_cleanup(c); return result;
}
void sm_response_free(SMResponse *r) { free(r->data); free(r->headers); free(r->error); memset(r, 0, sizeof(*r)); }

#else
#include <string.h>
SMResponse sm_request(const char *url, const char *username, const char *password, const char *command, const unsigned char *upload, size_t upload_length, const char *from, const char * const *recipients, int recipient_count, int starttls, int test_only, int oauth) { SMResponse response = {0}; response.code = -1; response.error = strdup("Use native mobile transport"); return response; }
void sm_response_free(SMResponse *r) { free(r->data); free(r->headers); free(r->error); memset(r, 0, sizeof(*r)); }
#endif
