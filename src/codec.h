#ifndef WB_COMMENT_CODEC_H
#define WB_COMMENT_CODEC_H
#include <stddef.h>

/* A display bound, independent of RouterOS version or wire lengths. */
#define WB_COMMENT_MAX_BYTES ((size_t)1048576)
enum wb_encoding { WB_AUTO, WB_UTF8, WB_CP1251 };
enum wb_status { WB_OK_UTF8, WB_OK_CP1251, WB_BAD_INPUT, WB_UNDEFINED_BYTE,
                 WB_TOO_LARGE, WB_NO_SPACE, WB_NO_MEMORY };
int wb_valid_utf8(const unsigned char *data, size_t length);
enum wb_status wb_decode_comment(const unsigned char *input, size_t length,
    char *output, size_t capacity, enum wb_encoding mode, size_t *written);
#endif
