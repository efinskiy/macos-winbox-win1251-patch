#include "codec.h"
#include <stdint.h>
#include <string.h>

static const uint16_t cp1251[128] = {
#include "cp1251_table.inc"
};

int wb_valid_utf8(const unsigned char *data, size_t length) {
    if (length > WB_COMMENT_MAX_BYTES || (data == NULL && length != 0)) return 0;
    size_t i = 0;
    while (i < length) {
        unsigned int c = data[i++];
        if (c < 0x80) continue;
        size_t more;
        unsigned int low = 0x80, high = 0xbf;
        if (c >= 0xc2 && c <= 0xdf) more = 1;
        else if (c >= 0xe0 && c <= 0xef) {
            more = 2;
            if (c == 0xe0) low = 0xa0;
            if (c == 0xed) high = 0x9f;
        } else if (c >= 0xf0 && c <= 0xf4) {
            more = 3;
            if (c == 0xf0) low = 0x90;
            if (c == 0xf4) high = 0x8f;
        } else return 0;
        if (more > length - i || data[i] < low || data[i] > high) return 0;
        ++i;
        for (size_t k = 1; k < more; ++k, ++i)
            if (data[i] < 0x80 || data[i] > 0xbf) return 0;
    }
    return 1;
}

enum wb_status wb_decode_comment(const unsigned char *input, size_t length,
        char *output, size_t capacity, enum wb_encoding mode, size_t *written) {
    if (written != NULL) *written = 0;
    if (output != NULL && capacity != 0) output[0] = '\0';
    if (output == NULL || capacity == 0 || written == NULL ||
        (input == NULL && length != 0) || mode < WB_AUTO || mode > WB_CP1251)
        return WB_BAD_INPUT;
    if (length > WB_COMMENT_MAX_BYTES) return WB_TOO_LARGE;
    if (mode != WB_CP1251 && wb_valid_utf8(input, length)) {
        if (length >= capacity) return WB_NO_SPACE;
        if (length != 0) memcpy(output, input, length);
        output[length] = '\0';
        *written = length;
        return WB_OK_UTF8;
    }
    if (mode == WB_UTF8) return WB_BAD_INPUT;
    size_t needed = 0;
    /* Validate before emitting anything, including an undefined CP1251 byte. */
    for (size_t i = 0; i < length; ++i) {
        unsigned int c = input[i];
        unsigned int u = c < 0x80 ? c : cp1251[c - 0x80];
        if (c >= 0x80 && u == 0) return WB_UNDEFINED_BYTE;
        needed += u < 0x80 ? 1u : (u < 0x800 ? 2u : 3u);
    }
    if (needed >= capacity) return WB_NO_SPACE;
    size_t pos = 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned int c = input[i];
        unsigned int u = c < 0x80 ? c : cp1251[c - 0x80];
        if (u < 0x80) output[pos++] = (char)u;
        else if (u < 0x800) {
            output[pos++] = (char)(0xc0u | (u >> 6));
            output[pos++] = (char)(0x80u | (u & 0x3fu));
        } else {
            output[pos++] = (char)(0xe0u | (u >> 12));
            output[pos++] = (char)(0x80u | ((u >> 6) & 0x3fu));
            output[pos++] = (char)(0x80u | (u & 0x3fu));
        }
    }
    output[pos] = '\0';
    *written = pos;
    return WB_OK_CP1251;
}
