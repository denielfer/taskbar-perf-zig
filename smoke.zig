const std = @import("std");

const w = @cImport({
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("WINVER", "0x0A00");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const wide = std.unicode.utf8ToUtf16LeStringLiteral;

fn findWindowForPid(class_name: [*:0]const u16, pid: w.DWORD) w.HWND {
    var current: w.HWND = null;
    while (true) {
        current = w.FindWindowExW(null, current, class_name, null);
        if (current == null) return null;
        var win_pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(current, &win_pid);
        if (win_pid == pid) return current;
    }
}

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("usage: smoke <path-to-TaskbarPerfZig.exe>\n", .{});
        return 1;
    }

    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, args[1]);
    defer allocator.free(exe_w);

    // A running instance holds the single-instance mutex: the new process would just ask it to open
    // its summary panel and exit 0, which looks like a crash here.
    if (w.FindWindowW(wide("TaskbarPerfZigOverlay"), null) != null) {
        std.debug.print("TaskbarPerfZig is already running; close it before running the smoke test\n", .{});
        return 1;
    }

    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi = std.mem.zeroes(w.PROCESS_INFORMATION);

    if (w.CreateProcessW(exe_w.ptr, null, null, null, 0, 0, null, null, &si, &pi) == 0) {
        std.debug.print("CreateProcessW failed: err={d}\n", .{w.GetLastError()});
        return 1;
    }
    defer _ = w.CloseHandle(pi.hThread);
    defer _ = w.CloseHandle(pi.hProcess);

    var overlay: w.HWND = null;
    const class_name = wide("TaskbarPerfZigOverlay");

    for (0..60) |_| {
        const wait_res = w.WaitForSingleObject(pi.hProcess, 0);
        if (wait_res != w.WAIT_TIMEOUT) {
            var code: w.DWORD = 1;
            _ = w.GetExitCodeProcess(pi.hProcess, &code);
            std.debug.print("TaskbarPerfZig exited early with code {d}\n", .{code});
            return 1;
        }
        overlay = findWindowForPid(class_name, pi.dwProcessId);
        if (overlay != null) break;
        w.Sleep(50);
    }

    if (overlay == null) {
        std.debug.print("Timed out waiting for TaskbarPerfZigOverlay window\n", .{});
        _ = w.TerminateProcess(pi.hProcess, 1);
        return 1;
    }

    // Confirm process stays alive briefly after creating the overlay window.
    w.Sleep(250);
    if (w.WaitForSingleObject(pi.hProcess, 0) != w.WAIT_TIMEOUT) {
        var code: w.DWORD = 1;
        _ = w.GetExitCodeProcess(pi.hProcess, &code);
        std.debug.print("TaskbarPerfZig exited unexpectedly with code {d}\n", .{code});
        return 1;
    }

    if (w.PostMessageW(overlay, w.WM_CLOSE, 0, 0) == 0) {
        std.debug.print("PostMessageW(WM_CLOSE) failed: err={d}\n", .{w.GetLastError()});
        _ = w.TerminateProcess(pi.hProcess, 1);
        return 1;
    }

    if (w.WaitForSingleObject(pi.hProcess, 3000) != w.WAIT_OBJECT_0) {
        std.debug.print("Timed out waiting for clean exit after WM_CLOSE\n", .{});
        _ = w.TerminateProcess(pi.hProcess, 1);
        return 1;
    }

    var exit_code: w.DWORD = 1;
    if (w.GetExitCodeProcess(pi.hProcess, &exit_code) == 0 or exit_code != 0) {
        std.debug.print("TaskbarPerfZig exited with non-zero code {d}\n", .{exit_code});
        return 1;
    }

    std.debug.print("smoke ok: TaskbarPerfZig started and closed cleanly\n", .{});
    return 0;
}
