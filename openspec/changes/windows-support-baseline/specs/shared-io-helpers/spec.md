# Spec: Cross-platform shared I/O helpers

> Delta spec for the new helpers added to `src/core/shared/io.zig`
> as part of the Windows x86_64 support baseline.

## Purpose

Centralize the platform branches that previously lived inline at
dozens of call sites. Every helper in this spec returns a
`![]u8` / typed value and uses `comptime builtin.os.tag` so the
non-Windows branch is elided on Linux/macOS.

## Requirements

### REQ-shared-home-dir
`io_mod.homeDir(alloc)` MUST return the user profile directory:

- **Windows**: `USERPROFILE` → `HOME` → `HOMEDRIVE+HOMEPATH`.
  Order matters; the first non-null wins. Returns
  `error.UserProfileMissing` if all three are unset.
- **Linux/macOS**: `HOME`. Returns `error.HomeMissing` if unset.
- The returned slice is allocated; the caller owns it.

### REQ-shared-temp-dir
`io_mod.tempDir(alloc)` MUST return the temporary directory:

- **Windows**: `TEMP` → `TMP`. Returns `error.TempMissing` if
  both are unset.
- **Linux/macOS**: `TMPDIR` or `/tmp`.
- The returned slice is allocated; the caller owns it.

### REQ-shared-env-case-insensitive
`io_mod.getenvCaseInsensitive(key)` MUST look up an environment
variable:

- **Windows**: case-insensitive lookup via `GetEnvironmentVariableW`.
- **Linux/macOS**: case-sensitive lookup via `std.posix.getenv`.
- Returns `null` if unset; the lifetime of the returned slice is
  the lifetime of the environment block (do not free).

### REQ-shared-permissions-from-mode
`io_mod.permissionsFromMode(mode)` MUST convert a POSIX `u32`
mode to `std.Io.File.Permissions`:

- **Windows**: returns `.default_file` (the Windows enum has no
  POSIX-mode semantics).
- **Linux/macOS**: `std.Io.File.Permissions.fromMode(mode)`.

### REQ-shared-permissions-to-mode
`io_mod.permissionsToMode(permissions)` MUST convert
`std.Io.File.Permissions` to a POSIX `u32` mode:

- **Windows**: returns `0` (no POSIX mode equivalent).
- **Linux/macOS**: `permissions.toMode()`.

### REQ-shared-open-regular-file-error
`io_mod.OpenRegularFileError` MUST be an error union used by every
helper that opens a regular file and must distinguish the
"not a regular file" failure mode from generic I/O errors. The
exact union is:

```zig
pub const OpenRegularFileError = std.Io.File.OpenError ||
    std.Io.File.StatError ||
    std.posix.UnexpectedError ||
    error{ NotRegularFile, SymLinkLoop, NameTooLong, FileNotFound };
```

Call sites that previously used a generic `std.Io.File.OpenError`
MUST be updated to thread `OpenRegularFileError` so error messages
remain specific.

### REQ-shared-realpath
`io_mod.realpathAlloc(alloc, path)` and
`io_mod.dirRealpathAlloc(alloc, dir, sub_path)` MUST resolve a
path to its canonical form:

- **Windows**: `RtlGetFullPathName_U` (UNC normalization).
- **Linux/macOS**: existing `realpath(3)` flow.

### REQ-shared-sync-verified-dir
`io_mod.syncVerifiedDir(...)` MUST flush a directory's metadata to
stable storage:

- **Windows**: returns `error.OperationUnsupported` (no fsync on
  Win32 directories).
- **Linux/macOS**: existing fsync flow.

## Scenarios

### SCN-shared-home-dir-windows
Given `USERPROFILE=C:\Users\alice`, when `homeDir(alloc)` is
called on Windows, then it returns `"C:\\Users\\alice"`.

### SCN-shared-temp-dir-windows
Given `TEMP=C:\Users\alice\AppData\Local\Temp`, when
`tempDir(alloc)` is called on Windows, then it returns that
value.

### SCN-shared-env-case-insensitive
Given `Path=C:\WINDOWS` on Windows, when
`getenvCaseInsensitive("PATH")` is called, then it returns
`"C:\\WINDOWS"`.

### SCN-shared-permissions-from-mode
Given `0o600`, when `permissionsFromMode(0o600)` is called on
Windows, then it returns `.default_file`. When called on Linux,
it returns the mode-encoded `.Permissions` for `0o600`.

### SCN-shared-realpath-windows
Given `"C:\\Users\\alice\\..\\bob"`, when `realpathAlloc(alloc, p)`
is called on Windows, then it returns `"C:\\Users\\bob"`.

## Out of scope

- The actual call-site replacements that adopted these helpers.
  Those are tracked in `../tasks.md` (T-F1.1 through T-F1.13).
- Anything outside `src/core/shared/io.zig`.