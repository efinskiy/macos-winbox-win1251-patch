#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* This probe calls the real WinBox method; the fixture supplies only its row data. */
struct variant_result { uintptr_t words[4]; };
typedef struct variant_result (*model_method)(const void *, const void *, int);
typedef void (*destroy_method)(void *);
#include "native_fixture.h"

__attribute__((constructor)) static void run_probe(void) {
    const char *path = getenv("WB_PROBE_REPORT");
    if (path == NULL) return;
    FILE *report = fopen(path, "w");
    if (report == NULL) _exit(90);
    uintptr_t method_address = address("WB_PROBE_MODEL");
    uintptr_t destroy_address = address("WB_PROBE_DESTROY");
    model_method method = NULL;
    destroy_method destroy = NULL;
    _Static_assert(sizeof(method) == sizeof(method_address), "function address size");
    memcpy(&method, &method_address, sizeof(method));
    memcpy(&destroy, &destroy_address, sizeof(destroy));
    if (method == NULL || destroy == NULL) {
        fputs("{\"error\":\"missing profile addresses\"}\n", report);
        (void)fclose(report);
        _exit(91);
    }
    unsigned int failed = 0;
    fputs("{\"target\":\"WinBox::BaseTableModel::data\",\"cases\":[", report);
    for (size_t case_index = 0; case_index < 2 * sizeof(examples)/sizeof(examples[0]); ++case_index) {
        size_t i = case_index / 2;
        int use_short = (case_index % 2) != 0;
        _Alignas(16) unsigned char model[512] = {0};
        _Alignas(16) unsigned char record[128] = {0};
        _Alignas(16) unsigned char index[32] = {0};
        uintptr_t entry = (uintptr_t)record, entries = (uintptr_t)&entry;
        uintptr_t model_pointer = (uintptr_t)model, present = 1;
        memcpy(model + 0x20, &present, sizeof(present));
        memcpy(model + 0x1b8, &entries, sizeof(entries));
        memcpy(index + 0x10, &model_pointer, sizeof(model_pointer));
        uintptr_t bytes = (uintptr_t)examples[i].bytes;
        size_t input_length = strlen(examples[i].bytes);
        if (input_length > 22 && use_short) {
            fputs("{\"error\":\"short string fixture exceeds capacity\"}", report);
            (void)fclose(report);
            _exit(93);
        }
#if defined(__aarch64__)
        if (use_short) {
            memcpy(record + 0x30, examples[i].bytes, input_length + 1);
            record[0x47] = (unsigned char)input_length;
        } else {
            memcpy(record + 0x30, &bytes, sizeof(bytes));
            record[0x47] = 0x80;
        }
#elif defined(__x86_64__)
        if (use_short) {
            record[0x30] = (unsigned char)(input_length * 2);
            memcpy(record + 0x31, examples[i].bytes, input_length + 1);
        } else {
            record[0x30] = 1;
            memcpy(record + 0x40, &bytes, sizeof(bytes));
        }
#else
#error Unsupported architecture
#endif
        unsigned char before_model[sizeof(model)], before_record[sizeof(record)];
        memcpy(before_model, model, sizeof(model));
        memcpy(before_record, record, sizeof(record));
        struct variant_result value = method(model, index, 0x104);
        size_t length = value.words[2];
        const uint16_t *text = (const uint16_t *)value.words[1];
        int correct = length == examples[i].length &&
            (length == 0 || (text != NULL &&
             memcmp(text, examples[i].expected, length * sizeof(*text)) == 0));
        int unchanged = memcmp(before_model, model, sizeof(model)) == 0 &&
                        memcmp(before_record, record, sizeof(record)) == 0;
        if (!correct || !unchanged) ++failed;
        fprintf(report, "%s{\"name\":\"%s\",\"storage\":\"%s\",\"decoded\":%s,\"row_unchanged\":%s,\"utf16_length\":%zu}",
            case_index == 0 ? "" : ",", examples[i].name, use_short ? "short" : "long", correct ? "true" : "false",
            unchanged ? "true" : "false", length);
        destroy(&value);
    }
    fprintf(report, "],\"failed\":%u}\n", failed);
    if (fclose(report) != 0) _exit(92);
    /* Stop before WinBox main: the probe never opens sessions or sends configuration. */
    _exit(failed == 0 ? 0 : 1);
}
