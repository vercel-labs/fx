// fx takes the login shell from the passwd entry (getpwuid_r in
// src/core/terminal/shell_resolver.zig), not from $SHELL, so a run cannot pick
// it. Loaded with DYLD_INSERT_LIBRARIES, this makes getpwuid_r report the shell
// that FX_TLA_LOGIN_SHELL names, and changes nothing else. macOS only, like
// ../lib/path-fault.c.
#include <pwd.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

struct interpose {
    const void *replacement;
    const void *original;
};

static int login_shell_getpwuid_r(uid_t uid, struct passwd *pwd, char *buf, size_t buflen, struct passwd **result) {
    int status = getpwuid_r(uid, pwd, buf, buflen, result);
    const char *shell = getenv("FX_TLA_LOGIN_SHELL");
    if (status == 0 && *result != NULL && shell != NULL && shell[0] != '\0') pwd->pw_shell = (char *)shell;
    return status;
}

__attribute__((used)) static struct interpose interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)login_shell_getpwuid_r, (const void *)getpwuid_r},
};
