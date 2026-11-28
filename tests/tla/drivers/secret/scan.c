// Loaded into fx with DYLD_INSERT_LIBRARIES by driver.ts in this folder. It
// looks at every block the process gives back to libc and appends a line to
// the file named by FX_SECRET_SCAN_RECORD for each block that still holds one
// of the markers listed, one per line, in the file named by
// FX_SECRET_SCAN_MARKERS:
//
//   free <bytes> <marker>   free() took the block back as it was
//   move <bytes> <marker>   realloc() moved the block and took the old one back
//
// <marker> is the marker's line number, from 0. The markers come from a file
// rather than the environment, so a copy fx makes of its environment never
// holds one. It writes "loaded <pid>" when it starts, so the driver knows it
// ran. macOS only: it replaces free and realloc through dyld's __interpose
// section and sizes each block with malloc_size.
#include <fcntl.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_MARKERS 32

static char marker_text[4096];
static const char *markers[MAX_MARKERS];
static size_t marker_lens[MAX_MARKERS];
static int marker_count = 0;
static int record_fd = -1;

static void note(const char *what, size_t bytes, long value) {
    if (record_fd < 0) return;
    char line[96];
    int len = snprintf(line, sizeof line, "%s %zu %ld\n", what, bytes, value);
    if (len > 0) (void)write(record_fd, line, (size_t)len);
}

__attribute__((constructor)) static void start(void) {
    const char *record = getenv("FX_SECRET_SCAN_RECORD");
    const char *list = getenv("FX_SECRET_SCAN_MARKERS");
    if (!record || !list) return;
    record_fd = open(record, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    int fd = open(list, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t got = read(fd, marker_text, sizeof marker_text - 1);
    close(fd);
    if (got <= 0) return;
    marker_text[got] = '\0';
    char *cursor = marker_text;
    while (*cursor && marker_count < MAX_MARKERS) {
        char *end = strchr(cursor, '\n');
        if (end) *end = '\0';
        if (*cursor) {
            markers[marker_count] = cursor;
            marker_lens[marker_count] = strlen(cursor);
            marker_count++;
        }
        if (!end) break;
        cursor = end + 1;
    }
    note("loaded", (size_t)marker_count, (long)getpid());
}

// The first marker the n bytes at p hold, or -1.
static int find(const void *p, size_t n) {
    for (int i = 0; i < marker_count; i++) {
        if (n >= marker_lens[i] && memmem(p, n, markers[i], marker_lens[i])) return i;
    }
    return -1;
}

static void scan_free(void *p) {
    if (p && marker_count > 0) {
        size_t n = malloc_size(p);
        int hit = find(p, n);
        if (hit >= 0) note("free", n, hit);
    }
    free(p);
}

static void *scan_realloc(void *p, size_t size) {
    int hit = -1;
    size_t n = 0;
    if (p && marker_count > 0) {
        n = malloc_size(p);
        hit = find(p, n);
    }
    void *moved = realloc(p, size);
    if (hit >= 0 && moved != p && (moved != NULL || size == 0)) note("move", n, hit);
    return moved;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interposers[] = {
    { (const void *)scan_free, (const void *)free },
    { (const void *)scan_realloc, (const void *)realloc },
};
