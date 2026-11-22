const std = @import("std");
const win = @import("win.zig");
const w = win.api;
const metrics = @import("metrics.zig");
const taskbar = @import("taskbar.zig");
const px = taskbar.px;

pub const Tile = struct {
    label: [:0]const u16,
    accent: w.COLORREF,
    plot: w.COLORREF,
};

pub const tiles = [_]Tile{
    .{ .label = win.wide("CPU"), .accent = rgb(103, 218, 251), .plot = rgb(17, 44, 55) },
    .{ .label = win.wide("RAM"), .accent = rgb(143, 177, 255), .plot = rgb(28, 39, 64) },
    .{ .label = win.wide("GPU"), .accent = rgb(218, 164, 249), .plot = rgb(51, 35, 61) },
    .{ .label = win.wide("DISCO"), .accent = rgb(173, 226, 120), .plot = rgb(37, 51, 29) },
    .{ .label = win.wide("REDE"), .accent = rgb(251, 158, 158), .plot = rgb(57, 31, 39) },
};

// Dark neutral key avoids neon magenta fringing around rounded borders under LWA_COLORKEY.
pub const color_key = rgb(1, 2, 3);

pub const Surface = struct {
    dc: w.HDC = null,
    bitmap: w.HBITMAP = null,
    previous: w.HGDIOBJ = null,
    width: i32 = 0,
    height: i32 = 0,

    pub fn ensure(self: *Surface, screen: w.HDC, width: i32, height: i32) ?w.HDC {
        if (width <= 0 or height <= 0) return null;
        if (self.dc != null and self.bitmap != null and self.width == width and self.height == height) {
            return self.dc;
        }
        if (self.dc == null) {
            self.dc = w.CreateCompatibleDC(screen) orelse return null;
            _ = w.SetBkMode(self.dc, w.TRANSPARENT);
        }
        if (self.bitmap != null) {
            _ = w.SelectObject(self.dc, self.previous);
            _ = w.DeleteObject(self.bitmap);
            self.bitmap = null;
            self.previous = null;
            self.width = 0;
            self.height = 0;
        }
        const bitmap = w.CreateCompatibleBitmap(screen, width, height) orelse return null;
        self.previous = w.SelectObject(self.dc, bitmap);
        self.bitmap = bitmap;
        self.width = width;
        self.height = height;
        return self.dc;
    }

    pub fn deinit(self: *Surface) void {
        if (self.dc != null) {
            if (self.bitmap != null) {
                _ = w.SelectObject(self.dc, self.previous);
                _ = w.DeleteObject(self.bitmap);
            }
            _ = w.DeleteDC(self.dc);
        }
        self.* = .{};
    }

    pub fn present(self: Surface, screen: w.HDC, client: w.RECT) void {
        if (self.dc != null) {
            _ = w.BitBlt(screen, 0, 0, client.right, client.bottom, self.dc, 0, 0, w.SRCCOPY);
        }
    }
};

pub const Cache = struct {
    surface: Surface = .{},
    label_font: w.HFONT = null,
    font_dpi: u32 = 0,

    pub fn ensureFont(self: *Cache, dpi: u32) w.HFONT {
        if (self.label_font == null or self.font_dpi != dpi) {
            const next = font(10, dpi, w.FW_SEMIBOLD);
            if (next != null) {
                if (self.label_font != null) _ = w.DeleteObject(self.label_font);
                self.label_font = next;
                self.font_dpi = dpi;
            }
        }
        return self.label_font;
    }

    pub fn deinit(self: *Cache) void {
        if (self.label_font != null) {
            _ = w.DeleteObject(self.label_font);
            self.label_font = null;
        }
        self.font_dpi = 0;
        self.surface.deinit();
    }
};

pub fn font(size: i32, dpi: u32, weight: c_int) w.HFONT {
    return w.CreateFontW(-px(size, dpi), 0, 0, 0, weight, 0, 0, 0, w.DEFAULT_CHARSET, w.OUT_DEFAULT_PRECIS, w.CLIP_DEFAULT_PRECIS, w.ANTIALIASED_QUALITY, w.DEFAULT_PITCH, win.wide("Segoe UI"));
}

pub const Placement = struct {
    rect: w.RECT,
    canvas_width: i32,
    canvas_height: i32,
    offset_x: i32,
    offset_y: i32,
    count: usize,
    dpi: u32,
};

pub fn place(bar: taskbar.Bar, visible: w.RECT, slot: taskbar.Slot) ?Placement {
    const bar_height = bar.rect.bottom - bar.rect.top;
    const height = @min(px(38, bar.dpi), bar_height - px(6, bar.dpi));
    if (height < px(22, bar.dpi)) return null;
    const x = bar.rect.left + slot.x;
    const y = bar.rect.top + @divTrunc(bar_height - height, 2);
    const full: w.RECT = .{ .left = x, .right = x + slot.width, .top = y, .bottom = y + height };
    var clipped: w.RECT = undefined;
    if (w.IntersectRect(&clipped, &full, &visible) == 0) return null;
    return .{
        .rect = clipped,
        .canvas_width = slot.width,
        .canvas_height = height,
        .offset_x = full.left - clipped.left,
        .offset_y = full.top - clipped.top,
        .count = slot.tiles,
        .dpi = bar.dpi,
    };
}

pub fn draw(window: w.HWND, cache: *Cache, placement: ?Placement, history: []const metrics.Series) void {
    var paint: w.PAINTSTRUCT = undefined;
    const screen = w.BeginPaint(window, &paint) orelse return;
    defer _ = w.EndPaint(window, &paint);
    const layout = placement orelse return;
    var client: w.RECT = undefined;
    if (w.GetClientRect(window, &client) == 0) return;
    const buffer = cache.surface.ensure(screen, client.right, client.bottom) orelse return;

    fill(buffer, client, color_key);
    const typeface = cache.ensureFont(layout.dpi);
    const old_font = if (typeface != null) w.SelectObject(buffer, typeface) else null;
    defer if (typeface != null) {
        _ = w.SelectObject(buffer, old_font);
    };

    const gap = px(taskbar.tile_gap, layout.dpi);
    const count: i32 = @intCast(layout.count);
    const width = @divTrunc(layout.canvas_width - gap * (count - 1), count);
    for (0..layout.count) |index| {
        const kind: metrics.Kind = @enumFromInt(index);
        const x = layout.offset_x + @as(i32, @intCast(index)) * (width + gap);
        const y = layout.offset_y;
        drawTile(buffer, .{ .left = x, .top = y, .right = x + width, .bottom = y + layout.canvas_height }, layout.dpi, kind, &history[index]);
    }
    cache.surface.present(screen, client);
}

fn drawTile(dc: w.HDC, rect: w.RECT, dpi: u32, kind: metrics.Kind, series: *const metrics.Series) void {
    const tile = tiles[@intFromEnum(kind)];
    const brush = w.GetStockObject(w.DC_BRUSH);
    const pen = w.GetStockObject(w.DC_PEN);
    if (brush != null and pen != null) {
        const old_pen = w.SelectObject(dc, pen);
        const old_brush = w.SelectObject(dc, brush);
        _ = w.SetDCBrushColor(dc, rgb(24, 27, 35));
        _ = w.SetDCPenColor(dc, rgb(55, 63, 77));
        const radius = px(8, dpi);
        _ = w.RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
        _ = w.SelectObject(dc, old_brush);
        _ = w.SelectObject(dc, old_pen);
    }

    const padding = px(5, dpi);
    const text_y = rect.top + px(3, dpi);
    const label_bottom = @min(rect.bottom, rect.top + px(16, dpi));

    var ascii: [16]u8 = undefined;
    const value = formatValue(&ascii, kind, series.latest());
    var utf16: [16]u16 = undefined;
    var text = win.utf16(&utf16, value);
    var text_size: w.SIZE = undefined;
    var has_extent = w.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &text_size) != 0;

    // "DISCO 100%" does not fit in a 72 DIP tile; dropping the unit keeps the label readable.
    var label_size: w.SIZE = undefined;
    if (has_extent and text.len > 1 and text[text.len - 1] == '%' and
        w.GetTextExtentPoint32W(dc, tile.label.ptr, @intCast(tile.label.len), &label_size) != 0 and
        label_size.cx + px(2, dpi) + text_size.cx > rect.right - rect.left - 2 * padding)
    {
        text = text[0 .. text.len - 1];
        has_extent = w.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &text_size) != 0;
    }

    const label_right = if (has_extent)
        @max(rect.left + padding, rect.right - padding - text_size.cx - px(2, dpi))
    else
        rect.right - padding;
    const label_clip: w.RECT = .{
        .left = rect.left + padding,
        .top = text_y,
        .right = @min(rect.right - padding, label_right),
        .bottom = label_bottom,
    };
    if (label_clip.right > label_clip.left and label_clip.bottom > label_clip.top) {
        _ = w.SetTextColor(dc, rgb(233, 237, 245));
        _ = w.ExtTextOutW(dc, rect.left + padding, text_y, w.ETO_CLIPPED, &label_clip, tile.label.ptr, @intCast(tile.label.len), null);
    }

    if (has_extent) {
        const value_x = rect.right - padding - text_size.cx;
        const value_clip: w.RECT = .{
            .left = rect.left + padding,
            .top = text_y,
            .right = rect.right - padding,
            .bottom = label_bottom,
        };
        if (value_clip.right > value_clip.left and value_clip.bottom > value_clip.top) {
            _ = w.SetTextColor(dc, tile.accent);
            _ = w.ExtTextOutW(dc, value_x, text_y, w.ETO_CLIPPED, &value_clip, text.ptr, @intCast(text.len), null);
        }
    }

    const chart: w.RECT = .{
        .left = rect.left + padding,
        .right = rect.right - padding,
        .top = rect.top + px(16, dpi),
        .bottom = rect.bottom - padding,
    };
    if (chart.bottom <= chart.top or chart.right <= chart.left) return;
    fill(dc, chart, tile.plot);
    plot(dc, chart, tile.accent, series, series.scale(kind));
}

pub fn plot(dc: w.HDC, rect: w.RECT, color: w.COLORREF, series: *const metrics.Series, scale: f64) void {
    if (series.count == 0 or rect.right <= rect.left or rect.bottom <= rect.top) return;
    const pen = w.GetStockObject(w.DC_PEN) orelse return;
    const prior = w.SelectObject(dc, pen);
    defer _ = w.SelectObject(dc, prior);
    _ = w.SetDCPenColor(dc, color);

    const width = rect.right - rect.left - 1;
    const height = rect.bottom - rect.top - 1;
    const safe_scale = if (scale > 0) scale else 100.0;
    var previous = false;
    for (0..series.count) |index| {
        const value = series.at(index) orelse {
            previous = false;
            continue;
        };
        const column: i32 = @intCast(metrics.capacity - series.count + index);
        const x = rect.left + @divTrunc(column * width, metrics.capacity - 1);
        const norm = std.math.clamp(value / safe_scale, 0.0, 1.0);
        const y = rect.bottom - 1 - @as(i32, @intFromFloat(@round(norm * @as(f64, @floatFromInt(height)))));
        if (previous) _ = w.LineTo(dc, x, y) else _ = w.MoveToEx(dc, x, y, null);
        previous = true;
    }
    if (previous) {
        var end: w.POINT = undefined;
        if (w.GetCurrentPositionEx(dc, &end) != 0) _ = w.SetPixelV(dc, end.x, end.y, color);
    }
}

pub fn fill(dc: w.HDC, rect: w.RECT, color: w.COLORREF) void {
    const brush: w.HBRUSH = @ptrCast(@alignCast(w.GetStockObject(w.DC_BRUSH) orelse return));
    _ = w.SetDCBrushColor(dc, color);
    _ = w.FillRect(dc, &rect, brush);
}

fn formatValue(buffer: []u8, kind: metrics.Kind, value: ?f64) []const u8 {
    const number = value orelse return "--";
    if (kind != .network) return std.fmt.bufPrint(buffer, "{d}%", .{@as(u32, @intFromFloat(@round(@min(number, 1000))))}) catch "--";
    // Bytes/s to bits/s. Values from 10 up drop the decimal so "REDE 125M" still fits a 72 DIP tile.
    const kbps = @min(number, 1e15) / 125;
    if (@round(kbps) < 1000) return std.fmt.bufPrint(buffer, "{d}k", .{@as(u32, @intFromFloat(@round(kbps)))}) catch "--";
    const mbps = kbps / 1000;
    if (mbps < 9.95) return std.fmt.bufPrint(buffer, "{d:.1}M", .{mbps}) catch "--";
    if (@round(mbps) < 1000) return std.fmt.bufPrint(buffer, "{d}M", .{@as(u32, @intFromFloat(@round(mbps)))}) catch "--";
    const gbps = mbps / 1000;
    if (gbps < 9.95) return std.fmt.bufPrint(buffer, "{d:.1}G", .{gbps}) catch "--";
    return std.fmt.bufPrint(buffer, "{d}G", .{@as(u32, @intFromFloat(@round(@min(gbps, 1_000_000))))}) catch "--";
}

test "formatValue keeps tile values short" {
    var buffer: [16]u8 = undefined;
    const cases = [_]struct { kind: metrics.Kind, value: ?f64, expected: []const u8 }{
        .{ .kind = .disk, .value = null, .expected = "--" },
        .{ .kind = .disk, .value = 99.6, .expected = "100%" },
        .{ .kind = .cpu, .value = 3.2, .expected = "3%" },
        .{ .kind = .network, .value = 0, .expected = "0k" },
        .{ .kind = .network, .value = 124_900, .expected = "999k" },
        .{ .kind = .network, .value = 124_990, .expected = "1.0M" },
        .{ .kind = .network, .value = 650_000, .expected = "5.2M" },
        .{ .kind = .network, .value = 1_243_000, .expected = "9.9M" },
        .{ .kind = .network, .value = 1_244_000, .expected = "10M" },
        .{ .kind = .network, .value = 12_487_500, .expected = "100M" },
        .{ .kind = .network, .value = 124_900_000, .expected = "999M" },
        .{ .kind = .network, .value = 124_990_000, .expected = "1.0G" },
        .{ .kind = .network, .value = 1_250_000_000, .expected = "10G" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, formatValue(&buffer, case.kind, case.value));
    }
}

pub fn rgb(r: u8, g: u8, b: u8) w.COLORREF {
    return @as(w.COLORREF, r) | (@as(w.COLORREF, g) << 8) | (@as(w.COLORREF, b) << 16);
}
