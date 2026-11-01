#include "codec.h"
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*variant_from_cstring)(void *, const char *);
static pthread_once_t config_once = PTHREAD_ONCE_INIT;
static enum wb_encoding encoding = WB_AUTO;
static int config_valid = 1;
static _Atomic unsigned long counts[7];

static void parse_mode(const char *value) {
    if (strcmp(value, "auto") == 0) encoding = WB_AUTO;
    else if (strcmp(value, "utf-8") == 0) encoding = WB_UTF8;
    else if (strcmp(value, "windows-1251") == 0) encoding = WB_CP1251;
    else config_valid = 0;
}

static void load_config(void) {
    const char *override = getenv("WINBOX_COMMENT_ENCODING");
    if (override != NULL) {
        parse_mode(override);
    } else {
        Dl_info info;
        char path[PATH_MAX];
        if (dladdr((const void *)&config_once, &info) == 0 || info.dli_fname == NULL) {
            config_valid = 0;
        } else {
            size_t n = strlen(info.dli_fname);
            if (n >= sizeof(path)) config_valid = 0;
            else {
                memcpy(path, info.dli_fname, n + 1);
                char *slash = strrchr(path, '/');
                if (slash == NULL) config_valid = 0;
                else {
                    *slash = '\0';
                    size_t prefix = (size_t)(slash - path);
                    const char suffix[] = "/../Resources/comment-encoding.conf";
                    if (prefix + sizeof(suffix) > sizeof(path)) config_valid = 0;
                    else {
                        memcpy(path + prefix, suffix, sizeof(suffix));
                        FILE *f = fopen(path, "r");
                        if (f == NULL) config_valid = 0;
                        else {
                            char line[64];
                            if (fgets(line, sizeof(line), f) == NULL) config_valid = 0;
                            else {
                                line[strcspn(line, "\r\n")] = '\0';
                                if (strncmp(line, "encoding=", 9) != 0) config_valid = 0;
                                else parse_mode(line + 9);
                            }
                            if (fclose(f) != 0) config_valid = 0;
                        }
                    }
                }
            }
        }
    }
    if (!config_valid) fputs("WinBox comment decoder: invalid encoding configuration\n", stderr);
}

static const char *display_bytes(const char *bytes, char **owned) {
    *owned = NULL;
    (void)pthread_once(&config_once, load_config);
    if (bytes == NULL) bytes = "";
    size_t n = strnlen(bytes, WB_COMMENT_MAX_BYTES + 1);
    enum wb_status status = WB_BAD_INPUT;
    if (!config_valid) goto reject;
    if (n > WB_COMMENT_MAX_BYTES) { status = WB_TOO_LARGE; goto reject; }
    if (encoding != WB_CP1251 && wb_valid_utf8((const unsigned char *)bytes, n)) {
        atomic_fetch_add_explicit(&counts[WB_OK_UTF8], 1, memory_order_relaxed);
        return bytes;
    }
    if (encoding == WB_UTF8) goto reject;
    size_t capacity = 3 * n + 1;
    char *decoded = malloc(capacity);
    if (decoded == NULL) { status = WB_NO_MEMORY; goto reject; }
    size_t written = 0;
    status = wb_decode_comment((const unsigned char *)bytes, n, decoded, capacity,
                               encoding, &written);
    if (status == WB_OK_UTF8 || status == WB_OK_CP1251) {
        atomic_fetch_add_explicit(&counts[status], 1, memory_order_relaxed);
        *owned = decoded;
        return decoded;
    }
    free(decoded);
reject:
    atomic_fetch_add_explicit(&counts[status], 1, memory_order_relaxed);
    return "";
}

__attribute__((visibility("default")))
void *wb_comment_variant_v1(void *result, const char *bytes, variant_from_cstring original) {
    if (result == NULL || original == NULL) return NULL;
    char *owned = NULL;
    const char *decoded = display_bytes(bytes, &owned);
    void *answer = original(result, decoded);
    free(owned);
    return answer;
}

static int is_comment_label(const unsigned char *storage) {
    if (storage == NULL) return 0;
    const char *text = NULL;
    size_t length = 0;
    /* These are the two libc++ string layouts in the pinned universal WinBox build. */
#if defined(__aarch64__)
    if ((storage[23] & 0x80u) != 0) {
        memcpy(&text, storage, sizeof(text));
        memcpy(&length, storage + 8, sizeof(length));
    } else { text = (const char *)storage; length = storage[23]; }
#elif defined(__x86_64__)
    if ((storage[0] & 1u) != 0) {
        memcpy(&text, storage + 16, sizeof(text));
        memcpy(&length, storage + 8, sizeof(length));
    } else { text = (const char *)storage + 1; length = (size_t)(storage[0] >> 1); }
#else
#error Unsupported WinBox architecture
#endif
    /* Slot::getFieldInfo supplies this built-in field name to TextWidget. */
    static const char comment_name[] = "Comment";
    return text != NULL && length == sizeof(comment_name)-1 &&
        memcmp(text, comment_name, sizeof(comment_name)-1) == 0;
}

typedef void (*widget_from_cstring)(void *, const char *);
__attribute__((visibility("default")))
void wb_comment_widget_v1(void *widget, const char *bytes, widget_from_cstring original,
                          const unsigned char *label_storage) {
    if (widget == NULL || original == NULL) return;
    if (!is_comment_label(label_storage)) { original(widget, bytes); return; }
    char *owned = NULL;
    const char *decoded = display_bytes(bytes, &owned);
    original(widget, decoded);
    free(owned);
}

__attribute__((visibility("default")))
unsigned long wb_comment_counter_v1(unsigned int status) {
    return status < 7 ? atomic_load_explicit(&counts[status], memory_order_relaxed) : 0;
}
