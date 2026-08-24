const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const process_query_limited_information: windows.DWORD = 0x1000;

extern "kernel32" fn GetProcessId(
    process: windows.HANDLE,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn GetProcessTimes(
    process: windows.HANDLE,
    creation_time: *windows.FILETIME,
    exit_time: *windows.FILETIME,
    kernel_time: *windows.FILETIME,
    user_time: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

pub fn idFromHandle(process: windows.HANDLE) !windows.DWORD {
    const id = GetProcessId(process);
    if (id == 0) return error.ProcessNotFound;
    return id;
}

pub fn creationTime(process_id: windows.DWORD) !u64 {
    const process = OpenProcess(
        process_query_limited_information,
        .FALSE,
        process_id,
    ) orelse return error.ProcessNotFound;
    defer windows.CloseHandle(process);

    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (!GetProcessTimes(process, &creation, &exit, &kernel, &user).toBool()) {
        return error.ProcessIdentityUnavailable;
    }
    return (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
}

test "current Windows process has a stable creation time" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const created = try creationTime(windows.GetCurrentProcessId());
    try std.testing.expect(created > 0);
}
