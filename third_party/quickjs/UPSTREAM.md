# QuickJS-ng upstream

- Project: <https://github.com/quickjs-ng/quickjs>
- Version: `0.15.0`
- Commit: `433941b99fb3c5e7f98b7ebd78727972bcf467ee`
- License: MIT, retained in `LICENSE`

fx vendors only the QuickJS core files required by `fx-code-host`. It does not
vendor or link `quickjs-libc`, the command-line interpreter, standard operating
system modules, examples, tests, or build-system files.

The code host creates a restricted context and exposes no QuickJS filesystem,
network, environment, subprocess, module, timer, worker, shared-memory,
`eval`, or `Function` API to generated programs.
