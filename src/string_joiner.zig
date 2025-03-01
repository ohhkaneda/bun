/// Rope-like data structure for joining many small strings into one big string.
const std = @import("std");
const default_allocator = bun.default_allocator;
const bun = @import("bun");
const string = bun.string;
const Allocator = std.mem.Allocator;
const ObjectPool = @import("./pool.zig").ObjectPool;
const Joiner = @This();

const Joinable = struct {
    offset: u31 = 0,
    needs_deinit: bool = false,
    allocator: Allocator = undefined,
    slice: []const u8 = "",

    pub const Pool = ObjectPool(Joinable, null, true, 4);
};

len: usize = 0,
use_pool: bool = true,
node_allocator: Allocator = undefined,

head: ?*Joinable.Pool.Node = null,
tail: ?*Joinable.Pool.Node = null,

/// Avoid an extra pass over the list when joining
watcher: Watcher = .{},

pub const Watcher = struct {
    input: []const u8 = "",
    estimated_count: u32 = 0,
    needs_newline: bool = false,
};

pub fn done(this: *Joiner, allocator: Allocator) ![]u8 {
    if (this.head == null) {
        var out: []u8 = &[_]u8{};
        return out;
    }

    var slice = try allocator.alloc(u8, this.len);
    var remaining = slice;
    var el_ = this.head;
    while (el_) |join| {
        const to_join = join.data.slice[join.data.offset..];
        @memcpy(remaining.ptr, to_join.ptr, to_join.len);

        remaining = remaining[@min(remaining.len, to_join.len)..];

        var prev = join;
        el_ = join.next;
        if (prev.data.needs_deinit) {
            prev.data.allocator.free(prev.data.slice);
            prev.data = Joinable{};
        }

        if (this.use_pool) prev.release();
    }

    return slice[0 .. slice.len - remaining.len];
}

pub fn lastByte(this: *const Joiner) u8 {
    if (this.tail) |tail| {
        const slice = tail.data.slice[tail.data.offset..];
        return if (slice.len > 0) slice[slice.len - 1] else 0;
    }

    return 0;
}

pub fn push(this: *Joiner, slice: string) void {
    this.append(slice, 0, null);
}

pub fn ensureNewlineAtEnd(this: *Joiner) void {
    if (this.watcher.needs_newline) {
        this.watcher.needs_newline = false;
        this.push("\n");
    }
}

pub fn append(this: *Joiner, slice: string, offset: u32, allocator: ?Allocator) void {
    const data = slice[offset..];
    this.len += @truncate(u32, data.len);

    var new_tail = if (this.use_pool)
        Joinable.Pool.get(default_allocator)
    else
        (this.node_allocator.create(Joinable.Pool.Node) catch unreachable);

    this.watcher.estimated_count += @boolToInt(
        this.watcher.input.len > 0 and
            bun.strings.contains(data, this.watcher.input),
    );

    this.watcher.needs_newline = this.watcher.input.len > 0 and data.len > 0 and
        data[data.len - 1] != '\n';

    new_tail.* = .{
        .allocator = default_allocator,
        .data = Joinable{
            .offset = @truncate(u31, offset),
            .allocator = allocator orelse undefined,
            .needs_deinit = allocator != null,
            .slice = slice,
        },
    };

    var tail = this.tail orelse {
        this.tail = new_tail;
        this.head = new_tail;
        return;
    };
    tail.next = new_tail;
    this.tail = new_tail;
}
