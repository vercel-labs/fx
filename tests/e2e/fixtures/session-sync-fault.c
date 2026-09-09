#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef __APPLE__
#include <dlfcn.h>
#endif

static _Atomic int fired;

static int real_sync(int fd) {
#ifdef __APPLE__
    return fsync(fd);
#else
    int (*next)(int) = dlsym(RTLD_NEXT, "fsync");
    if (next) return next(fd);
    errno = EIO;
    return -1;
#endif
}

static int injected_sync(int fd) {
    const char *target = getenv("FX_TEST_SYNC_TARGET");
    const char *target_file = getenv("FX_TEST_SYNC_TARGET_FILE");
    char configured[PATH_MAX];
    if (target_file) {
        int source = open(target_file, O_RDONLY);
        if (source < 0) return real_sync(fd);
        ssize_t count = read(source, configured, sizeof(configured) - 1);
        close(source);
        if (count <= 0 || (size_t)count >= sizeof(configured) - 1) return real_sync(fd);
        configured[count] = 0;
        target = configured;
    }
    const char *arm = getenv("FX_TEST_SYNC_ARM");
    const char *record = getenv("FX_TEST_SYNC_RECORD");
    const char *match = getenv("FX_TEST_SYNC_MATCH");
    char actual[PATH_MAX], expected[PATH_MAX];
    if (!target || !arm || !record || !match || access(arm, F_OK) || !realpath(target, expected)) return real_sync(fd);
#ifdef __APPLE__
    if (fcntl(fd, F_GETPATH, actual)) return real_sync(fd);
#else
    char link[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t path_bytes = readlink(link, actual, sizeof(actual) - 1);
    if (path_bytes < 0 || (size_t)path_bytes >= sizeof(actual) - 1) return real_sync(fd);
    actual[path_bytes] = 0;
#endif
    if (strcmp(actual, expected)) return real_sync(fd);
    struct stat state;
    if (fstat(fd, &state) || !S_ISREG(state.st_mode)) return real_sync(fd);
    if (!atomic_load(&fired)) {
        char tail[16385];
        size_t count = state.st_size < 16384 ? (size_t)state.st_size : 16384;
        ssize_t got = pread(fd, tail, count, state.st_size - count);
        if (got < 0) return real_sync(fd);
        tail[got] = 0;
        size_t match_bytes = strlen(match);
        int found = 0;
        for (size_t offset = 0; offset + match_bytes <= (size_t)got; offset++) {
            if (!memcmp(tail + offset, match, match_bytes)) { found = 1; break; }
        }
        if (!found) return real_sync(fd);
    }
    int hit = atomic_fetch_add(&fired, 1) + 1;
    int log = open(record, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (log >= 0) {
        dprintf(log, "hit=%d target=%s\n", hit, actual);
        close(log);
    }
    const char *mode = getenv("FX_TEST_SYNC_MODE");
    if (mode && !strcmp(mode, "hold")) {
        while (!access(arm, F_OK)) usleep(10000);
        return real_sync(fd);
    }
    errno = EIO;
    return -1;
}

#ifdef __APPLE__
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; }
binding = { (const void *)injected_sync, (const void *)fsync };
#else
int fsync(int fd) { return injected_sync(fd); }
#endif
