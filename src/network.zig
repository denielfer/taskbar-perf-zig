const std = @import("std");
const win = @import("win.zig");
const w = win.api;

// MIB_IF_ROW2 uses C bitfields that Zig's C translator cannot represent.
pub const Row = extern struct {
    key: u64 align(8),
    index: u32,
    guid: w.GUID,
    alias: [257]u16,
    description: [257]u16,
    physical_address_length: u32,
    physical_address: [32]u8,
    permanent_physical_address: [32]u8,
    mtu: u32,
    kind: u32,
    tunnel_type: u32,
    media_type: u32,
    physical_medium_type: u32,
    access_type: u32,
    direction_type: u32,
    status_flags: u8,
    oper_status: u32,
    admin_status: u32,
    media_connect_state: u32,
    network_guid: w.GUID,
    connection_type: u32,
    transmit_link_speed: u64 align(8),
    receive_link_speed: u64,
    in_octets: u64,
    in_unicast_packets: u64,
    in_non_unicast_packets: u64,
    in_discards: u64,
    in_errors: u64,
    in_unknown_protocols: u64,
    in_unicast_octets: u64,
    in_multicast_octets: u64,
    in_broadcast_octets: u64,
    out_octets: u64,
    out_unicast_packets: u64,
    out_non_unicast_packets: u64,
    out_discards: u64,
    out_errors: u64,
    out_unicast_octets: u64,
    out_multicast_octets: u64,
    out_broadcast_octets: u64,
    out_queue_length: u64,

    pub fn active(self: *const Row) bool {
        const operational_up = 1;
        const filter_interface = 1 << 1;
        const teredo_tunnel = 14;
        return self.oper_status == operational_up and self.kind != w.IF_TYPE_SOFTWARE_LOOPBACK and
            self.tunnel_type != teredo_tunnel and
            self.status_flags & filter_interface == 0;
    }

    pub fn isPhysical(self: *const Row) bool {
        const connector_present = 1 << 2;
        const if_type_tunnel = 131;
        if (self.status_flags & connector_present == 0) return false;
        if (self.tunnel_type != 0 or self.kind == if_type_tunnel) return false;
        const desc = std.mem.sliceTo(&self.description, 0);
        return !containsAsciiCaseInsensitive(desc, "virtual") and
            !containsAsciiCaseInsensitive(desc, "vpn");
    }
};

fn containsAsciiCaseInsensitive(haystack: []const u16, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var matched = true;
        for (needle, 0..) |ch, j| {
            const unit = haystack[i + j];
            if (unit > 0x7f or std.ascii.toLower(@intCast(unit)) != std.ascii.toLower(ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub const Table = extern struct {
    count: u32,
    first_row: Row,

    pub fn rows(self: *const Table) []const Row {
        return @as([*]const Row, @ptrCast(&self.first_row))[0..self.count];
    }
};

const Address = extern struct {
    socket_address: [28]u8 align(4), // SOCKADDR_INET
    key: u64 align(8),
    index: u32,
    prefix_origin: u32,
    suffix_origin: u32,
    valid_lifetime: u32,
    preferred_lifetime: u32,
    on_link_prefix_length: u8,
    skip_as_source: u8,
    dad_state: u32,
    scope_id: u32,
    creation_time: i64 align(8),
};

comptime {
    if (@sizeOf(Row) != 1352) @compileError("Unexpected MIB_IF_ROW2 size");
    if (@sizeOf(Address) != 80) @compileError("Unexpected MIB_UNICASTIPADDRESS_ROW size");
}

pub const AddressTable = extern struct {
    count: u32,
    first_row: Address,

    pub fn read() ?*AddressTable {
        var table: ?*AddressTable = null;
        return if (GetUnicastIpAddressTable(0, &table) == 0) table else null; // AF_UNSPEC
    }

    pub fn contains(self: *const AddressTable, key: u64) bool {
        const addresses = @as([*]const Address, @ptrCast(&self.first_row))[0..self.count];
        const deprecated = 3; // IpDadStateDeprecated, followed by IpDadStatePreferred
        for (addresses) |address| {
            if (address.key == key and address.valid_lifetime != 0 and address.dad_state >= deprecated) return true;
        }
        return false;
    }
};

pub extern "iphlpapi" fn GetIfTable2(table: *?*Table) callconv(.winapi) w.DWORD;
pub extern "iphlpapi" fn FreeMibTable(table: *anyopaque) callconv(.winapi) void;
extern "iphlpapi" fn GetUnicastIpAddressTable(family: u16, table: *?*AddressTable) callconv(.winapi) w.DWORD;

fn writeWide(buf: *[257]u16, text: []const u8) void {
    @memset(buf, 0);
    _ = win.utf16(buf, text);
}

test "network layout and isPhysical" {
    try std.testing.expectEqual(@as(usize, 1352), @sizeOf(Row));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Address));

    var eth = std.mem.zeroes(Row);
    eth.oper_status = 1;
    eth.kind = 6; // IF_TYPE_ETHERNET_CSMACD
    eth.status_flags = 1 << 2; // ConnectorPresent
    writeWide(&eth.description, "Example Gigabit Ethernet Controller");
    try std.testing.expect(eth.active());
    try std.testing.expect(eth.isPhysical());

    var vpn = eth;
    writeWide(&vpn.description, "Example VPN Ethernet Adapter");
    try std.testing.expect(!vpn.isPhysical());

    var veth = eth;
    writeWide(&veth.description, "Hyper-V Virtual Ethernet Adapter");
    try std.testing.expect(!veth.isPhysical());

    var tunnel = eth;
    tunnel.kind = 131;
    writeWide(&tunnel.description, "WireGuard Tunnel");
    try std.testing.expect(!tunnel.isPhysical());

    var no_conn = eth;
    no_conn.status_flags = 0;
    try std.testing.expect(!no_conn.isPhysical());
}
