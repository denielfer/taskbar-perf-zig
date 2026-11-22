const std = @import("std");

pub const api = @cImport({
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("WINVER", "0x0A00");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("CINTERFACE", "1");
    @cInclude("windows.h");
    @cInclude("dwmapi.h");
    @cInclude("shellapi.h");
    @cInclude("pdh.h");
    @cInclude("pdhmsg.h");
    @cInclude("ipifcons.h");
    @cInclude("dxgi.h");
    @cInclude("winioctl.h");
    @cInclude("uiautomationclient.h");
    @cInclude("wtsapi32.h");
    @cInclude("dbt.h");
});

pub const wide = std.unicode.utf8ToUtf16LeStringLiteral;

// Win32's HWND_TOPMOST is a signed sentinel, not a pointer to a window.
pub extern "user32" fn SetWindowPos(window: api.HWND, insert_after: isize, x: c_int, y: c_int, width: c_int, height: c_int, flags: api.UINT) callconv(.winapi) api.BOOL;

// Defined directly to avoid depending on INITGUID linkage in C headers.
pub const guid_console_display_state: api.GUID = .{
    .Data1 = 0x6fe69556,
    .Data2 = 0x704a,
    .Data3 = 0x47a0,
    .Data4 = .{ 0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47 },
};

pub fn utf16(buffer: []u16, ascii: []const u8) []const u16 {
    for (ascii, buffer[0..ascii.len]) |byte, *out| out.* = byte;
    return buffer[0..ascii.len];
}
