const std = @import("std");
const win = @import("win.zig");
const w = win.api;
const hardware = @import("hardware.zig");
const interfaces = @import("network.zig");

pub const capacity = 60;
/// Worker threads: Zig's spawn commits the full stack on Windows, so the 16 MiB default
/// is 16 MiB of private memory per thread. 512 KiB leaves room for COM/UIA calls.
pub const thread_stack_size = 512 * 1024;
pub const Kind = enum { cpu, ram, gpu, disk, network };

pub const Series = struct {
    values: [capacity]f64 = @splat(-1),
    next: usize = 0,
    count: usize = 0,

    pub fn push(self: *Series, value: ?f64) void {
        self.values[self.next] = value orelse -1;
        self.next = (self.next + 1) % capacity;
        self.count = @min(self.count + 1, capacity);
    }

    pub fn at(self: *const Series, index: usize) ?f64 {
        const value = self.values[(capacity + self.next - self.count + index) % capacity];
        return if (value >= 0) value else null;
    }

    pub fn latest(self: *const Series) ?f64 {
        return if (self.count > 0) self.at(self.count - 1) else null;
    }

    pub fn scale(self: *const Series, kind: Kind) f64 {
        if (kind != .network) return 100;
        var max: f64 = 0;
        for (self.values) |value| max = @max(max, value);
        return @max(125_000, max);
    }
};

pub const Memory = struct { used: u64, total: u64 };

pub const Disk = struct {
    index: u32,
    letters: [80]u16,
    media: []const u16,
    activity: Series = .{},
    observed: bool = false,
};

const Traffic = struct { received: u64, sent: u64, time: u64 };

pub const Network = struct {
    key: u64,
    index: u32,
    name: [257]u16,
    description: [257]u16,
    physical: bool = false,
    prior: ?Traffic = null,
    received: Series = .{},
    sent: Series = .{},
    observed: bool = false,
};

pub const Gpu = struct {
    luid: w.LUID,
    name: [128]u16,
    activity: Series = .{},
    temperature: ?f64 = null,
    peak: ?f64 = null,
    observed: bool = false,
};

const CpuTimes = struct {
    idle: u64,
    total: u64,
};

const allocator = std.heap.c_allocator;

pub const Snapshot = struct {
    history: [@typeInfo(Kind).@"enum".fields.len]Series = @splat(.{}),
    cpu_ghz: ?f64 = null,
    memory: ?Memory = null,
    disks: std.ArrayList(Disk) = .empty,
    networks: std.ArrayList(Network) = .empty,
    gpus: std.ArrayList(Gpu) = .empty,

    pub fn deinit(self: *Snapshot) void {
        self.disks.deinit(allocator);
        self.networks.deinit(allocator);
        self.gpus.deinit(allocator);
    }

    pub fn copyFrom(self: *Snapshot, src: *const Collector) void {
        self.history = src.history;
        self.cpu_ghz = src.cpu_ghz;
        self.memory = src.memory;
        self.disks.clearRetainingCapacity();
        self.disks.appendSlice(allocator, src.disks.items) catch {};
        self.networks.clearRetainingCapacity();
        self.networks.appendSlice(allocator, src.networks.items) catch {};
        self.gpus.clearRetainingCapacity();
        self.gpus.appendSlice(allocator, src.gpus.items) catch {};
    }
};

pub const Sampler = struct {
    mutex: std.Thread.Mutex = .{},
    published: Snapshot = .{},
    stop: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    summary_open: std.atomic.Value(bool) = .init(false),
    temp_refresh_requested: std.atomic.Value(bool) = .init(false),
    devices_dirty_at: std.atomic.Value(u64) = .init(0),
    wake_pending: std.atomic.Value(bool) = .init(false),
    wake: std.Thread.ResetEvent = .{},
    finished: std.Thread.ResetEvent = .{},
    notify_window: w.HWND = null,
    notify_message: w.UINT = 0,
    thread: ?std.Thread = null,

    pub fn start(self: *Sampler, notify_window: w.HWND, notify_message: w.UINT) !void {
        self.notify_window = notify_window;
        self.notify_message = notify_message;
        // std.Thread.spawn on Windows commits the whole stack (16 MiB by default): keep it small.
        self.thread = try std.Thread.spawn(.{ .stack_size = thread_stack_size }, run, .{self});
    }

    pub fn deinit(self: *Sampler) void {
        self.stop.store(true, .release);
        self.signalWake();
        if (self.thread) |thread| {
            if (self.finished.timedWait(1500 * std.time.ns_per_ms)) |_| {
                thread.join();
                self.published.deinit();
            } else |_| {
                thread.detach();
            }
            self.thread = null;
        } else {
            self.published.deinit();
        }
    }

    pub fn setPaused(self: *Sampler, value: bool) void {
        const previous = self.paused.swap(value, .acq_rel);
        if (previous != value) self.signalWake();
    }

    pub fn setSummaryOpen(self: *Sampler, value: bool) void {
        const previous = self.summary_open.swap(value, .acq_rel);
        if (value and !previous) {
            self.temp_refresh_requested.store(true, .release);
            self.signalWake();
        }
    }

    pub fn markDevicesDirty(self: *Sampler) void {
        const ts = w.GetTickCount64();
        self.devices_dirty_at.store(if (ts == 0) 1 else ts, .release);
    }

    pub fn lockSnapshot(self: *Sampler) *const Snapshot {
        self.mutex.lock();
        return &self.published;
    }

    pub fn unlockSnapshot(self: *Sampler) void {
        self.mutex.unlock();
    }

    fn signalWake(self: *Sampler) void {
        self.wake_pending.store(true, .release);
        self.wake.set();
    }

    fn publish(self: *Sampler, collector: *const Collector) void {
        self.mutex.lock();
        self.published.copyFrom(collector);
        self.mutex.unlock();
        if (self.notify_window != null and self.notify_message != 0) {
            _ = w.PostMessageW(self.notify_window, self.notify_message, 0, 0);
        }
    }

    fn run(self: *Sampler) void {
        defer self.finished.set();

        var collector: Collector = .{};
        collector.init();
        defer collector.deinit();

        self.publish(&collector);
        var last_sample_ms = w.GetTickCount64();
        var was_paused = false;

        while (!self.stop.load(.acquire)) {
            if (self.paused.load(.acquire)) {
                was_paused = true;
                self.wake.reset();
                if (self.wake_pending.swap(false, .seq_cst)) continue;
                if (self.stop.load(.acquire) or !self.paused.load(.acquire)) continue;
                self.wake.wait();
                continue;
            }
            if (was_paused) {
                // Rates against pre-pause counters would average the whole pause into one point.
                was_paused = false;
                collector.resumeAfterPause();
                self.publish(&collector);
                last_sample_ms = w.GetTickCount64();
                continue;
            }

            const now = w.GetTickCount64();
            if (now -| last_sample_ms >= 1000) {
                self.temp_refresh_requested.store(false, .release);
                const dirty_at = self.devices_dirty_at.load(.acquire);
                if (dirty_at != 0 and now -| dirty_at >= 2000) {
                    if (self.devices_dirty_at.cmpxchgStrong(dirty_at, 0, .acq_rel, .acquire) == null) {
                        collector.refresh_disks = true;
                    }
                }
                collector.sample(self.summary_open.load(.acquire));
                last_sample_ms = now;
                self.publish(&collector);
            } else if (self.temp_refresh_requested.swap(false, .acq_rel)) {
                if (self.summary_open.load(.acquire)) {
                    collector.refreshGpuTemperatures();
                    self.publish(&collector);
                }
            }

            const elapsed = w.GetTickCount64() -| last_sample_ms;
            const remaining = 1000 -| elapsed;
            if (remaining > 0) {
                self.wake.reset();
                if (self.wake_pending.swap(false, .seq_cst)) continue;
                if (self.stop.load(.acquire) or self.paused.load(.acquire) or self.temp_refresh_requested.load(.acquire)) continue;
                _ = self.wake.timedWait(remaining * std.time.ns_per_ms) catch {};
            }
        }
    }
};

pub const Collector = struct {
    history: [@typeInfo(Kind).@"enum".fields.len]Series = @splat(.{}),
    query: w.PDH_HQUERY = null,
    disk: w.PDH_HCOUNTER = null,
    gpu: w.PDH_HCOUNTER = null,
    // CPU speed is only shown in the summary panel: its counters live in their own query,
    // collected only while the panel is open (collecting them every second is not free).
    cpu_query: w.PDH_HQUERY = null,
    cpu_frequency: w.PDH_HCOUNTER = null,
    cpu_performance: w.PDH_HCOUNTER = null,
    cpu_query_warm: bool = false,
    cpu_query_retry: u32 = 0,
    // Network: the interface list is rebuilt only when Windows reports a change (or every
    // ~60 samples); each sample reads just the listed interfaces with GetIfEntry2.
    net_dirty: std.atomic.Value(bool) = .init(true),
    net_watch: [2]?*anyopaque = .{ null, null },
    net_list_age: u32 = 0,
    cpu: ?CpuTimes = null,
    cpu_ghz: ?f64 = null,
    memory: ?Memory = null,
    disks: std.ArrayList(Disk) = .empty,
    networks: std.ArrayList(Network) = .empty,
    gpus: std.ArrayList(Gpu) = .empty,
    graphics: ?*w.IDXGIFactory1 = null,
    temperature_reader: ?hardware.TemperatureReader = null,
    buffer: []align(@alignOf(w.PDH_FMT_COUNTERVALUE_ITEM_W)) u8 = &.{},
    engines: std.AutoHashMapUnmanaged(u64, struct { adapter: u64, activity: f64 }) = .empty,
    refresh_disks: bool = false,
    pdh_samples: u32 = 0,
    pdh_retry_countdown: u32 = 30,
    pdh_retry_interval: u32 = 30,

    /// `self` must not move afterwards: the network change callbacks hold `&self.net_dirty`.
    pub fn init(self: *Collector) void {
        self.cpu = cpuTimes();
        self.temperature_reader = hardware.TemperatureReader.load();
        self.refreshGpus();
        interfaces.watchChanges(&self.net_dirty, &self.net_watch);
        _ = self.readNetworks(false);
        self.openPdh();
    }

    pub fn deinit(self: *Collector) void {
        interfaces.unwatchChanges(&self.net_watch);
        self.closePdh();
        self.closeCpuQuery();
        if (self.graphics) |factory| _ = factory.lpVtbl.*.Release.?(factory);
        self.disks.deinit(allocator);
        self.networks.deinit(allocator);
        self.gpus.deinit(allocator);
        allocator.free(self.buffer);
        self.engines.deinit(allocator);
    }

    fn openPdh(self: *Collector) void {
        self.closePdh();
        if (w.PdhOpenQueryW(null, 0, &self.query) != 0) {
            self.query = null;
            return;
        }
        self.disk = self.addCounter(self.query, win.wide("\\PhysicalDisk(*)\\% Idle Time"));
        self.gpu = self.addCounter(self.query, win.wide("\\GPU Engine(*)\\Utilization Percentage"));
        _ = w.PdhCollectQueryData(self.query);
        self.pdh_samples = 0;
    }

    fn closePdh(self: *Collector) void {
        if (self.query != null) {
            _ = w.PdhCloseQuery(self.query);
            self.query = null;
        }
        self.disk = null;
        self.gpu = null;
    }

    fn pdhMissingCounters(self: *const Collector) bool {
        return self.query == null or self.disk == null or self.gpu == null;
    }

    fn retryMissingPdhCounters(self: *Collector) bool {
        if (self.query == null) {
            self.openPdh();
            return true;
        }
        if (self.disk == null) self.disk = self.addCounter(self.query, win.wide("\\PhysicalDisk(*)\\% Idle Time"));
        if (self.gpu == null) self.gpu = self.addCounter(self.query, win.wide("\\GPU Engine(*)\\Utilization Percentage"));
        return false;
    }

    /// Opens the CPU speed query on first use; retried at most every 60 samples if it fails.
    fn ensureCpuQuery(self: *Collector) bool {
        if (self.cpu_query != null and self.cpu_frequency != null) return true;
        if (self.cpu_query_retry > 0) {
            self.cpu_query_retry -= 1;
            return false;
        }
        self.closeCpuQuery();
        if (w.PdhOpenQueryW(null, 0, &self.cpu_query) != 0) {
            self.cpu_query = null;
            self.cpu_query_retry = 60;
            return false;
        }
        self.cpu_frequency = self.addCounter(self.cpu_query, win.wide("\\Processor Information(_Total)\\Processor Frequency"));
        self.cpu_performance = self.addCounter(self.cpu_query, win.wide("\\Processor Information(_Total)\\% Processor Performance"));
        if (self.cpu_frequency == null) {
            self.closeCpuQuery();
            self.cpu_query_retry = 60;
            return false;
        }
        return true;
    }

    fn closeCpuQuery(self: *Collector) void {
        if (self.cpu_query != null) {
            _ = w.PdhCloseQuery(self.cpu_query);
            self.cpu_query = null;
        }
        self.cpu_frequency = null;
        self.cpu_performance = null;
        self.cpu_query_warm = false;
    }

    /// CPU speed for the summary panel. The first collection after the panel opens only sets
    /// a baseline: % Processor Performance is a rate and would average the closed period.
    fn sampleCpuSpeed(self: *Collector, summary_open: bool) ?f64 {
        if (!summary_open or !self.ensureCpuQuery()) {
            self.cpu_query_warm = false;
            return null;
        }
        if (w.PdhCollectQueryData(self.cpu_query) != 0) {
            self.cpu_query_warm = false;
            return null;
        }
        if (!self.cpu_query_warm) {
            self.cpu_query_warm = true;
            return null;
        }
        return self.readCpuSpeed();
    }

    /// Re-baselines every delta-based reading and marks the paused period as a gap in the charts.
    pub fn resumeAfterPause(self: *Collector) void {
        self.cpu = cpuTimes();
        _ = self.readNetworks(false);
        if (self.query != null) _ = w.PdhCollectQueryData(self.query);
        self.cpu_ghz = null;
        self.cpu_query_warm = false;
        for (&self.history) |*series| series.push(null);
        for (self.disks.items) |*disk| disk.activity.push(null);
        for (self.networks.items) |*net| {
            net.received.push(null);
            net.sent.push(null);
        }
        for (self.gpus.items) |*gpu| gpu.activity.push(null);
    }

    fn refreshGpuTemperatures(self: *Collector) void {
        for (self.gpus.items) |*gpu| {
            gpu.temperature = if (self.temperature_reader) |reader| reader.celsius(gpu.luid) else null;
        }
    }

    /// `summary_open`: the summary panel is visible (GPU temperature and CPU speed are read only then).
    pub fn sample(self: *Collector, summary_open: bool) void {
        const query_gpu_temp = summary_open;
        var skip_pdh_rates = false;
        if (self.pdhMissingCounters()) {
            if (self.pdh_retry_countdown == 0) {
                skip_pdh_rates = self.retryMissingPdhCounters();
                if (self.pdhMissingCounters()) {
                    self.pdh_retry_interval = @min(300, self.pdh_retry_interval * 2);
                    self.pdh_retry_countdown = self.pdh_retry_interval;
                } else {
                    self.pdh_retry_interval = 30;
                    self.pdh_retry_countdown = 30;
                }
            } else {
                self.pdh_retry_countdown -= 1;
            }
        } else {
            self.pdh_retry_interval = 30;
            self.pdh_retry_countdown = 30;
        }

        self.history[@intFromEnum(Kind.cpu)].push(self.readCpu());
        var memory = std.mem.zeroes(w.MEMORYSTATUSEX);
        memory.dwLength = @sizeOf(w.MEMORYSTATUSEX);
        self.memory = if (w.GlobalMemoryStatusEx(&memory) != 0 and memory.ullTotalPhys != 0)
            .{ .used = memory.ullTotalPhys -| memory.ullAvailPhys, .total = memory.ullTotalPhys }
        else
            null;
        const ram: ?f64 = if (self.memory) |m| 100 * asFloat(m.used) / asFloat(m.total) else null;
        self.history[@intFromEnum(Kind.ram)].push(ram);

        const collected = !skip_pdh_rates and self.query != null and w.PdhCollectQueryData(self.query) == 0;
        if (collected) self.pdh_samples +|= 1;

        self.cpu_ghz = self.sampleCpuSpeed(summary_open);
        self.refreshGpus();
        self.history[@intFromEnum(Kind.gpu)].push(self.readGpu(collected, query_gpu_temp));
        self.history[@intFromEnum(Kind.disk)].push(self.readDisks(collected));
        self.history[@intFromEnum(Kind.network)].push(self.readNetworks(true));

        // Periodically rotate PDH query to reclaim internal pdh.dll memory from dynamic GPU Engine(*) instances.
        if (self.gpu != null and self.pdh_samples >= 3600) {
            self.openPdh();
        }
    }

    fn addCounter(_: *Collector, query: w.PDH_HQUERY, path: [*:0]const u16) w.PDH_HCOUNTER {
        var counter: w.PDH_HCOUNTER = null;
        return if (w.PdhAddEnglishCounterW(query, path, 0, &counter) == 0) counter else null;
    }

    fn readCpu(self: *Collector) ?f64 {
        const current = cpuTimes() orelse return null;
        const previous = self.cpu;
        self.cpu = current;
        const before = previous orelse return null;
        const elapsed = current.total -| before.total;
        if (elapsed == 0) return null;
        const busy = elapsed -| (current.idle -| before.idle);
        return 100 * @as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(elapsed));
    }

    fn readCpuSpeed(self: *Collector) ?f64 {
        const frequency = scalar(self.cpu_frequency) orelse return null;
        if (frequency <= 0) return null;
        // Without the performance counter, fall back to the nominal frequency; with it but no
        // valid sample yet, show nothing rather than the nominal value for a second.
        const performance = scalar(self.cpu_performance) orelse
            return if (self.cpu_performance == null) frequency / 1000 else null;
        return frequency * performance / 100_000;
    }

    fn items(self: *Collector, counter: w.PDH_HCOUNTER) []const w.PDH_FMT_COUNTERVALUE_ITEM_W {
        if (counter == null) return &.{};
        var count: w.DWORD = 0;
        var bytes: w.DWORD = @intCast(self.buffer.len);
        var data: [*c]w.PDH_FMT_COUNTERVALUE_ITEM_W = if (bytes == 0) null else @ptrCast(self.buffer.ptr);
        const format = w.PDH_FMT_DOUBLE | w.PDH_FMT_NOCAP100;
        var status = w.PdhGetFormattedCounterArrayW(counter, format, &bytes, &count, data);
        // Instances may appear or disappear while PDH fills the buffer.
        if (status == @as(w.PDH_STATUS, @bitCast(@as(u32, w.PDH_MORE_DATA))) and bytes > self.buffer.len) {
            const replacement = allocator.alignedAlloc(u8, .of(w.PDH_FMT_COUNTERVALUE_ITEM_W), bytes) catch return &.{};
            allocator.free(self.buffer);
            self.buffer = replacement;
            data = @ptrCast(replacement.ptr);
            status = w.PdhGetFormattedCounterArrayW(counter, format, &bytes, &count, data);
        }
        if (status != 0 or count == 0) return &.{};
        return data[0..count];
    }

    fn refreshGpus(self: *Collector) void {
        if (self.graphics) |factory| {
            if (factory.lpVtbl.*.IsCurrent.?(factory) != 0) return;
            _ = factory.lpVtbl.*.Release.?(factory);
        }
        self.graphics = hardware.graphicsFactory();
        const factory = self.graphics orelse return;
        for (self.gpus.items) |*gpu| gpu.observed = false;
        var index: u32 = 0;
        while (true) : (index += 1) {
            var adapter: ?*w.IDXGIAdapter1 = null;
            if (factory.lpVtbl.*.EnumAdapters1.?(factory, index, &adapter) < 0) break;
            const device = adapter orelse break;
            defer _ = device.lpVtbl.*.Release.?(device);
            var desc: w.DXGI_ADAPTER_DESC1 = undefined;
            if (device.lpVtbl.*.GetDesc1.?(device, &desc) < 0 or desc.Flags & w.DXGI_ADAPTER_FLAG_SOFTWARE != 0) continue;
            const id = hardware.luid(desc.AdapterLuid);
            for (self.gpus.items) |*gpu| {
                if (hardware.luid(gpu.luid) == id) {
                    gpu.observed = true;
                    gpu.name = desc.Description;
                    break;
                }
            } else self.gpus.append(allocator, .{ .luid = desc.AdapterLuid, .name = desc.Description, .observed = true }) catch continue;
        }
        var i: usize = self.gpus.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.gpus.items[i].observed) _ = self.gpus.orderedRemove(i);
        }
    }

    fn readGpu(self: *Collector, collected: bool, query_gpu_temp: bool) ?f64 {
        self.engines.clearRetainingCapacity();
        defer self.engines.clearRetainingCapacity();
        for (self.gpus.items) |*gpu| gpu.peak = null;
        for (if (collected) self.items(self.gpu) else &.{}) |item| {
            const value = validValue(item.FmtValue) orelse continue;
            const name = instanceName(item) orelse continue;
            const start = std.mem.indexOf(u16, name, win.wide("luid_")) orelse continue;
            const end = std.mem.indexOfScalar(u16, name, '#') orelse name.len;
            if (end <= start) continue;
            const engine = name[start..end];
            const adapter = engineLuid(engine) orelse continue;
            const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(engine));
            const entry = self.engines.getOrPut(allocator, key) catch continue;
            if (!entry.found_existing) entry.value_ptr.* = .{ .adapter = adapter, .activity = 0 };
            entry.value_ptr.activity += value;
        }
        var peak: ?f64 = null;
        var values = self.engines.valueIterator();
        while (values.next()) |value| {
            const activity = @min(100, value.activity);
            peak = @max(peak orelse 0, activity);
            for (self.gpus.items) |*gpu| {
                if (hardware.luid(gpu.luid) == value.adapter) {
                    gpu.peak = @max(gpu.peak orelse 0, activity);
                    break;
                }
            }
        }
        for (self.gpus.items) |*gpu| {
            gpu.activity.push(gpu.peak);
            gpu.temperature = if (query_gpu_temp)
                (if (self.temperature_reader) |reader| reader.celsius(gpu.luid) else null)
            else
                null;
        }
        return peak;
    }

    fn readDisks(self: *Collector, collected: bool) ?f64 {
        var drive_map: ?hardware.DriveMap = null;
        const refresh_meta = self.refresh_disks;
        self.refresh_disks = false;
        if (refresh_meta) {
            const map = hardware.scanDriveMap();
            drive_map = map;
            for (self.disks.items) |*disk| {
                disk.media = hardware.diskType(disk.index);
                disk.letters = map.lettersForDisk(disk.index);
            }
        }

        var peak: ?f64 = null;
        var saw_instances = false;
        for (self.disks.items) |*disk| disk.observed = false;
        for (if (collected) self.items(self.disk) else &.{}) |item| {
            const name = instanceName(item) orelse continue;
            const digits = std.mem.indexOfScalar(u16, name, ' ') orelse name.len;
            const index = parseNumber(name[0..digits], 10) orelse continue;
            saw_instances = true;
            const disk = for (self.disks.items) |*disk| {
                if (disk.index == index) break disk;
            } else blk: {
                if (drive_map == null) drive_map = hardware.scanDriveMap();
                const disk = self.disks.addOne(allocator) catch continue;
                disk.* = .{
                    .index = index,
                    .media = hardware.diskType(index),
                    .letters = drive_map.?.lettersForDisk(index),
                };
                break :blk disk;
            };
            if (disk.observed) continue;
            if (disk.letters[0] == 0 and digits < name.len) copyName(&disk.letters, name[digits + 1 ..]);
            disk.observed = true;
            const activity: ?f64 = if (validValue(item.FmtValue)) |idle| 100 - @min(idle, 100) else null;
            disk.activity.push(activity);
            if (activity) |value| peak = @max(peak orelse 0, value);
        }
        var i: usize = self.disks.items.len;
        while (i > 0) {
            i -= 1;
            if (self.disks.items[i].observed) continue;
            if (saw_instances) {
                _ = self.disks.orderedRemove(i);
            } else self.disks.items[i].activity.push(null);
        }
        std.mem.sort(Disk, self.disks.items, {}, struct {
            fn less(_: void, a: Disk, b: Disk) bool {
                return a.index < b.index;
            }
        }.less);
        return peak;
    }

    /// Rebuilds the interface list from the full tables (GetIfTable2 + unicast addresses).
    /// Keeps each surviving interface's history and traffic baseline.
    fn rebuildNetworks(self: *Collector) bool {
        var result: ?*interfaces.Table = null;
        if (interfaces.GetIfTable2(&result) != 0 or result == null) return false;
        const table = result.?;
        defer interfaces.FreeMibTable(table);
        const addresses = interfaces.AddressTable.read();
        defer if (addresses) |entries| interfaces.FreeMibTable(entries);
        for (self.networks.items) |*net| net.observed = false;
        for (table.rows()) |*row| {
            if (!row.active()) continue;
            const key = row.key;
            if (addresses) |entries| {
                if (!entries.contains(key)) continue;
            }
            const physical = row.isPhysical();
            const net = for (self.networks.items) |*net| {
                if (net.key == key) break net;
            } else blk: {
                const net = self.networks.addOne(allocator) catch continue;
                net.* = .{ .key = key, .index = row.index, .name = row.alias, .description = row.description, .physical = physical };
                break :blk net;
            };
            net.observed = true;
            net.index = row.index;
            net.name = row.alias;
            net.description = row.description;
            net.physical = physical;
        }
        var i: usize = self.networks.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.networks.items[i].observed) _ = self.networks.orderedRemove(i);
        }
        std.mem.sort(Network, self.networks.items, {}, struct {
            fn less(_: void, a: Network, b: Network) bool {
                return a.index < b.index;
            }
        }.less);
        return true;
    }

    fn readNetworks(self: *Collector, record: bool) ?f64 {
        // GetIfTable2 builds a row for every interface (virtual ones included) and is one of the
        // costliest calls per sample: the full list is rebuilt only on a change notification
        // or every ~60 samples.
        self.net_list_age +|= 1;
        if (self.net_dirty.swap(false, .acq_rel) or self.net_list_age >= 60) {
            self.net_list_age = 0;
            if (!self.rebuildNetworks()) {
                self.net_dirty.store(true, .release); // retry on the next sample
                if (record) for (self.networks.items) |*net| {
                    net.received.push(null);
                    net.sent.push(null);
                };
                return null;
            }
        }

        const now = w.GetTickCount64();
        var total_all: ?f64 = null;
        var total_physical: ?f64 = null;
        var any_physical = false;
        for (self.networks.items) |*net| {
            if (net.physical) any_physical = true;
            var row = std.mem.zeroes(interfaces.Row);
            row.key = net.key;
            if (interfaces.GetIfEntry2(&row) != 0 or !row.active()) {
                // Went down between notifications: a gap now, gone after the next rebuild.
                self.net_dirty.store(true, .release);
                net.prior = null;
                if (record) {
                    net.received.push(null);
                    net.sent.push(null);
                }
                continue;
            }
            const prior = net.prior;
            net.prior = .{ .received = row.in_octets, .sent = row.out_octets, .time = now };
            if (!record) continue;
            const recv, const sent = if (prior) |p|
                .{ counterRate(row.in_octets, p.received, now -| p.time), counterRate(row.out_octets, p.sent, now -| p.time) }
            else
                .{ @as(?f64, null), @as(?f64, null) };
            net.received.push(recv);
            net.sent.push(sent);
            if (recv != null or sent != null) {
                const delta = (recv orelse 0) + (sent orelse 0);
                total_all = (total_all orelse 0) + delta;
                if (net.physical) {
                    total_physical = (total_physical orelse 0) + delta;
                }
            }
        }
        return selectNetworkTotal(any_physical, total_physical, total_all);
    }
};

pub fn selectNetworkTotal(any_physical: bool, total_physical: ?f64, total_all: ?f64) ?f64 {
    if (!any_physical) return total_all;
    if ((total_physical orelse 0) > 0 or (total_all orelse 0) == 0) return total_physical;
    return total_all;
}

fn copyName(buffer: []u16, name: []const u16) void {
    const len = @min(buffer.len - 1, name.len);
    @memcpy(buffer[0..len], name[0..len]);
    buffer[len] = 0;
}

fn counterRate(current: u64, previous: u64, elapsed_ms: u64) ?f64 {
    if (current < previous or elapsed_ms == 0) return null;
    return 1000 * asFloat(current - previous) / asFloat(elapsed_ms);
}

fn asFloat(n: u64) f64 {
    return @floatFromInt(n);
}

fn scalar(counter: w.PDH_HCOUNTER) ?f64 {
    if (counter == null) return null;
    var value: w.PDH_FMT_COUNTERVALUE = undefined;
    if (w.PdhGetFormattedCounterValue(counter, w.PDH_FMT_DOUBLE | w.PDH_FMT_NOCAP100, null, &value) != 0) return null;
    return validValue(value);
}

fn parseNumber(value: []const u16, base: u8) ?u32 {
    var ascii: [10]u8 = undefined;
    if (value.len > ascii.len) return null;
    for (value, ascii[0..value.len]) |unit, *byte| byte.* = std.math.cast(u8, unit) orelse return null;
    return std.fmt.parseInt(u32, ascii[0..value.len], base) catch null;
}

fn engineLuid(engine: []const u16) ?u64 {
    var parts = std.mem.splitScalar(u16, engine, '_');
    _ = parts.next(); // luid
    const high = parseNumber(parts.next() orelse return null, 0) orelse return null;
    const low = parseNumber(parts.next() orelse return null, 0) orelse return null;
    return (@as(u64, high) << 32) | low;
}

fn instanceName(item: w.PDH_FMT_COUNTERVALUE_ITEM_W) ?[]const u16 {
    if (item.szName == null) return null;
    return std.mem.span(@as([*:0]const u16, @ptrCast(item.szName)));
}

fn validValue(counter: w.PDH_FMT_COUNTERVALUE) ?f64 {
    if (counter.CStatus != w.PDH_CSTATUS_VALID_DATA and counter.CStatus != w.PDH_CSTATUS_NEW_DATA) return null;
    const value = counter.unnamed_0.doubleValue;
    return if (std.math.isFinite(value)) @max(value, 0) else null;
}

fn ticks(time: w.FILETIME) u64 {
    return (@as(u64, time.dwHighDateTime) << 32) | time.dwLowDateTime;
}

fn cpuTimes() ?CpuTimes {
    var idle: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (w.GetSystemTimes(&idle, &kernel, &user) == 0) return null;
    return .{ .idle = ticks(idle), .total = ticks(kernel) + ticks(user) };
}

test "Series push, indexing, latest, and scale" {
    var s: Series = .{};
    try std.testing.expectEqual(@as(?f64, null), s.latest());
    try std.testing.expectEqual(@as(f64, 100), s.scale(.cpu));
    try std.testing.expectEqual(@as(f64, 125_000), s.scale(.network));

    for (0..65) |i| {
        s.push(@floatFromInt(i));
    }
    try std.testing.expectEqual(@as(usize, 60), s.count);
    try std.testing.expectEqual(@as(?f64, 5.0), s.at(0));
    try std.testing.expectEqual(@as(?f64, 64.0), s.latest());

    s.push(null);
    try std.testing.expectEqual(@as(?f64, null), s.latest());

    var net_s: Series = .{};
    net_s.push(500_000);
    try std.testing.expectEqual(@as(f64, 500_000), net_s.scale(.network));
}

test "resumeAfterPause leaves a gap and a fresh CPU baseline" {
    var collector: Collector = .{};
    defer collector.deinit();
    collector.history[@intFromEnum(Kind.cpu)].push(40);
    var disk: Disk = .{ .index = 0, .letters = @splat(0), .media = &.{} };
    disk.activity.push(10);
    try collector.disks.append(allocator, disk);

    collector.resumeAfterPause();

    try std.testing.expectEqual(@as(?f64, null), collector.history[@intFromEnum(Kind.cpu)].latest());
    try std.testing.expectEqual(@as(usize, 2), collector.history[@intFromEnum(Kind.cpu)].count);
    try std.testing.expectEqual(@as(?f64, null), collector.disks.items[0].activity.latest());
    try std.testing.expect(collector.cpu != null);
    for (collector.networks.items) |net| try std.testing.expect(net.prior != null);
}

test "counterRate guards wraparound and zero elapsed" {
    try std.testing.expectEqual(@as(?f64, null), counterRate(100, 200, 1000));
    try std.testing.expectEqual(@as(?f64, null), counterRate(200, 100, 0));
    try std.testing.expectEqual(@as(?f64, 2000.0), counterRate(1200, 200, 500));
}

test "selectNetworkTotal falls back on Hyper-V external vSwitch" {
    try std.testing.expectEqual(@as(?f64, 1500.0), selectNetworkTotal(true, 1500.0, 3000.0));
    try std.testing.expectEqual(@as(?f64, 0.0), selectNetworkTotal(true, 0.0, 0.0));
    try std.testing.expectEqual(@as(?f64, 2400.0), selectNetworkTotal(true, 0.0, 2400.0));
    try std.testing.expectEqual(@as(?f64, 2400.0), selectNetworkTotal(true, null, 2400.0));
    try std.testing.expectEqual(@as(?f64, 900.0), selectNetworkTotal(false, null, 900.0));
}
