#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "native_fixture.h"

typedef void (*widget_constructor)(void *, void *, int, int, unsigned int, int, int);
typedef void (*unary_method)(void *);
typedef void (*text_setter)(void *, const char *);

static void store_pointer(unsigned char *where, uintptr_t value) {
    memcpy(where, &value, sizeof(value));
}

static void string_fixture(unsigned char *storage, const char *bytes, int use_short) {
    size_t length = strlen(bytes);
#if defined(__aarch64__)
    if (use_short) {
        memcpy(storage, bytes, length + 1);
        storage[23] = (unsigned char)length;
    } else {
        store_pointer(storage, (uintptr_t)bytes);
        store_pointer(storage + 8, length);
        storage[23] = 0x80;
    }
#elif defined(__x86_64__)
    if (use_short) {
        storage[0] = (unsigned char)(2 * length);
        memcpy(storage + 1, bytes, length + 1);
    } else {
        storage[0] = 1;
        store_pointer(storage + 8, length);
        store_pointer(storage + 16, (uintptr_t)bytes);
    }
#endif
}

static int equal_text(const unsigned char *widget, size_t offset,
                      const uint16_t *expected, size_t expected_length) {
    const uint16_t *data = NULL;
    size_t length = 0;
    memcpy(&data, widget + offset + 8, sizeof(data));
    memcpy(&length, widget + offset + 16, sizeof(length));
    return length == expected_length &&
        (length == 0 || (data != NULL && memcmp(data, expected, 2 * length) == 0));
}

static void destroy_widget(unsigned char *widget) {
    uintptr_t *vtable = NULL;
    unary_method destroy = NULL;
    memcpy(&vtable, widget, sizeof(vtable));
    /* QObject's non-deleting virtual destructor releases Qt and string members. */
    memcpy(&destroy, &vtable[3], sizeof(destroy));
    destroy(widget);
}

__attribute__((constructor)) static void run_probe(void) {
    const char *path = getenv("WB_PROBE_REPORT");
    if (path == NULL) return;
    FILE *report = fopen(path, "w");
    if (report == NULL) _exit(90);
    widget_constructor construct = NULL;
    unary_method refresh = NULL;
    text_setter original = NULL;
    uintptr_t ctor_address = address("WB_EDITOR_WIDGET_CTOR");
    uintptr_t refresh_address = address("WB_EDITOR_VIEW_REFRESH");
    uintptr_t setter_address = address("WB_EDITOR_ORIGINAL_HELPER");
    uintptr_t view_vtable = address("WB_EDITOR_VIEW_VTABLE");
    uintptr_t converter_vtable = address("WB_EDITOR_CONVERTER_VTABLE");
    const char *offset_text = getenv("WB_EDITOR_WIDGET_TEXT_OFFSET");
    size_t text_offset = offset_text == NULL ? 0 : (size_t)strtoul(offset_text, NULL, 10);
    if (!ctor_address || !refresh_address || !setter_address || !view_vtable ||
        !converter_vtable || text_offset > 400 || text_offset < 8) {
        fputs("{\"error\":\"missing editor profile\"}", report);
        (void)fclose(report);
        _exit(91);
    }
    memcpy(&construct, &ctor_address, sizeof(construct));
    memcpy(&refresh, &refresh_address, sizeof(refresh));
    memcpy(&original, &setter_address, sizeof(original));
    unsigned int failed = 0;
    fputs("{\"target\":\"WinBox::TextView::refresh\",\"cases\":[", report);
    for (size_t index = 0; index < 4 * sizeof(examples)/sizeof(examples[0]); ++index) {
        size_t i = index / 4;
        int comment = (index % 4) < 2, use_short = (index % 2) != 0;
        _Alignas(16) unsigned char widget[512] = {0}, reference[512] = {0};
        _Alignas(16) unsigned char field[160] = {0}, reference_field[160] = {0};
        _Alignas(16) unsigned char view[256] = {0}, converter[32] = {0}, raw[24] = {0};
        if (strlen(examples[i].bytes) > 22) _exit(93);
        string_fixture(field, comment ? "Comment" : "Name", 1);
        construct(widget, field, 0, 0, UINT32_MAX, 0, 0);
        string_fixture(raw, examples[i].bytes, use_short);
        unsigned char before[sizeof(raw)];
        memcpy(before, raw, sizeof(raw));
        store_pointer(view, view_vtable);
        store_pointer(view + 0xb8, (uintptr_t)widget);
        store_pointer(view + 0xd8, (uintptr_t)raw);
        store_pointer(view + 0xe0, (uintptr_t)converter);
        store_pointer(converter, converter_vtable);
        uint32_t maximum = UINT32_MAX;
        memcpy(converter + 12, &maximum, sizeof(maximum));
        refresh(view);
        int correct;
        if (comment) correct = equal_text(widget, text_offset, examples[i].expected, examples[i].length);
        else {
            /* Compare untouched fields with WinBox's own original UTF-8 behavior. */
            string_fixture(reference_field, "Name", 1);
            construct(reference, reference_field, 0, 0, UINT32_MAX, 0, 0);
            original(reference, examples[i].bytes);
            const uint16_t *expected = NULL;
            size_t length = 0;
            memcpy(&expected, reference + text_offset + 8, sizeof(expected));
            memcpy(&length, reference + text_offset + 16, sizeof(length));
            correct = equal_text(widget, text_offset, expected, length);
            destroy_widget(reference);
        }
        int unchanged = memcmp(before, raw, sizeof(raw)) == 0;
        if (!correct || !unchanged) ++failed;
        fprintf(report, "%s{\"name\":\"%s\",\"field\":\"%s\",\"storage\":\"%s\",\"decoded\":%s,\"source_unchanged\":%s}",
            index == 0 ? "" : ",", examples[i].name, comment ? "Comment" : "Name",
            use_short ? "short" : "long", correct ? "true" : "false", unchanged ? "true" : "false");
        (void)fflush(report);
        destroy_widget(widget);
    }
    fprintf(report, "],\"failed\":%u}\n", failed);
    if (fclose(report) != 0) _exit(92);
    /* No WinBox main, router connection, or configuration write is performed. */
    _exit(failed == 0 ? 0 : 1);
}
