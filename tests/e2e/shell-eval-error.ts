// What `eval` prints for a command with an unclosed quote, as the shell tool
// returns it. The shell snapshot runs a user-profile command through `eval`
// (`snapshotInvocation` and `snapshotScript` in
// src/core/terminal/shell_resolver.zig), so the error names `eval` and not the
// shell, and each shell gives it another prefix:
//
//   zsh      (eval):1: unmatched "
//   bash 5   /dev/fd/0: eval: line 2: unexpected EOF while looking for matching `"'
//   bash 3.2 /bin/bash: eval: line 7: unexpected EOF while looking for matching `"'
//
// bash 5 sources the snapshot script from /dev/fd/0. bash 3.2 reads it with
// `eval "$(< /dev/fd/0)"`, so it names itself, under the path fx started it
// by, and the line number depends on the startup files.
// tests/tla/shell_eval_error/ShellEvalError.tla models which prefixes the
// matcher must accept, and tests/tla/drivers/shell_eval_error/ runs real shells
// through it.
export const EVAL_ERROR_PREFIX = /\(eval\):1:|\/dev\/fd\/0: eval:|bash: eval: line \d+:/;
