const std = @import("std");
const win = @import("win.zig");
const w = win.api;

pub fn diskType(index: u32) []const u16 {
    var path: [48]u8 = undefined;
    const ascii = std.fmt.bufPrint(&path, "\\\\.\\PhysicalDrive{d}", .{index}) catch return &.{};
    var wide_path: [49]u16 = undefined;
    _ = win.utf16(&wide_path, ascii);
    wide_path[ascii.len] = 0;
    const device = openDevice(wide_path[0..ascii.len :0]) orelse return &.{};
    defer _ = w.CloseHandle(device);

    var descriptor: [1024]u8 align(@alignOf(w.STORAGE_DEVICE_DESCRIPTOR)) = undefined;
    const bus = if (storageProperty(device, w.StorageDeviceProperty, &descriptor) >= @sizeOf(w.STORAGE_DEVICE_DESCRIPTOR))
        @as(*const w.STORAGE_DEVICE_DESCRIPTOR, @ptrCast(&descriptor)).BusType
    else
        w.BusTypeUnknown;
    if (bus == w.BusTypeNvme) return win.wide("SSD (NVMe)");

    var seek: w.DEVICE_SEEK_PENALTY_DESCRIPTOR = undefined;
    if (storageProperty(device, w.StorageDeviceSeekPenaltyProperty, std.mem.asBytes(&seek)) < @sizeOf(w.DEVICE_SEEK_PENALTY_DESCRIPTOR)) {
        return switch (bus) {
            w.BusTypeSata => win.wide("SATA"),
            w.BusTypeUsb => win.wide("USB"),
            w.BusTypeSas => win.wide("SAS"),
            else => &.{},
        };
    }
    if (seek.IncursSeekPenalty != 0) {
        return switch (bus) {
            w.BusTypeSata => win.wide("HDD (SATA)"),
            w.BusTypeUsb => win.wide("HDD (USB)"),
            w.BusTypeSas => win.wide("HDD (SAS)"),
            else => win.wide("HDD"),
        };
    }
    return switch (bus) {
        w.BusTypeSata => win.wide("SSD (SATA)"),
        w.BusTypeUsb => win.wide("SSD (USB)"),
        else => win.wide("SSD"),
    };
}

fn openDevice(path: [*:0]const u16) ?*anyopaque {
    const handle = w.CreateFileW(path, 0, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, 0, null) orelse return null;
    return if (@intFromPtr(handle) == std.math.maxInt(usize)) null else handle;
}

const DriveExtent = struct {
    letter: u16,
    disk: u32,
};

pub const DriveMap = struct {
    entries: [128]DriveExtent = undefined,
    len: usize = 0,

    pub fn lettersForDisk(self: *const DriveMap, index: u32) [80]u16 {
        var letters: [80]u16 = @splat(0);
        var length: usize = 0;
        for (self.entries[0..self.len]) |entry| {
            if (entry.disk != index) continue;
            if (containsLetter(letters[0..length], entry.letter)) continue;
            if (length > 0) {
                if (length + 3 >= letters.len) break;
                letters[length] = ' ';
                length += 1;
            } else if (length + 2 >= letters.len) {
                break;
            }
            letters[length..][0..2].* = .{ entry.letter, ':' };
            length += 2;
        }
        return letters;
    }
};

fn containsLetter(letters: []const u16, target: u16) bool {
    var i: usize = 0;
    while (i + 1 < letters.len) : (i += 3) {
        if (letters[i] == target) return true;
    }
    return false;
}

pub fn scanDriveMap() DriveMap {
    var map: DriveMap = .{};
    const drives = w.GetLogicalDrives();
    for (0..26) |i| {
        if (drives & (@as(u32, 1) << @as(u5, @intCast(i))) == 0) continue;
        const letter: u16 = @as(u16, @intCast(i)) + 'A';
        const root: [3:0]u16 = .{ letter, ':', '\\' };
        const kind = w.GetDriveTypeW(&root);
        if (kind != w.DRIVE_FIXED and kind != w.DRIVE_REMOVABLE) continue;
        collectVolumeExtents(letter, &map);
    }
    return map;
}

fn collectVolumeExtents(letter: u16, map: *DriveMap) void {
    const path: [6:0]u16 = .{ '\\', '\\', '.', '\\', letter, ':' };
    const handle = openDevice(&path) orelse return;
    defer _ = w.CloseHandle(handle);
    var volumes: extern struct { count: u32, extents: [64]w.DISK_EXTENT } = undefined;
    var size: w.DWORD = 0;
    if (w.DeviceIoControl(handle, w.IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 0, &volumes, @sizeOf(@TypeOf(volumes)), &size, null) == 0) return;
    const available = (size -| @offsetOf(@TypeOf(volumes), "extents")) / @sizeOf(w.DISK_EXTENT);
    for (volumes.extents[0..@min(volumes.count, available, volumes.extents.len)]) |extent| {
        if (map.len >= map.entries.len) return;
        map.entries[map.len] = .{ .letter = letter, .disk = extent.DiskNumber };
        map.len += 1;
    }
}

fn storageProperty(device: w.HANDLE, property: w.STORAGE_PROPERTY_ID, buffer: []u8) u32 {
    var query = std.mem.zeroes(w.STORAGE_PROPERTY_QUERY);
    query.PropertyId = property;
    query.QueryType = w.PropertyStandardQuery;
    var count: w.DWORD = 0;
    return if (w.DeviceIoControl(device, w.IOCTL_STORAGE_QUERY_PROPERTY, &query, @sizeOf(w.STORAGE_PROPERTY_QUERY), buffer.ptr, @intCast(buffer.len), &count, null) != 0) count else 0;
}

const factory_iid: w.GUID = .{
    .Data1 = 0x770aae78,
    .Data2 = 0xf26f,
    .Data3 = 0x4dba,
    .Data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 },
};

pub fn graphicsFactory() ?*w.IDXGIFactory1 {
    var object: ?*anyopaque = null;
    if (w.CreateDXGIFactory1(&factory_iid, &object) < 0) return null;
    return @ptrCast(@alignCast(object));
}

pub fn luid(value: w.LUID) u64 {
    return (@as(u64, @as(u32, @bitCast(value.HighPart))) << 32) | value.LowPart;
}

// The MinGW headers omit these WDDM declarations. The records match the Windows DDK ABI.
const AdapterOpen = extern struct { luid: w.LUID, handle: u32 = 0 };
const AdapterClose = extern struct { handle: u32 };
const AdapterQuery = extern struct { handle: u32, kind: u32, data: *anyopaque, size: u32 };
const AdapterPerf = extern struct {
    physical_index: u32,
    frequencies_and_bandwidths: [5]u64 align(8),
    fan_rpm: u32,
    power: u32,
    temperature: u32,
    power_state_override: u8,
};

comptime {
    if (@sizeOf(usize) != 8) @compileError("WDDM D3DKMT ABI declarations assume 64-bit pointers");
    if (@sizeOf(AdapterOpen) != 12) @compileError("Unexpected AdapterOpen size");
    if (@sizeOf(AdapterClose) != 4) @compileError("Unexpected AdapterClose size");
    if (@sizeOf(AdapterQuery) != 24) @compileError("Unexpected AdapterQuery size");
    if (@sizeOf(AdapterPerf) != 64) @compileError("Unexpected AdapterPerf size");
    if (@offsetOf(AdapterPerf, "temperature") != 56) @compileError("Unexpected AdapterPerf.temperature offset");
}

pub const TemperatureReader = struct {
    open: *const fn (*AdapterOpen) callconv(.winapi) w.LONG,
    close: *const fn (*const AdapterClose) callconv(.winapi) w.LONG,
    query: *const fn (*const AdapterQuery) callconv(.winapi) w.LONG,

    pub fn load() ?TemperatureReader {
        const gdi = w.GetModuleHandleW(win.wide("gdi32.dll")) orelse return null;
        return .{
            .open = @ptrCast(w.GetProcAddress(gdi, "D3DKMTOpenAdapterFromLuid") orelse return null),
            .close = @ptrCast(w.GetProcAddress(gdi, "D3DKMTCloseAdapter") orelse return null),
            .query = @ptrCast(w.GetProcAddress(gdi, "D3DKMTQueryAdapterInfo") orelse return null),
        };
    }

    pub fn celsius(self: TemperatureReader, adapter: w.LUID) ?f64 {
        var open: AdapterOpen = .{ .luid = adapter };
        if (self.open(&open) != 0) return null;
        defer _ = self.close(&.{ .handle = open.handle });
        var data = std.mem.zeroes(AdapterPerf);
        // KMTQAITYPE_ADAPTERPERFDATA
        if (self.query(&.{ .handle = open.handle, .kind = 62, .data = &data, .size = @sizeOf(AdapterPerf) }) != 0) return null;
        if (data.temperature == 0 or data.temperature > 1500) return null;
        return @as(f64, @floatFromInt(data.temperature)) / 10;
    }
};

test "hardware WDDM ABI sizes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(AdapterPerf));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(AdapterPerf, "temperature"));
}
