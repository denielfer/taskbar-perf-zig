const std = @import("std");
const win = @import("win.zig");
const w = win.api;
const metrics = @import("metrics.zig");
const taskbar = @import("taskbar.zig");
const paint = @import("paint.zig");
const summary = @import("summary.zig");

const window_class = win.wide("TaskbarPerfZigOverlay");
const overlay_title = win.wide("TaskbarPerf Zig");
const tray_message = w.WM_APP + 1;
const track_message = w.WM_APP + 2;
const sample_ready_message = w.WM_APP + 3;
const tracker_ready_message = w.WM_APP + 4;
const show_summary_message = w.WM_APP + 5;
const track_timer = 1;
const tray_id = 1;
const exit_command = 1001;
const summary_command = 1002;
const topmost = -1;
const per_monitor_v2: w.DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

var sampler: metrics.Sampler = .{};
var tracker: taskbar.Tracker = .{};
var paint_cache: paint.Cache = .{};
var placement: ?paint.Placement = null;
var panel: summary.Panel = .{};
var overlay_window: w.HWND = null;
var last_taskbar_hwnd: w.HWND = null;
var last_bar_rect: w.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
var stable_bar_ticks: u8 = 0;
var timer_interval_ms: u32 = 0;
var taskbar_created: w.UINT = 0;
var menu_open = false;
var left_down = false;
var track_pending: std.atomic.Value(bool) = .init(false);
var display_off = false;
var session_locked = false;
var hook_foreground: w.HWINEVENTHOOK = null;
var hook_location: w.HWINEVENTHOOK = null;
var power_notify: w.HPOWERNOTIFY = null;
var wts_registered = false;

const LoadConfig64 = extern struct {
    size: u32 = 0,
    time_date_stamp: u32 = 0,
    major_version: u16 = 0,
    minor_version: u16 = 0,
    global_flags_clear: u32 = 0,
    global_flags_set: u32 = 0,
    critical_section_default_timeout: u32 = 0,
    decommit_free_block_threshold: u64 = 0,
    decommit_total_free_threshold: u64 = 0,
    lock_prefix_table: u64 = 0,
    maximum_allocation_size: u64 = 0,
    virtual_memory_threshold: u64 = 0,
    process_affinity_mask: u64 = 0,
    process_heap_flags: u32 = 0,
    csd_version: u16 = 0,
    dependent_load_flags: u16 = 0,
    reserved_ptrs_1: [8]u64 = .{0} ** 8,
    guard_flags: u32 = 0,
    code_integrity_flags: u16 = 0,
    code_integrity_catalog: u16 = 0,
    code_integrity_catalog_offset: u32 = 0,
    code_integrity_reserved: u32 = 0,
    reserved_tail: [20]u64 = .{0} ** 20,
};

comptime {
    if (@sizeOf(LoadConfig64) != 320) @compileError("Unexpected LoadConfig64 size");
    if (@offsetOf(LoadConfig64, "dependent_load_flags") != 78) @compileError("Unexpected DependentLoadFlags offset");
}

pub export const _load_config_used: LoadConfig64 align(8) = .{
    .size = @sizeOf(LoadConfig64),
    .dependent_load_flags = w.LOAD_LIBRARY_SEARCH_SYSTEM32,
};

pub fn main() u8 {
    _ = w.SetDefaultDllDirectories(w.LOAD_LIBRARY_SEARCH_SYSTEM32);

    const mutex = w.CreateMutexW(null, 0, win.wide("Local\\TaskbarPerfZig")) orelse return 1;
    const already_open = w.GetLastError() == w.ERROR_ALREADY_EXISTS;
    defer _ = w.CloseHandle(mutex);
    if (already_open) {
        if (w.FindWindowW(window_class, overlay_title)) |existing| {
            var pid: w.DWORD = 0;
            _ = w.GetWindowThreadProcessId(existing, &pid);
            if (pid != 0) _ = w.AllowSetForegroundWindow(pid);
            _ = w.PostMessageW(existing, show_summary_message, 0, 0);
        }
        return 0;
    }

    _ = w.SetProcessDpiAwarenessContext(per_monitor_v2);
    return run();
}

fn run() u8 {
    // Registered first so LIFO defers stop worker threads only after windows and GDI caches are destroyed.
    defer sampler.deinit();
    defer tracker.deinit();
    defer paint_cache.deinit();
    defer panel.deinit();

    const instance = w.GetModuleHandleW(null) orelse return 1;
    var class = std.mem.zeroes(w.WNDCLASSW);
    class.hInstance = instance;
    class.hCursor = w.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    class.lpszClassName = window_class;
    class.lpfnWndProc = windowProc;
    if (w.RegisterClassW(&class) == 0) return 1;

    taskbar_created = w.RegisterWindowMessageW(win.wide("TaskbarCreated"));
    const window = w.CreateWindowExW(
        w.WS_EX_LAYERED | w.WS_EX_NOACTIVATE | w.WS_EX_TOOLWINDOW | w.WS_EX_TOPMOST,
        window_class,
        overlay_title,
        w.WS_POPUP,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    ) orelse return 1;
    overlay_window = window;
    defer {
        overlay_window = null;
        if (w.IsWindow(window) != 0) _ = w.DestroyWindow(window);
    }

    if (w.SetLayeredWindowAttributes(window, paint.color_key, 0, w.LWA_COLORKEY) == 0) return 1;
    panel.window = createPanel(instance) orelse return 1;
    defer if (w.IsWindow(panel.window) != 0) {
        _ = w.DestroyWindow(panel.window);
    };

    defer unregisterNotifications(window);
    hook_foreground = w.SetWinEventHook(
        w.EVENT_SYSTEM_FOREGROUND,
        w.EVENT_SYSTEM_FOREGROUND,
        null,
        winEventProc,
        0,
        0,
        w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS,
    );
    installExplorerLocationHook();
    power_notify = w.RegisterPowerSettingNotification(window, &win.guid_console_display_state, w.DEVICE_NOTIFY_WINDOW_HANDLE);
    wts_registered = w.WTSRegisterSessionNotification(window, w.NOTIFY_FOR_THIS_SESSION) != 0;

    tracker.start(paint.tiles.len, window, tracker_ready_message) catch return 1;
    sampler.start(window, sample_ready_message) catch return 1;

    _ = setTrayIcon(window, w.NIM_ADD);
    setTrackTimer(window, 500);
    track(window);

    var message: w.MSG = undefined;
    while (true) {
        const result = w.GetMessageW(&message, null, 0, 0);
        if (result <= 0) return if (result == 0) 0 else 1;
        _ = w.TranslateMessage(&message);
        _ = w.DispatchMessageW(&message);
    }
}

fn isPaused() bool {
    return display_off or session_locked;
}

fn setTrackTimer(window: w.HWND, interval_ms: u32) void {
    if (interval_ms == timer_interval_ms) return;
    if (interval_ms == 0) {
        _ = w.KillTimer(window, track_timer);
        timer_interval_ms = 0;
        return;
    }
    if (w.SetTimer(window, track_timer, interval_ms, null) != 0) {
        timer_interval_ms = interval_ms;
    }
}

fn updatePauseState(window: w.HWND) void {
    const paused = isPaused();
    sampler.setPaused(paused);
    tracker.setPaused(paused);
    if (paused) {
        setTrackTimer(window, 0);
        closeSummary();
        hide(window);
    } else {
        stable_bar_ticks = 0;
        setTrackTimer(window, 16);
        tracker.requestLayoutMeasure();
        track(window);
    }
}

fn installExplorerLocationHook() void {
    if (hook_location != null) {
        _ = w.UnhookWinEvent(hook_location);
        hook_location = null;
    }
    const tray = w.FindWindowW(win.wide("Shell_TrayWnd"), null) orelse return;
    var pid: w.DWORD = 0;
    const tid = w.GetWindowThreadProcessId(tray, &pid);
    if (pid == 0 or tid == 0) return;
    hook_location = w.SetWinEventHook(
        w.EVENT_OBJECT_LOCATIONCHANGE,
        w.EVENT_OBJECT_LOCATIONCHANGE,
        null,
        winEventProc,
        pid,
        tid,
        w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS,
    );
}

fn unregisterNotifications(window: w.HWND) void {
    if (hook_foreground != null) {
        _ = w.UnhookWinEvent(hook_foreground);
        hook_foreground = null;
    }
    if (hook_location != null) {
        _ = w.UnhookWinEvent(hook_location);
        hook_location = null;
    }
    if (power_notify != null) {
        _ = w.UnregisterPowerSettingNotification(power_notify);
        power_notify = null;
    }
    if (wts_registered) {
        _ = w.WTSUnRegisterSessionNotification(window);
        wts_registered = false;
    }
}

fn winEventProc(_: w.HWINEVENTHOOK, event: w.DWORD, hwnd: w.HWND, id_object: w.LONG, id_child: w.LONG, _: w.DWORD, _: w.DWORD) callconv(.winapi) void {
    const target_overlay = overlay_window orelse return;
    if (isPaused()) return;

    if (event == w.EVENT_SYSTEM_FOREGROUND) {
        // If SetForegroundWindow failed, the panel never gets WM_ACTIVATE(WA_INACTIVE); another
        // process taking the foreground means "clicked outside". Stale events are ignored.
        if (panel.bounds != null and hwnd != null and hwnd != panel.window and hwnd != target_overlay and
            w.GetForegroundWindow() == hwnd)
        {
            panel.last_deactivated = w.GetTickCount64();
            closeSummary();
        }
        tracker.requestForegroundMeasure();
        if (!track_pending.swap(true, .acq_rel)) {
            if (w.PostMessageW(target_overlay, track_message, 0, 0) == 0) {
                track_pending.store(false, .release);
            }
        }
        return;
    }

    if (event == w.EVENT_OBJECT_LOCATIONCHANGE and id_object == w.OBJID_WINDOW and id_child == w.CHILDID_SELF and hwnd != null) {
        const target = last_taskbar_hwnd orelse w.FindWindowW(win.wide("Shell_TrayWnd"), null);
        if (target != null and hwnd == target) {
            tracker.requestLayoutMeasure();
            if (!track_pending.swap(true, .acq_rel)) {
                if (w.PostMessageW(target_overlay, track_message, 0, 0) == 0) {
                    track_pending.store(false, .release);
                }
            }
        }
    }
}

fn track(window: w.HWND) void {
    if (isPaused()) return;
    const bar = taskbar.Bar.read() orelse {
        closeSummary();
        return hide(window);
    };
    last_taskbar_hwnd = bar.window;

    const visible = bar.visiblePart();
    const rect_changed = !std.meta.eql(last_bar_rect, bar.rect);
    last_bar_rect = bar.rect;
    const partially_visible = if (visible) |vis|
        (vis.bottom - vis.top < bar.rect.bottom - bar.rect.top - taskbar.px(4, bar.dpi))
    else
        false;
    if (rect_changed or partially_visible) {
        stable_bar_ticks = 0;
        setTrackTimer(window, 16);
    } else if (stable_bar_ticks < 2) {
        stable_bar_ticks += 1;
        setTrackTimer(window, 16);
    } else {
        setTrackTimer(window, 500);
    }

    if (!(panel.bounds != null and w.GetForegroundWindow() == panel.window) and
        bar.fullscreen(window, tracker.exclusive_fullscreen.load(.monotonic)))
    {
        closeSummary();
        return hide(window);
    }

    if (panel.bounds != null) {
        const rows = blk: {
            const snap = sampler.lockSnapshot();
            defer sampler.unlockSnapshot();
            break :blk summary.rowCount(snap);
        };
        if (!panel.position(bar, rows)) closeSummary();
    }

    const vis = visible orelse return hide(window);
    const slot = tracker.slotFor(bar) orelse return hide(window);
    const next = paint.place(bar, vis, slot) orelse return hide(window);

    const redraw = if (placement) |previous|
        previous.dpi != next.dpi or previous.count != next.count or
            previous.offset_x != next.offset_x or previous.offset_y != next.offset_y or
            previous.canvas_width != next.canvas_width or previous.canvas_height != next.canvas_height or
            previous.rect.right - previous.rect.left != next.rect.right - next.rect.left or
            previous.rect.bottom - previous.rect.top != next.rect.bottom - next.rect.top
    else
        true;
    const moved = if (placement) |previous| !std.meta.eql(previous.rect, next.rect) else true;
    const lift = !menu_open and (placement == null or taskbar.isBehindTaskbar(window, bar.window));
    placement = next;
    if (moved or lift) {
        const bounds = next.rect;
        var flags: w.UINT = w.SWP_SHOWWINDOW | w.SWP_NOACTIVATE;
        if (!lift) flags |= w.SWP_NOZORDER;
        if (win.SetWindowPos(window, topmost, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top, flags) == 0) return hide(window);
    }
    if (redraw) _ = w.InvalidateRect(window, null, 0);
}

fn hide(window: w.HWND) void {
    if (placement != null) {
        _ = w.ShowWindow(window, w.SW_HIDE);
        placement = null;
    }
}

fn windowProc(window: w.HWND, message: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (message == taskbar_created and taskbar_created != 0) {
        _ = setTrayIcon(window, w.NIM_ADD);
        installExplorerLocationHook();
        tracker.requestLayoutMeasure();
        track(window);
        return 0;
    }
    switch (message) {
        w.WM_TIMER => {
            if (wp == track_timer) track(window);
            return 0;
        },
        track_message => {
            track_pending.store(false, .release);
            track(window);
            return 0;
        },
        tracker_ready_message => {
            track(window);
            return 0;
        },
        sample_ready_message => {
            if (placement != null) _ = w.InvalidateRect(window, null, 0);
            if (panel.bounds != null) {
                if (taskbar.Bar.read()) |bar| {
                    const rows = blk: {
                        const snap = sampler.lockSnapshot();
                        defer sampler.unlockSnapshot();
                        break :blk summary.rowCount(snap);
                    };
                    if (!panel.position(bar, rows)) closeSummary();
                } else {
                    closeSummary();
                }
                panel.repaint();
            }
            return 0;
        },
        show_summary_message => {
            if (!isPaused()) showSummary(window);
            return 0;
        },
        w.WM_DISPLAYCHANGE => {
            tracker.requestLayoutMeasure();
            track(window);
            return 0;
        },
        w.WM_DEVICECHANGE => {
            if (wp == w.DBT_DEVICEARRIVAL or wp == w.DBT_DEVICEREMOVECOMPLETE or wp == w.DBT_DEVNODES_CHANGED) {
                sampler.markDevicesDirty();
            }
            return 0;
        },
        w.WM_POWERBROADCAST => {
            if (wp == w.PBT_POWERSETTINGCHANGE and lp != 0) {
                const setting: *const w.POWERBROADCAST_SETTING = @ptrFromInt(@as(usize, @bitCast(lp)));
                if (std.mem.eql(u8, std.mem.asBytes(&setting.PowerSetting), std.mem.asBytes(&win.guid_console_display_state)) and
                    setting.DataLength >= 1)
                {
                    display_off = (setting.Data[0] == 0);
                    updatePauseState(window);
                }
            }
            return w.DefWindowProcW(window, message, wp, lp);
        },
        w.WM_WTSSESSION_CHANGE => {
            if (wp == w.WTS_SESSION_LOCK) {
                session_locked = true;
                updatePauseState(window);
            } else if (wp == w.WTS_SESSION_UNLOCK) {
                session_locked = false;
                updatePauseState(window);
            }
            return 0;
        },
        w.WM_PAINT => {
            const snap = sampler.lockSnapshot();
            defer sampler.unlockSnapshot();
            paint.draw(window, &paint_cache, placement, &snap.history);
            return 0;
        },
        w.WM_ERASEBKGND => return 1,
        w.WM_MOUSEACTIVATE => return w.MA_NOACTIVATE,
        w.WM_LBUTTONDOWN => {
            left_down = true;
            return 0;
        },
        w.WM_LBUTTONUP => {
            const was_down = left_down;
            left_down = false;
            if (was_down) toggleSummary(window);
            return 0;
        },
        w.WM_CAPTURECHANGED, w.WM_CANCELMODE => {
            left_down = false;
            return 0;
        },
        w.WM_RBUTTONUP, w.WM_CONTEXTMENU => {
            left_down = false;
            contextMenu(window);
            return 0;
        },
        w.WM_COMMAND => {
            switch (@as(u16, @truncate(wp))) {
                summary_command => showSummary(window),
                exit_command => _ = w.PostMessageW(window, w.WM_CLOSE, 0, 0),
                else => return w.DefWindowProcW(window, message, wp, lp),
            }
            return 0;
        },
        tray_message => {
            if (wp == tray_id) switch (lp) {
                w.WM_LBUTTONUP => toggleSummary(window),
                w.WM_RBUTTONUP, w.WM_CONTEXTMENU => contextMenu(window),
                else => {},
            };
            return 0;
        },
        w.WM_DESTROY => {
            closeSummary();
            unregisterNotifications(window);
            setTrackTimer(window, 0);
            _ = setTrayIcon(window, w.NIM_DELETE);
            w.PostQuitMessage(0);
            return 0;
        },
        else => return w.DefWindowProcW(window, message, wp, lp),
    }
}

fn createPanel(instance: w.HINSTANCE) w.HWND {
    const class_name = win.wide("TaskbarPerfZigSummary");
    var class = std.mem.zeroes(w.WNDCLASSW);
    class.hInstance = instance;
    class.hCursor = w.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    class.lpszClassName = class_name;
    class.lpfnWndProc = panelProc;
    if (w.RegisterClassW(&class) == 0) return null;
    return w.CreateWindowExW(w.WS_EX_TOOLWINDOW | w.WS_EX_TOPMOST, class_name, win.wide("Resumo de desempenho"), w.WS_POPUP, 0, 0, 0, 0, null, null, instance, null);
}

fn closeSummary() void {
    panel.close();
    sampler.setSummaryOpen(false);
}

fn showSummary(overlay: w.HWND) void {
    if (isPaused()) return;
    const bar = taskbar.Bar.read() orelse return;
    if (bar.fullscreen(overlay, tracker.exclusive_fullscreen.load(.monotonic))) return;
    if (panel.bounds == null) {
        panel.scroll = 0;
        panel.anchor = if (placement) |p| p.rect.left else bar.rect.left + taskbar.px(8, bar.dpi);
    }
    const rows = blk: {
        const snap = sampler.lockSnapshot();
        defer sampler.unlockSnapshot();
        break :blk summary.rowCount(snap);
    };
    if (panel.position(bar, rows)) {
        sampler.setSummaryOpen(true);
        if (w.SetForegroundWindow(panel.window) != 0) {
            _ = w.SetFocus(panel.window);
        }
    }
}

fn toggleSummary(overlay: w.HWND) void {
    if (panel.bounds != null) {
        closeSummary();
        return;
    }
    if (w.GetTickCount64() -| panel.last_deactivated < 250) return;
    showSummary(overlay);
}

fn coordinate(bits: usize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(bits))));
}

fn panelProc(window: w.HWND, message: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (message) {
        w.WM_PAINT => {
            const snap = sampler.lockSnapshot();
            defer sampler.unlockSnapshot();
            panel.draw(snap);
        },
        w.WM_ERASEBKGND => return 1,
        w.WM_LBUTTONUP => {
            const bits: usize = @bitCast(lp);
            panel.click(coordinate(bits), coordinate(bits >> 16));
            if (panel.bounds == null) sampler.setSummaryOpen(false);
        },
        w.WM_MOUSEWHEEL => panel.scrollBy(@divTrunc(-coordinate(wp >> 16) * taskbar.px(67, panel.dpi), w.WHEEL_DELTA)),
        w.WM_ACTIVATE => {
            if (@as(u16, @truncate(wp)) == w.WA_INACTIVE) {
                panel.last_deactivated = w.GetTickCount64();
                closeSummary();
                return 0;
            }
            return w.DefWindowProcW(window, message, wp, lp);
        },
        w.WM_CLOSE => closeSummary(),
        w.WM_KEYDOWN => switch (wp) {
            w.VK_ESCAPE => closeSummary(),
            w.VK_UP => panel.scrollBy(-taskbar.px(67, panel.dpi)),
            w.VK_DOWN => panel.scrollBy(taskbar.px(67, panel.dpi)),
            w.VK_PRIOR, w.VK_NEXT => {
                if (panel.bounds) |bounds| {
                    const distance = bounds.bottom - bounds.top - taskbar.px(78, panel.dpi);
                    panel.scrollBy(if (wp == w.VK_PRIOR) -distance else distance);
                }
            },
            else => return w.DefWindowProcW(window, message, wp, lp),
        },
        else => return w.DefWindowProcW(window, message, wp, lp),
    }
    return 0;
}

fn setTrayIcon(window: w.HWND, command: w.DWORD) bool {
    var item = std.mem.zeroes(w.NOTIFYICONDATAW);
    item.cbSize = @sizeOf(w.NOTIFYICONDATAW);
    item.hWnd = window;
    item.uID = tray_id;
    item.uFlags = w.NIF_MESSAGE | w.NIF_ICON | w.NIF_TIP;
    item.uCallbackMessage = tray_message;
    item.hIcon = w.LoadIconW(null, @ptrFromInt(32516)); // IDI_INFORMATION
    @memcpy(item.szTip[0..overlay_title.len], overlay_title);
    return w.Shell_NotifyIconW(command, &item) != 0;
}

fn contextMenu(window: w.HWND) void {
    if (menu_open) return;
    const menu = w.CreatePopupMenu() orelse return;
    defer _ = w.DestroyMenu(menu);
    if (w.AppendMenuW(menu, w.MF_STRING, summary_command, win.wide("&Abrir resumo")) == 0 or
        w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null) == 0 or
        w.AppendMenuW(menu, w.MF_STRING, exit_command, win.wide("&Encerrar TaskbarPerf")) == 0) return;
    var point: w.POINT = undefined;
    if (w.GetCursorPos(&point) == 0) return;
    var flags: w.UINT = w.TPM_RIGHTBUTTON | w.TPM_BOTTOMALIGN;
    if (taskbar.Bar.read()) |bar| {
        const screen = bar.monitor.rcMonitor;
        const gap = taskbar.px(3, bar.dpi);
        if (bar.rect.top - screen.top < screen.bottom - bar.rect.bottom) {
            flags = w.TPM_RIGHTBUTTON | w.TPM_TOPALIGN;
            point.y = bar.rect.bottom + gap;
        } else {
            point.y = bar.rect.top - gap;
        }
    }
    menu_open = true;
    defer menu_open = false;
    _ = w.SetForegroundWindow(window);
    _ = w.TrackPopupMenu(menu, flags, point.x, point.y, 0, window, null);
    _ = w.PostMessageW(window, w.WM_NULL, 0, 0);
}

test "LoadConfig64 ABI layout" {
    try std.testing.expectEqual(@as(usize, 320), @sizeOf(LoadConfig64));
    try std.testing.expectEqual(@as(usize, 78), @offsetOf(LoadConfig64, "dependent_load_flags"));
}

test {
    _ = @import("hardware.zig");
    _ = @import("network.zig");
    _ = metrics;
    _ = taskbar;
    _ = summary;
    _ = paint;
}
