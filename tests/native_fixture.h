/* Shared cases and ASLR lookup for real WinBox integration probes. */
struct example { const char *name, *bytes; const uint16_t *expected; size_t length; };
#define CASE(name, bytes, text) {name, bytes, (const uint16_t *)u##text, sizeof(u##text)/2-1}
static const struct example examples[] = {
    CASE("ascii", "uplink #1", "uplink #1"),
    CASE("utf8", "Привет", "Привет"),
    CASE("cp1251", "\xcf\xf0\xe8\xe2\xe5\xf2", "Привет"),
    CASE("cp1251-yo", "\xa8\xb8", "Ёё"),
    CASE("cp1251-ukrainian", "\xaa\xba\xaf\xbf\xb2\xb3\xa5\xb4", "ЄєЇїІіҐґ"),
    CASE("cp1251-punctuation", "\x93\xc2\xe0\xed\x94\x97\xb9\xa0", "“Ван”—№ "),
    CASE("utf8-emoji", "Канал 😀", "Канал 😀"),
    CASE("utf8-replacement", "�", "�"),
    CASE("ambiguous-utf8-first", "\xd0\xa1", "С"),
    CASE("undefined-cp1251", "\x98", ""),
    CASE("empty", "", ""),
};

static uintptr_t address(const char *name) {
    const char *text = getenv(name);
    if (text == NULL) return 0;
    char *end = NULL;
    unsigned long long value = strtoull(text, &end, 0);
    if (end == text || *end != '\0' || value == 0) return 0;
    /* DYLD_INSERT_LIBRARIES can put the probe at index 0, ahead of MH_EXECUTE. */
    uint32_t count = _dyld_image_count();
    if (count > 4096) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header != NULL && header->filetype == MH_EXECUTE)
            return (uintptr_t)value + (uintptr_t)_dyld_get_image_vmaddr_slide(i);
    }
    return 0;
}

