const std = @import("std");
const win = @import("win.zig");
const w = win.api;
const metrics = @import("metrics.zig");
const taskbar = @import("taskbar.zig");
const paint = @import("paint.zig");
const rgb = paint.rgb;
const px = taskbar.px;

const bg = rgb(17, 20, 27);
const border = rgb(54, 63, 78);
const card = rgb(27, 32, 42);
const primary = rgb(242, 245, 251);
const muted = rgb(166, 178, 198);
const send_color = rgb(247, 194, 122);
const header = 66;
const row_height = 67;
const padding = 12;

pub const Panel = struct {
    window: w.HWND = null,
    bounds: ?w.RECT = null,
    anchor: i32 = 0,
    dpi: u32 = 96,
    scroll: i32 = 0,
    max_scroll: i32 = 0,
    rows: usize = 0,
    last_deactivated: u64 = 0,
    surface: paint.Surface = .{},
    font_dpi: u32 = 0,
    heading_font: w.HFONT = null,
    title_font: w.HFONT = null,
    small_font: w.HFONT = null,

    pub fn deinit(self: *Panel) void {
        if (self.heading_font != null) _ = w.DeleteObject(self.heading_font);
        if (self.title_font != null) _ = w.DeleteObject(self.title_font);
        if (self.small_font != null) _ = w.DeleteObject(self.small_font);
        self.heading_font = null;
        self.title_font = null;
        self.small_font = null;
        self.font_dpi = 0;
        self.surface.deinit();
    }

    fn ensureFonts(self: *Panel, dpi: u32) bool {
        if (self.font_dpi == dpi and self.heading_font != null and self.title_font != null and self.small_font != null) {
            return true;
        }
        const heading = paint.font(23, dpi, w.FW_SEMIBOLD) orelse return false;
        const title = paint.font(15, dpi, w.FW_SEMIBOLD) orelse {
            _ = w.DeleteObject(heading);
            return false;
        };
        const small = paint.font(12, dpi, w.FW_NORMAL) orelse {
            _ = w.DeleteObject(title);
            _ = w.DeleteObject(heading);
            return false;
        };
        if (self.heading_font != null) _ = w.DeleteObject(self.heading_font);
        if (self.title_font != null) _ = w.DeleteObject(self.title_font);
        if (self.small_font != null) _ = w.DeleteObject(self.small_font);
        self.heading_font = heading;
        self.title_font = title;
        self.small_font = small;
        self.font_dpi = dpi;
        return true;
    }

    pub fn close(self: *Panel) void {
        if (self.bounds == null) return;
        self.bounds = null;
        if (self.window != null and w.IsWindow(self.window) != 0) {
            _ = w.ShowWindow(self.window, w.SW_HIDE);
        }
        // Back buffer and fonts are released while hidden and rebuilt on the next draw.
        self.deinit();
    }

    pub fn position(self: *Panel, bar: taskbar.Bar, rows: usize) bool {
        const screen = bar.monitor.rcMonitor;
        const dpi = bar.dpi;
        const gap = px(8, dpi);
        const thickness = bar.rect.bottom - bar.rect.top;
        const width = @min(px(398, dpi), screen.right - screen.left - 2 * gap);
        const content = @as(i32, @intCast(rows)) * px(row_height, dpi);
        const chrome = px(header + padding, dpi);
        const height = @min(chrome + content, screen.bottom - screen.top - thickness - 2 * gap);
        if (width <= 0 or height <= chrome) return false;
        const x = std.math.clamp(self.anchor, screen.left + gap, screen.right - gap - width);
        const at_top = bar.rect.top - screen.top < screen.bottom - bar.rect.bottom;
        const y = if (at_top) screen.top + thickness + gap else screen.bottom - thickness - gap - height;
        const bounds: w.RECT = .{ .left = x, .top = y, .right = x + width, .bottom = y + height };

        const first = self.bounds == null;
        const moved = first or !std.meta.eql(self.bounds.?, bounds);
        const redraw = moved or self.dpi != dpi or self.rows != rows;
        self.dpi = dpi;
        self.rows = rows;
        self.max_scroll = @max(0, content - (height - chrome));
        self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);
        if (moved) {
            var flags: w.UINT = w.SWP_SHOWWINDOW | w.SWP_NOACTIVATE;
            if (!first) flags |= w.SWP_NOZORDER;
            self.bounds = bounds;
            if (win.SetWindowPos(self.window, -1, x, y, width, height, flags) == 0) {
                self.close();
                return false;
            }
        }
        if (redraw) self.repaint();
        return true;
    }

    pub fn repaint(self: Panel) void {
        if (self.bounds != null) _ = w.InvalidateRect(self.window, null, 0);
    }

    pub fn scrollBy(self: *Panel, distance: i32) void {
        const next = std.math.clamp(self.scroll + distance, 0, self.max_scroll);
        if (next == self.scroll) return;
        self.scroll = next;
        self.repaint();
    }

    pub fn click(self: *Panel, x: i32, y: i32) void {
        const bounds = self.bounds orelse return;
        const client: w.RECT = .{ .left = 0, .top = 0, .right = bounds.right - bounds.left, .bottom = bounds.bottom - bounds.top };
        const button = closeButton(client, self.dpi);
        if (x >= button.left and x < button.right and y >= button.top and y < button.bottom) return self.close();
        if (self.max_scroll > 0 and x >= client.right - px(padding, self.dpi)) {
            const body = bodyRect(client, self.dpi);
            if (y >= body.top and y < body.bottom) {
                const thumb = scrollThumb(body, self.max_scroll, self.scroll);
                if (y < thumb.top) self.scrollBy(body.top - body.bottom);
                if (y >= thumb.bottom) self.scrollBy(body.bottom - body.top);
            }
        }
    }

    pub fn draw(self: *Panel, snapshot: *const metrics.Snapshot) void {
        var ps: w.PAINTSTRUCT = undefined;
        const screen = w.BeginPaint(self.window, &ps) orelse return;
        defer _ = w.EndPaint(self.window, &ps);
        var client: w.RECT = undefined;
        if (w.GetClientRect(self.window, &client) == 0) return;
        const dc = self.surface.ensure(screen, client.right, client.bottom) orelse return;
        const dpi = self.dpi;
        if (!self.ensureFonts(dpi)) return;

        paint.fill(dc, client, border);
        paint.fill(dc, .{ .left = 1, .top = 1, .right = client.right - 1, .bottom = client.bottom - 1 }, bg);
        const button = closeButton(client, dpi);
        paint.fill(dc, button, card);
        const original = w.SelectObject(dc, self.heading_font);
        defer _ = w.SelectObject(dc, original);
        label(dc, win.wide("Desempenho"), px(16, dpi), px(10, dpi), button.left - px(8, dpi), px(30, dpi), primary);
        _ = w.SelectObject(dc, self.small_font);
        label(dc, win.wide("Últimos 60 segundos"), px(17, dpi), px(40, dpi), button.left, px(16, dpi), muted);
        label(dc, win.wide("×"), button.left + px(11, dpi), button.top, button.right, button.bottom - button.top, primary);

        const body = bodyRect(client, dpi);
        const saved = w.SaveDC(dc);
        _ = w.IntersectClipRect(dc, body.left, body.top, body.right, body.bottom);
        var row: Rows = .{
            .dc = dc,
            .body = body,
            .dpi = dpi,
            .title = self.title_font,
            .small = self.small_font,
            .y = body.top - self.scroll,
        };
        drawRows(&row, snapshot);
        if (saved != 0) _ = w.RestoreDC(dc, saved);

        if (self.max_scroll > 0) {
            const thumb = scrollThumb(body, self.max_scroll, self.scroll);
            const track_x = body.right + px(5, dpi);
            paint.fill(dc, .{ .left = track_x, .right = track_x + px(3, dpi), .top = body.top, .bottom = body.bottom }, card);
            paint.fill(dc, .{ .left = track_x, .right = track_x + px(3, dpi), .top = thumb.top, .bottom = thumb.bottom }, muted);
        }
        self.surface.present(screen, client);
    }
};

pub fn rowCount(snapshot: *const metrics.Snapshot) usize {
    return 2 + @max(1, snapshot.disks.items.len) + @max(1, snapshot.networks.items.len) + @max(1, snapshot.gpus.items.len);
}

fn bodyRect(client: w.RECT, dpi: u32) w.RECT {
    return .{ .left = px(padding, dpi), .right = client.right - px(padding, dpi), .top = px(header, dpi), .bottom = client.bottom - px(padding, dpi) };
}

fn closeButton(client: w.RECT, dpi: u32) w.RECT {
    return .{ .left = client.right - px(44, dpi), .right = client.right - px(13, dpi), .top = px(13, dpi), .bottom = px(43, dpi) };
}

fn scrollThumb(body: w.RECT, max_scroll: i32, scroll: i32) struct { top: i32, bottom: i32 } {
    const height = body.bottom - body.top;
    if (height <= 0 or max_scroll <= 0) return .{ .top = body.top, .bottom = body.top };
    const clamped_scroll = std.math.clamp(scroll, 0, max_scroll);
    const thumb = @max(@min(20, height), @divTrunc(height * height, height + max_scroll));
    const top = body.top + @divTrunc((height - thumb) * clamped_scroll, max_scroll);
    return .{ .top = top, .bottom = top + thumb };
}

const Rows = struct {
    dc: w.HDC,
    body: w.RECT,
    dpi: u32,
    title: w.HFONT,
    small: w.HFONT,
    y: i32,

    fn add(self: *Rows, kind: metrics.Kind, name: []const u16, description: []const u16, value: []const u16, history: *const metrics.Series, extra: ?*const metrics.Series) void {
        const y = self.y;
        self.y += px(row_height, self.dpi);
        if (self.y <= self.body.top or y >= self.body.bottom) return;

        const dpi = self.dpi;
        const dc = self.dc;
        const palette = paint.tiles[@intFromEnum(kind)];
        paint.fill(dc, .{ .left = self.body.left, .top = y, .right = self.body.right, .bottom = self.y - px(5, dpi) }, card);
        const chart: w.RECT = .{ .left = self.body.left + px(9, dpi), .top = y + px(10, dpi), .right = self.body.left + px(105, dpi), .bottom = y + px(52, dpi) };
        paint.fill(dc, chart, border);
        const inside: w.RECT = .{ .left = chart.left + 1, .right = chart.right - 1, .top = chart.top + 1, .bottom = chart.bottom - 1 };
        paint.fill(dc, inside, palette.plot);
        const center = @divTrunc(inside.top + inside.bottom, 2);
        paint.fill(dc, .{ .left = inside.left, .right = inside.right, .top = center, .bottom = center + 1 }, border);
        const scale = @max(history.scale(kind), if (extra) |other| other.scale(kind) else 0);
        if (extra) |series| paint.plot(dc, inside, send_color, series, scale);
        paint.plot(dc, inside, palette.accent, history, scale);

        const left = chart.right + px(12, dpi);
        const right = self.body.right - px(10, dpi);
        const line = px(15, dpi);
        const named = description.len != 0;
        _ = w.SelectObject(dc, self.title);
        label(dc, name, left, y + px(if (named) 6 else 12, dpi), right, px(19, dpi), primary);
        _ = w.SelectObject(dc, self.small);
        if (named) label(dc, description, left, y + px(25, dpi), right, line, muted);
        label(dc, value, left, y + px(if (named) 41 else 33, dpi), right, line, palette.accent);
    }
};

fn drawRows(row: *Rows, data: *const metrics.Snapshot) void {
    const cpu = &data.history[@intFromEnum(metrics.Kind.cpu)];
    const ram = &data.history[@intFromEnum(metrics.Kind.ram)];
    var usage: [128]u16 = undefined;
    var name: [128]u16 = undefined;
    var percent_buffer: [16]u8 = undefined;
    const cpu_pct = percent(&percent_buffer, cpu.latest());
    const speed = if (data.cpu_ghz) |ghz| format(&usage, "{s}   {d:.2} GHz", .{ cpu_pct, ghz }) else format(&usage, "{s}", .{cpu_pct});
    row.add(.cpu, win.wide("CPU"), &.{}, speed, cpu, null);
    const memory = if (data.memory) |m| format(&usage, "{d:.1} / {d:.1} GB   ({s})", .{
        @as(f64, @floatFromInt(m.used)) / 1073741824, @as(f64, @floatFromInt(m.total)) / 1073741824, percent(&percent_buffer, ram.latest()),
    }) else win.wide("—");
    row.add(.ram, win.wide("Memória"), &.{}, memory, ram, null);

    for (data.disks.items) |*disk| {
        const letters = std.mem.sliceTo(&disk.letters, 0);
        const prefix = format(&name, "Disco {d}", .{disk.index});
        var length = prefix.len;
        if (letters.len != 0) {
            @memcpy(name[length..][0..2], win.wide(" ("));
            length += 2;
            @memcpy(name[length..][0..letters.len], letters);
            length += letters.len;
            name[length] = ')';
            length += 1;
        }
        row.add(.disk, name[0..length], disk.media, format(&usage, "{s}", .{percent(&percent_buffer, disk.activity.latest())}), &disk.activity, null);
    }
    if (data.disks.items.len == 0) row.add(.disk, win.wide("Disco"), &.{}, win.wide("—"), &data.history[@intFromEnum(metrics.Kind.disk)], null);

    for (data.networks.items) |*net| {
        var sent: [24]u8 = undefined;
        var received: [24]u8 = undefined;
        const text = format(&usage, "Envio {s}   Receb. {s}", .{ rate(&sent, net.sent.latest()), rate(&received, net.received.latest()) });
        row.add(.network, std.mem.sliceTo(&net.name, 0), std.mem.sliceTo(&net.description, 0), text, &net.received, &net.sent);
    }
    if (data.networks.items.len == 0) row.add(.network, win.wide("Rede"), &.{}, win.wide("—"), &data.history[@intFromEnum(metrics.Kind.network)], null);

    for (data.gpus.items, 0..) |*gpu, i| {
        const pct = percent(&percent_buffer, gpu.activity.latest());
        const text = if (gpu.temperature) |temp| format(&usage, "{s}   ({d:.0} °C)", .{ pct, temp }) else format(&usage, "{s}", .{pct});
        row.add(.gpu, format(&name, "GPU {d}", .{i}), std.mem.sliceTo(&gpu.name, 0), text, &gpu.activity, null);
    }
    if (data.gpus.items.len == 0) {
        const gpu = &data.history[@intFromEnum(metrics.Kind.gpu)];
        row.add(.gpu, win.wide("GPU"), &.{}, format(&usage, "{s}", .{percent(&percent_buffer, gpu.latest())}), gpu, null);
    }
}

fn label(dc: w.HDC, value: []const u16, left: i32, y: i32, right: i32, height: i32, color: w.COLORREF) void {
    if (right <= left or value.len == 0) return;
    var rect: w.RECT = .{ .left = left, .top = y, .right = right, .bottom = y + height };
    _ = w.SetTextColor(dc, color);
    _ = w.DrawTextW(dc, value.ptr, @intCast(value.len), &rect, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_END_ELLIPSIS | w.DT_NOPREFIX);
}

fn format(out: []u16, comptime template: []const u8, args: anytype) []const u16 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, template, args) catch return win.wide("—");
    for (text, 0..) |byte, i| {
        if (byte == '.' and i > 0 and i + 1 < text.len and std.ascii.isDigit(text[i - 1]) and std.ascii.isDigit(text[i + 1])) buffer[i] = ',';
    }
    const len = std.unicode.utf8ToUtf16Le(out, text) catch return win.wide("—");
    return out[0..len];
}

fn percent(buffer: []u8, value: ?f64) []const u8 {
    const number = value orelse return "—";
    return std.fmt.bufPrint(buffer, "{d:.0}%", .{number}) catch "—";
}

fn rate(buffer: []u8, value: ?f64) []const u8 {
    const bytes = value orelse return "—";
    if (bytes >= 125_000_000) return std.fmt.bufPrint(buffer, "{d:.1} Gbps", .{bytes / 125_000_000}) catch "—";
    if (bytes >= 125_000) return std.fmt.bufPrint(buffer, "{d:.1} Mbps", .{bytes / 125_000}) catch "—";
    return std.fmt.bufPrint(buffer, "{d:.0} Kbps", .{bytes / 125}) catch "—";
}

test "scrollThumb handles degenerate body and clamps cleanly" {
    const empty_body: w.RECT = .{ .left = 10, .top = 50, .right = 200, .bottom = 50 };
    const zero = scrollThumb(empty_body, 100, 20);
    try std.testing.expectEqual(@as(i32, 50), zero.top);
    try std.testing.expectEqual(@as(i32, 50), zero.bottom);

    const body: w.RECT = .{ .left = 10, .top = 60, .right = 200, .bottom = 260 };
    const bottom = scrollThumb(body, 200, 999);
    try std.testing.expect(bottom.bottom <= body.bottom);
    try std.testing.expect(bottom.top >= body.top);
}
