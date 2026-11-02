// Faults on exact paths, while the file FX_PATH_FAULT_ARM exists.
// FX_PATH_FAULT_TARGETS holds absolute paths, separated by ':'.
//
//   FX_PATH_FAULT_MODE=refuse  every rename, unlink and rmdir that would move
//                              or remove a target, or anything inside one,
//                              fails with EACCES.
//   FX_PATH_FAULT_MODE=pause   a rename of exactly a target blocks until the
//                              arm file is gone, so a driver can kill the
//                              process at that point, or for
//                              FX_PATH_FAULT_PAUSE_MS milliseconds when set.
//
// Each hit appends a line to FX_PATH_FAULT_RECORD, the evidence that the
// boundary was reached. Every other call passes through untouched.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum hit { MISS, REFUSE, PAUSE };

// The absolute path `path` names relative to `dirfd`, lexically.
static int absolute(int dirfd, const char *path, char out[PATH_MAX]) {
    if (path[0] == '/') {
        if (strlen(path) >= PATH_MAX) return -1;
        strcpy(out, path);
        return 0;
    }
    char dir[PATH_MAX];
    if (dirfd == AT_FDCWD) {
        if (!getcwd(dir, sizeof dir)) return -1;
    } else if (fcntl(dirfd, F_GETPATH, dir) != 0) {
        return -1;
    }
    if (snprintf(out, PATH_MAX, "%s/%s", dir, path) >= PATH_MAX) return -1;
    return 0;
}

static void record(const char *what, const char *path) {
    const char *file = getenv("FX_PATH_FAULT_RECORD");
    if (!file) return;
    int log = open(file, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (log < 0) return;
    dprintf(log, "%s %s\n", what, path);
    close(log);
}

// What to do with a call on `path`. Targets are realpaths, so `path` is
// compared after resolving its parent folder. A rename may pause; any call
// may be refused.
static enum hit check(int dirfd, const char *path, int is_rename) {
    const char *targets = getenv("FX_PATH_FAULT_TARGETS");
    const char *arm = getenv("FX_PATH_FAULT_ARM");
    const char *mode = getenv("FX_PATH_FAULT_MODE");
    if (!targets || !arm || !mode || access(arm, F_OK) != 0) return MISS;
    int pause = strcmp(mode, "pause") == 0;
    if (pause && !is_rename) return MISS;
    char full[PATH_MAX], parent[PATH_MAX], resolved[PATH_MAX];
    if (absolute(dirfd, path, full) != 0) return MISS;
    size_t len = strlen(full);
    while (len > 1 && full[len - 1] == '/') full[--len] = '\0';
    char *slash = strrchr(full, '/');
    if (!slash || slash == full) return MISS;
    *slash = '\0';
    if (!realpath(full, parent)) return MISS;
    if (snprintf(resolved, sizeof resolved, "%s/%s", parent, slash + 1) >= (int)sizeof resolved) return MISS;
    const char *start = targets;
    while (*start) {
        const char *end = strchr(start, ':');
        size_t n = end ? (size_t)(end - start) : strlen(start);
        int exact = n > 0 && strncmp(resolved, start, n) == 0 && resolved[n] == '\0';
        int inside = n > 0 && strncmp(resolved, start, n) == 0 && resolved[n] == '/';
        if (pause ? exact : (exact || inside)) {
            record(pause ? "paused" : "refused", resolved);
            return pause ? PAUSE : REFUSE;
        }
        if (!end) break;
        start = end + 1;
    }
    return MISS;
}

static long long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

// Blocks a paused rename until the driver disarms or kills the process, or
// until FX_PATH_FAULT_PAUSE_MS has passed.
static void hold(void) {
    const char *arm = getenv("FX_PATH_FAULT_ARM");
    const char *limit = getenv("FX_PATH_FAULT_PAUSE_MS");
    long long until = limit ? now_ms() + atoll(limit) : -1;
    while (arm && access(arm, F_OK) == 0 && (until < 0 || now_ms() < until)) usleep(10000);
}

static int fault_rename(const char *from, const char *to) {
    switch (check(AT_FDCWD, from, 1)) {
        case REFUSE: return errno = EACCES, -1;
        case PAUSE: hold(); break;
        case MISS: break;
    }
    return rename(from, to);
}

static int fault_renameat(int fromfd, const char *from, int tofd, const char *to) {
    switch (check(fromfd, from, 1)) {
        case REFUSE: return errno = EACCES, -1;
        case PAUSE: hold(); break;
        case MISS: break;
    }
    return renameat(fromfd, from, tofd, to);
}

static int fault_renameatx_np(int fromfd, const char *from, int tofd, const char *to, unsigned int flags) {
    switch (check(fromfd, from, 1)) {
        case REFUSE: return errno = EACCES, -1;
        case PAUSE: hold(); break;
        case MISS: break;
    }
    return renameatx_np(fromfd, from, tofd, to, flags);
}

static int fault_unlink(const char *path) {
    if (check(AT_FDCWD, path, 0) == REFUSE) return errno = EACCES, -1;
    return unlink(path);
}

static int fault_unlinkat(int dirfd, const char *path, int flags) {
    if (check(dirfd, path, 0) == REFUSE) return errno = EACCES, -1;
    return unlinkat(dirfd, path, flags);
}

static int fault_rmdir(const char *path) {
    if (check(AT_FDCWD, path, 0) == REFUSE) return errno = EACCES, -1;
    return rmdir(path);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interposers[] = {
    {(const void *)fault_rename, (const void *)rename},
    {(const void *)fault_renameat, (const void *)renameat},
    {(const void *)fault_renameatx_np, (const void *)renameatx_np},
    {(const void *)fault_unlink, (const void *)unlink},
    {(const void *)fault_unlinkat, (const void *)unlinkat},
    {(const void *)fault_rmdir, (const void *)rmdir},
};
