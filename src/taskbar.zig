const std = @import("std");
const win = @import("win.zig");
const w = win.api;

pub const Bar = struct {
    window: w.HWND,
    rect: w.RECT,
    monitor: w.MONITORINFO,
    dpi: u32,

    pub fn read() ?Bar {
        const window = w.FindWindowW(win.wide("Shell_TrayWnd"), null) orelse return null;
        if (w.IsWindowVisible(window) == 0) return null;
        var rect: w.RECT = undefined;
        if (w.GetWindowRect(window, &rect) == 0) return null;
        if (rect.right - rect.left <= rect.bottom - rect.top) return null;
        const display = w.MonitorFromWindow(window, w.MONITOR_DEFAULTTONEAREST) orelse return null;
        var monitor = std.mem.zeroes(w.MONITORINFO);
        monitor.cbSize = @sizeOf(w.MONITORINFO);
        if (w.GetMonitorInfoW(display, &monitor) == 0) return null;
        const dpi = w.GetDpiForWindow(window);
        return .{ .window = window, .rect = rect, .monitor = monitor, .dpi = if (dpi == 0) 96 else dpi };
    }

    pub fn fullscreen(self: Bar, overlay: w.HWND, exclusive: bool) bool {
        const fg = w.GetForegroundWindow() orelse return exclusive;
        if (fg == self.window or fg == overlay or w.IsIconic(fg) != 0 or w.IsWindowVisible(fg) == 0) return false;
        var class: [64]u16 = undefined;
        const count = w.GetClassNameW(fg, &class, class.len);
        if (count <= 0) return false;
        for ([_][]const u16{ win.wide("Progman"), win.wide("WorkerW"), win.wide("Shell_SecondaryTrayWnd") }) |name| {
            if (std.mem.eql(u16, class[0..@intCast(count)], name)) return false;
        }

        const monitor = self.monitor.rcMonitor;
        var rect: w.RECT = undefined;
        if (w.DwmGetWindowAttribute(fg, w.DWMWA_EXTENDED_FRAME_BOUNDS, &rect, @sizeOf(w.RECT)) < 0 and
            w.GetWindowRect(fg, &rect) == 0) return false;
        if (rect.right <= monitor.left or rect.left >= monitor.right or
            rect.bottom <= monitor.top or rect.top >= monitor.bottom) return false;
        if (exclusive) return true;

        const style = w.GetWindowLongW(fg, w.GWL_STYLE);
        if (w.IsZoomed(fg) != 0 and (style & w.WS_CAPTION) == w.WS_CAPTION) return false;
        // The visible DWM frame excludes the resize borders of ordinary maximized windows.
        const tolerance = px(2, self.dpi);
        return rect.left <= monitor.left + tolerance and rect.right >= monitor.right - tolerance and
            rect.top <= monitor.top + tolerance and rect.bottom >= monitor.bottom - tolerance;
    }

    pub fn visiblePart(self: Bar) ?w.RECT {
        var visible: w.RECT = undefined;
        if (w.IntersectRect(&visible, &self.rect, &self.monitor.rcMonitor) == 0) return null;
        if (visible.bottom - visible.top < px(6, self.dpi)) return null;
        return visible;
    }
};

pub fn px(dip: i32, dpi: u32) i32 {
    return w.MulDiv(dip, @intCast(dpi), 96);
}

pub fn isBehindTaskbar(overlay: w.HWND, taskbar_hwnd: w.HWND) bool {
    var cur: w.HWND = overlay;
    for (0..128) |_| {
        cur = w.GetWindow(cur, w.GW_HWNDPREV);
        if (cur == null) break;
        if (cur == taskbar_hwnd) return true;
    }
    return false;
}

const Interval = struct { left: i32, right: i32 };

pub const Slot = struct { x: i32, width: i32, tiles: usize };
const tile_width = 72;
pub const tile_gap = 4;

const automation_class: w.GUID = .{
    .Data1 = 0xe22ad333,
    .Data2 = 0xb25f,
    .Data3 = 0x460c,
    .Data4 = .{ 0x83, 0xd0, 0x05, 0x81, 0x10, 0x73, 0x95, 0xc9 },
};
const automation_iid: w.GUID = .{
    .Data1 = 0x30cbe57d,
    .Data2 = 0xd9d0,
    .Data3 = 0x452a,
    .Data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee },
};

const control_types = [_]w.CONTROLTYPEID{
    w.UIA_ButtonControlTypeId,
    w.UIA_SplitButtonControlTypeId,
    w.UIA_MenuItemControlTypeId,
    w.UIA_ListItemControlTypeId,
    w.UIA_TabItemControlTypeId,
    w.UIA_CheckBoxControlTypeId,
    w.UIA_EditControlTypeId,
};

const VariantI4 = extern struct {
    vt: u16 = 3, // VT_I4
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    lval: i32,
    pad: [3]u32 = .{ 0, 0, 0 },
};

comptime {
    if (@sizeOf(VariantI4) != @sizeOf(w.VARIANT)) @compileError("Unexpected VARIANT size");
}

fn variantI4(value: i32) w.VARIANT {
    var out: w.VARIANT = undefined;
    const raw = VariantI4{ .lval = value };
    @memcpy(std.mem.asBytes(&out), std.mem.asBytes(&raw));
    return out;
}

const UiaResources = struct {
    automation: *w.IUIAutomation,
    condition: *w.IUIAutomationCondition,
    cache: *w.IUIAutomationCacheRequest,
    uses_true_condition: bool = false,

    fn createControlTypeCondition(automation: *w.IUIAutomation) ?*w.IUIAutomationCondition {
        const vtable = automation.lpVtbl.*;
        var props: [control_types.len]?*w.IUIAutomationCondition = @splat(null);
        defer for (props) |maybe_cond| {
            if (maybe_cond) |cond| _ = cond.lpVtbl.*.Release.?(cond);
        };

        for (control_types, 0..) |ct, idx| {
            if (vtable.CreatePropertyCondition.?(automation, w.UIA_ControlTypePropertyId, variantI4(ct), &props[idx]) < 0 or props[idx] == null) {
                return null;
            }
        }

        var combined: ?*w.IUIAutomationCondition = null;
        if (vtable.CreateOrConditionFromNativeArray.?(automation, @ptrCast(&props), @intCast(props.len), &combined) < 0) {
            return null;
        }
        return combined;
    }

    fn init() ?UiaResources {
        var object: ?*anyopaque = null;
        if (w.CoCreateInstance(&automation_class, null, w.CLSCTX_INPROC_SERVER, &automation_iid, &object) < 0) return null;
        const automation: *w.IUIAutomation = @ptrCast(@alignCast(object orelse return null));
        errdefer _ = automation.lpVtbl.*.Release.?(automation);

        const vtable = automation.lpVtbl.*;
        var uses_true_condition = false;
        const condition = createControlTypeCondition(automation) orelse blk: {
            var raw_cond: ?*w.IUIAutomationCondition = null;
            if (vtable.CreateTrueCondition.?(automation, &raw_cond) < 0) return null;
            uses_true_condition = true;
            break :blk raw_cond orelse return null;
        };
        errdefer _ = condition.lpVtbl.*.Release.?(condition);

        var raw_cache: ?*w.IUIAutomationCacheRequest = null;
        if (vtable.CreateCacheRequest.?(automation, &raw_cache) < 0) return null;
        const cache = raw_cache orelse return null;
        errdefer _ = cache.lpVtbl.*.Release.?(cache);

        if (uses_true_condition) {
            if (cache.lpVtbl.*.AddProperty.?(cache, w.UIA_ControlTypePropertyId) < 0) return null;
        }
        if (cache.lpVtbl.*.AddProperty.?(cache, w.UIA_BoundingRectanglePropertyId) < 0 or
            cache.lpVtbl.*.put_AutomationElementMode.?(cache, w.AutomationElementMode_None) < 0)
        {
            return null;
        }

        return .{
            .automation = automation,
            .condition = condition,
            .cache = cache,
            .uses_true_condition = uses_true_condition,
        };
    }

    fn deinit(self: UiaResources) void {
        _ = self.cache.lpVtbl.*.Release.?(self.cache);
        _ = self.condition.lpVtbl.*.Release.?(self.condition);
        _ = self.automation.lpVtbl.*.Release.?(self.automation);
    }
};

pub const Tracker = struct {
    mutex: std.Thread.Mutex = .{},
    stop: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    layout_requested: std.atomic.Value(bool) = .init(true),
    foreground_requested: std.atomic.Value(bool) = .init(false),
    wake_pending: std.atomic.Value(bool) = .init(false),
    wake: std.Thread.ResetEvent = .{},
    finished: std.Thread.ResetEvent = .{},
    thread: ?std.Thread = null,
    snapshot: ?struct { bar: Bar, slot: ?Slot } = null,
    exclusive_fullscreen: std.atomic.Value(bool) = .init(false),
    notify_window: w.HWND = null,
    notify_message: w.UINT = 0,

    pub fn start(self: *Tracker, max_tiles: usize, notify_window: w.HWND, notify_message: w.UINT) !void {
        self.notify_window = notify_window;
        self.notify_message = notify_message;
        self.thread = try std.Thread.spawn(.{}, watch, .{ self, max_tiles });
    }

    pub fn deinit(self: *Tracker) void {
        self.stop.store(true, .release);
        self.signalWake();
        if (self.thread) |thread| {
            if (self.finished.timedWait(1000 * std.time.ns_per_ms)) |_| {
                thread.join();
            } else |_| {
                thread.detach();
            }
            self.thread = null;
        }
    }

    pub fn setPaused(self: *Tracker, value: bool) void {
        const previous = self.paused.swap(value, .acq_rel);
        if (previous != value) {
            if (!value) self.layout_requested.store(true, .release);
            self.signalWake();
        }
    }

    pub fn requestLayoutMeasure(self: *Tracker) void {
        self.layout_requested.store(true, .release);
        self.signalWake();
    }

    pub fn requestForegroundMeasure(self: *Tracker) void {
        self.foreground_requested.store(true, .release);
        self.signalWake();
    }

    pub fn slotFor(self: *Tracker, bar: Bar) ?Slot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const snapshot = self.snapshot orelse return null;
        return if (sameLayout(snapshot.bar, bar)) snapshot.slot else null;
    }

    fn signalWake(self: *Tracker) void {
        self.wake_pending.store(true, .release);
        self.wake.set();
    }

    fn watch(self: *Tracker, max_tiles: usize) void {
        defer self.finished.set();

        const com_ready = w.CoInitializeEx(null, w.COINIT_MULTITHREADED) >= 0;
        defer if (com_ready) w.CoUninitialize();

        const uia = if (com_ready) UiaResources.init() else null;
        defer if (uia) |res| res.deinit();

        // Explorer queries can block while it animates the taskbar. Keep them off the window thread.
        var previous: ?Bar = null;
        var measured: ?Bar = null;
        var refreshed: u64 = 0;
        var last_slot: ?Slot = null;
        var has_published = false;

        while (!self.stop.load(.acquire)) {
            if (self.paused.load(.acquire)) {
                self.wake.reset();
                if (self.wake_pending.swap(false, .seq_cst)) continue;
                if (self.stop.load(.acquire) or !self.paused.load(.acquire)) continue;
                self.wake.wait();
                continue;
            }

            var state: w.QUERY_USER_NOTIFICATION_STATE = undefined;
            const exclusive = w.SHQueryUserNotificationState(&state) >= 0 and state == w.QUNS_RUNNING_D3D_FULL_SCREEN;
            // The UI reads this flag in track(); without a nudge it would only see the change on its next tick.
            if (self.exclusive_fullscreen.swap(exclusive, .monotonic) != exclusive and
                self.notify_window != null and self.notify_message != 0)
            {
                _ = w.PostMessageW(self.notify_window, self.notify_message, 0, 0);
            }

            const now = w.GetTickCount64();
            var wait_ms: u64 = 5000;

            if (Bar.read()) |bar| {
                const prior = previous;
                previous = bar;
                const visible = bar.visiblePart();
                const full_height = visible != null and
                    (visible.?.bottom - visible.?.top >= bar.rect.bottom - bar.rect.top - px(4, bar.dpi));
                const rect_stable = prior != null and std.meta.eql(prior.?.rect, bar.rect);

                if (!rect_stable) {
                    wait_ms = 125;
                } else if (!full_height) {
                    // Auto-hide taskbar is resting hidden; sleep until LOCATIONCHANGE wakes us.
                    wait_ms = 5000;
                } else {
                    const layout_changed = measured == null or !sameLayout(measured.?, bar);
                    const since_refresh = now -| refreshed;
                    const layout_req = self.layout_requested.load(.acquire);
                    const fg_req = self.foreground_requested.load(.acquire);
                    const should_measure = layout_changed or
                        since_refresh >= 5000 or
                        (layout_req and since_refresh >= 300) or
                        (fg_req and since_refresh >= 1500);

                    if (should_measure) {
                        self.layout_requested.store(false, .release);
                        self.foreground_requested.store(false, .release);
                        measured = bar;
                        refreshed = now;
                        const slot = if (uia) |res|
                            (measure(res, bar, max_tiles) catch fallbackSlot(bar, max_tiles))
                        else
                            fallbackSlot(bar, max_tiles);

                        const slot_changed = !has_published or !sameOptionalSlot(last_slot, slot);
                        last_slot = slot;
                        has_published = true;

                        self.mutex.lock();
                        self.snapshot = .{ .bar = bar, .slot = slot };
                        self.mutex.unlock();

                        if (slot_changed and self.notify_window != null and self.notify_message != 0) {
                            _ = w.PostMessageW(self.notify_window, self.notify_message, 0, 0);
                        }
                    } else if (layout_req) {
                        wait_ms = 300 -| since_refresh;
                    } else if (fg_req) {
                        wait_ms = 1500 -| since_refresh;
                    } else {
                        wait_ms = 5000 -| since_refresh;
                    }
                }
            }

            self.wake.reset();
            if (self.wake_pending.swap(false, .seq_cst)) continue;
            if (self.stop.load(.acquire) or self.paused.load(.acquire)) continue;
            _ = self.wake.timedWait(wait_ms * std.time.ns_per_ms) catch {};
        }
    }

    fn measure(uia: UiaResources, bar: Bar, max_tiles: usize) error{AccessibilityUnavailable}!?Slot {
        const unavailable = error.AccessibilityUnavailable;
        const vtable = uia.automation.lpVtbl.*;
        var root: ?*w.IUIAutomationElement = null;
        if (vtable.ElementFromHandle.?(uia.automation, bar.window, &root) < 0) return unavailable;
        const element = root orelse return unavailable;
        defer _ = element.lpVtbl.*.Release.?(element);

        var result: ?*w.IUIAutomationElementArray = null;
        if (element.lpVtbl.*.FindAllBuildCache.?(element, w.TreeScope_Descendants, uia.condition, uia.cache, &result) < 0) return unavailable;
        const elements = result orelse return unavailable;
        defer _ = elements.lpVtbl.*.Release.?(elements);

        var count: c_int = 0;
        if (elements.lpVtbl.*.get_Length.?(elements, &count) < 0) return unavailable;

        var occupied: [256]Interval = undefined;
        var occupied_len: usize = 0;
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            var child: ?*w.IUIAutomationElement = null;
            if (elements.lpVtbl.*.GetElement.?(elements, i, &child) < 0) continue;
            const item = child orelse continue;
            defer _ = item.lpVtbl.*.Release.?(item);

            if (uia.uses_true_condition) {
                var kind: w.CONTROLTYPEID = 0;
                if (item.lpVtbl.*.get_CachedControlType.?(item, &kind) < 0) continue;
                switch (kind) {
                    w.UIA_ButtonControlTypeId,
                    w.UIA_SplitButtonControlTypeId,
                    w.UIA_MenuItemControlTypeId,
                    w.UIA_ListItemControlTypeId,
                    w.UIA_TabItemControlTypeId,
                    w.UIA_CheckBoxControlTypeId,
                    w.UIA_EditControlTypeId,
                    => {},
                    else => continue,
                }
            }

            var rect: w.RECT = undefined;
            var intersection: w.RECT = undefined;
            if (item.lpVtbl.*.get_CachedBoundingRectangle.?(item, &rect) < 0) continue;
            if (w.IntersectRect(&intersection, &rect, &bar.rect) == 0) continue;
            if (occupied_len < occupied.len) {
                occupied[occupied_len] = .{
                    .left = intersection.left - bar.rect.left,
                    .right = intersection.right - bar.rect.left,
                };
                occupied_len += 1;
            }
        }

        const items = occupied[0..occupied_len];
        if (items.len == 0) return unavailable;
        std.mem.sort(Interval, items, {}, struct {
            fn less(_: void, a: Interval, b: Interval) bool {
                return a.left < b.left;
            }
        }.less);
        return findSlot(items, @divTrunc(bar.rect.right - bar.rect.left, 2), bar.dpi, max_tiles);
    }
};

fn sameOptionalSlot(a: ?Slot, b: ?Slot) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.meta.eql(a.?, b.?);
}

fn fallbackSlot(bar: Bar, max_tiles: usize) ?Slot {
    const margin = px(8, bar.dpi);
    const limit = @divTrunc(bar.rect.right - bar.rect.left, 2);
    var best: ?Slot = null;
    updateSlot(&best, margin, limit, px(tile_width, bar.dpi), px(tile_gap, bar.dpi), max_tiles);
    return best;
}

fn sameLayout(a: Bar, b: Bar) bool {
    return a.window == b.window and a.dpi == b.dpi and a.rect.right - a.rect.left == b.rect.right - b.rect.left;
}

fn findSlot(occupied: []const Interval, limit: i32, dpi: u32, max_tiles: usize) ?Slot {
    const margin = px(6, dpi);
    const tile = px(tile_width, dpi);
    const gap = px(tile_gap, dpi);
    var best: ?Slot = null;
    var left = margin;
    for (occupied) |item| {
        updateSlot(&best, left, @min(item.left - margin, limit), tile, gap, max_tiles);
        left = @max(left, item.right + margin);
        if (left >= limit or (best != null and best.?.tiles == max_tiles)) return best;
    }
    updateSlot(&best, left, limit, tile, gap, max_tiles);
    return best;
}

fn updateSlot(best: *?Slot, left: i32, right: i32, tile: i32, gap: i32, max_tiles: usize) void {
    if (right - left < tile) return;
    const count = @min(max_tiles, @as(usize, @intCast(@divTrunc(right - left + gap, tile + gap))));
    if (best.* != null and best.*.?.tiles >= count) return;
    best.* = .{ .x = left, .width = @as(i32, @intCast(count)) * (tile + gap) - gap, .tiles = count };
}

test "findSlot locates largest gap on left half" {
    const occupied = [_]Interval{
        .{ .left = 0, .right = 48 },
        .{ .left = 450, .right = 600 },
    };
    const slot = findSlot(&occupied, 960, 96, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 5), slot.tiles);
    try std.testing.expectEqual(@as(i32, 54), slot.x);
    try std.testing.expectEqual(@as(i32, 5 * 72 + 4 * 4), slot.width);

    const prefer_second = [_]Interval{
        .{ .left = 0, .right = 48 },
        .{ .left = 400, .right = 560 },
    };
    const second = findSlot(&prefer_second, 960, 96, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 5), second.tiles);
    try std.testing.expectEqual(@as(i32, 566), second.x);
}

test "findSlot returns null when gap is too narrow" {
    const occupied = [_]Interval{
        .{ .left = 0, .right = 50 },
        .{ .left = 90, .right = 960 },
    };
    try std.testing.expectEqual(@as(?Slot, null), findSlot(&occupied, 960, 96, 5));
}
