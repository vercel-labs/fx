// Answers polls and reads on stdin the way a system answers in two cases this
// machine never produces, so the driver can run the built fx against them.
// Loaded with DYLD_INSERT_LIBRARIES on macOS.
//
//   FX_STDIN_EIO_MODE=revoked  once stdin's terminal is gone (tcgetattr on it
//                              fails), a poll that reports POLLHUP or
//                              POLLNVAL on stdin reports POLLIN alone, and a
//                              read on stdin fails with EIO: what
//                              macos-15-arm64 answered for a revoked
//                              controlling terminal, where this machine
//                              answers POLLNVAL and a read of 0.
//   FX_STDIN_EIO_MODE=live     while the file FX_STDIN_EIO_ARM exists, a read
//                              on stdin fails with EIO and the terminal stays
//                              as it is: a background read that SIGTTIN did
//                              not stop.
//
// Each rewritten answer appends a line to FX_STDIN_EIO_RECORD, the evidence
// that the boundary was reached. Every other call passes through untouched,
// and tcgetattr is never rewritten.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static int mode_is(const char *want) {
    const char *mode = getenv("FX_STDIN_EIO_MODE");
    return mode && strcmp(mode, want) == 0;
}

static void record(const char *what) {
    const char *file = getenv("FX_STDIN_EIO_RECORD");
    if (!file) return;
    int log = open(file, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (log < 0) return;
    dprintf(log, "%s\n", what);
    close(log);
}

static int stdin_gone(void) {
    struct termios settings;
    return tcgetattr(STDIN_FILENO, &settings) != 0;
}

static int live_armed(void) {
    const char *arm = getenv("FX_STDIN_EIO_ARM");
    return mode_is("live") && arm && access(arm, F_OK) == 0;
}

static int fault_poll(struct pollfd *fds, nfds_t count, int timeout) {
    int ready = poll(fds, count, timeout);
    if (ready <= 0 || !mode_is("revoked")) return ready;
    for (nfds_t i = 0; i < count; i++) {
        if (fds[i].fd != STDIN_FILENO || !(fds[i].revents & (POLLHUP | POLLNVAL))) continue;
        if (!stdin_gone()) continue;
        fds[i].revents = (short)(fds[i].events & POLLIN);
        if (fds[i].revents == 0) ready--;
        record("poll-readable");
    }
    return ready;
}

static ssize_t fault_read(int fd, void *buf, size_t size) {
    if (fd == STDIN_FILENO && ((mode_is("revoked") && stdin_gone()) || live_armed())) {
        record(mode_is("revoked") ? "read-eio-revoked" : "read-eio-live");
        errno = EIO;
        return -1;
    }
    return read(fd, buf, size);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interposers[] = {
    {(const void *)fault_poll, (const void *)poll},
    {(const void *)fault_read, (const void *)read},
};
