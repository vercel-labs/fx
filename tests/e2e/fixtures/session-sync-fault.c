#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
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

typedef int (*sync_fn)(int);

static int injected(int fd, sync_fn pass) {
    const char *target = getenv("FX_TEST_SYNC_TARGET");
    const char *arm = getenv("FX_TEST_SYNC_ARM");
    const char *record = getenv("FX_TEST_SYNC_RECORD");
    const char *match = getenv("FX_TEST_SYNC_MATCH");
    char actual[PATH_MAX], expected[PATH_MAX];
    if (!target || !arm || !record || !match || access(arm, F_OK) || !realpath(target, expected)) return pass(fd);
#ifdef __APPLE__
    if (fcntl(fd, F_GETPATH, actual)) return pass(fd);
#else
    char link[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t path_bytes = readlink(link, actual, sizeof(actual) - 1);
    if (path_bytes < 0 || (size_t)path_bytes >= sizeof(actual) - 1) return pass(fd);
    actual[path_bytes] = 0;
#endif
    if (strcmp(actual, expected)) return pass(fd);
    struct stat state;
    if (fstat(fd, &state) || !S_ISREG(state.st_mode)) return pass(fd);
    if (!atomic_load(&fired)) {
        char tail[16385];
        size_t count = state.st_size < 16384 ? (size_t)state.st_size : 16384;
        ssize_t got = pread(fd, tail, count, state.st_size - count);
        if (got < 0) return pass(fd);
        tail[got] = 0;
        if (!strstr(tail, match)) return pass(fd);
    }
    int hit = atomic_fetch_add(&fired, 1) + 1;
    int log = open(record, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (log >= 0) {
        dprintf(log, "hit=%d target=%s\n", hit, actual);
        close(log);
    }
    errno = EIO;
    return -1;
}

static int injected_sync(int fd) { return injected(fd, real_sync); }

#ifdef __APPLE__
static int real_full_sync(int fd) { return fcntl(fd, F_FULLFSYNC); }

// fx flushes the conversation log with F_FULLFSYNC on macOS.
static int injected_fcntl(int fd, int cmd, ...) {
    va_list args;
    va_start(args, cmd);
    void *arg = va_arg(args, void *);
    va_end(args);
    if (cmd == F_FULLFSYNC) return injected(fd, real_full_sync);
    return fcntl(fd, cmd, arg);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; }
bindings[] = {
    { (const void *)injected_sync, (const void *)fsync },
    { (const void *)injected_fcntl, (const void *)fcntl },
};
#else
int fsync(int fd) { return injected_sync(fd); }
#endif
