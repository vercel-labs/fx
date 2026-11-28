// Answers stdin the way a revoked terminal does on macOS 15, so a Linux run can
// reach the same failed read. Loaded with LD_PRELOAD on Linux.
//
// While the file named by FX_STDIN_EIO_ARM exists:
//   poll on stdin   reports POLLIN only, never POLLHUP or POLLNVAL
//   read on stdin   fails with EIO
//   isatty on stdin answers 0
// Each rewritten answer appends a line to FX_STDIN_EIO_RECORD. Before the file
// exists, and for every other descriptor, each call passes through to libc.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int armed(void) {
    const char *arm = getenv("FX_STDIN_EIO_ARM");
    return arm != NULL && access(arm, F_OK) == 0;
}

static void record(const char *what) {
    const char *file = getenv("FX_STDIN_EIO_RECORD");
    if (file == NULL) return;
    int fd = open(file, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    dprintf(fd, "%s\n", what);
    close(fd);
}

ssize_t read(int fd, void *buf, size_t count) {
    static ssize_t (*real_read)(int, void *, size_t);
    if (real_read == NULL) real_read = (ssize_t (*)(int, void *, size_t))dlsym(RTLD_NEXT, "read");
    if (fd == STDIN_FILENO && armed()) {
        record("read-eio");
        errno = EIO;
        return -1;
    }
    return real_read(fd, buf, count);
}

int isatty(int fd) {
    static int (*real_isatty)(int);
    if (real_isatty == NULL) real_isatty = (int (*)(int))dlsym(RTLD_NEXT, "isatty");
    if (fd == STDIN_FILENO && armed()) {
        record("isatty-0");
        errno = ENOTTY;
        return 0;
    }
    return real_isatty(fd);
}

int poll(struct pollfd *fds, nfds_t count, int timeout) {
    static int (*real_poll)(struct pollfd *, nfds_t, int);
    if (real_poll == NULL) real_poll = (int (*)(struct pollfd *, nfds_t, int))dlsym(RTLD_NEXT, "poll");
    int has_stdin = 0;
    for (nfds_t i = 0; i < count; i++) {
        if (fds[i].fd == STDIN_FILENO) has_stdin = 1;
    }
    if (!has_stdin || !armed()) return real_poll(fds, count, timeout);
    int ready = 0;
    for (nfds_t i = 0; i < count; i++) {
        fds[i].revents = fds[i].fd == STDIN_FILENO ? (fds[i].events & POLLIN) : 0;
        if (fds[i].revents != 0) ready++;
    }
    return ready;
}
