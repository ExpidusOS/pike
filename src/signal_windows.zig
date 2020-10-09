const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const windows = os.windows;

const mem = std.mem;

pub fn Waker(comptime Set: type) type {
    const set_count = @bitSizeOf(Set);
    const set_int = meta.Int(false, set_count);

    return struct {
        const Self = @This();

        const Node = struct {
            next: [set_count]?*Node = [1]?*Node{null} ** set_count,
            prev: [set_count]?*Node = [1]?*Node{null} ** set_count,
            frame: anyframe,
        };

        const IS_READY = 1 << 0;

        lock: std.Mutex = .{},
        head: [set_count]usize = [1]usize{@ptrToInt(@as(?*Node, null))} ** set_count,
        tail: [set_count]usize = [1]usize{@ptrToInt(@as(?*Node, null))} ** set_count,

        inline fn recover(ptr: usize) ?*Node {
            return @intToPtr(?*Node, ptr & ~@as(usize, IS_READY));
        }

        inline fn append(self: *Self, comptime ptr: usize, node: *Node) void {
            const head = recover(self.head[ptr]);

            if (head == null) {
                self.head[ptr] = @ptrToInt(node);
            } else {
                const tail = recover(self.tail[ptr]) orelse unreachable;
                tail.next[ptr] = node;
            }

            self.tail[ptr] = @ptrToInt(node);
        }

        inline fn shift(self: *Self, comptime ptr: usize) ?*Node {
            const head = recover(self.head[ptr]) orelse unreachable;

            self.head[ptr] = @ptrToInt(head.next[ptr]);
            if (recover(self.head[ptr])) |new_head| {
                new_head.prev[ptr] = null;
            } else {
                self.tail[ptr] = @ptrToInt(@as(?*Node, null));
            }

            return head;
        }

        pub fn wait(self: *Self, comptime event: Set) callconv(.Async) void {
            comptime const set_bits = @bitCast(set_int, event);

            if (set_bits == @as(set_int, 0)) {
                return;
            }

            comptime var i = 0;
            comptime var j = 0;

            const lock = self.lock.acquire();

            var ready = false;
            inline while (i < set_count) : (i += 1) {
                if (set_bits & (1 << i) == 0) continue;

                if (self.head[i] & IS_READY != 0) {
                    self.head[i] = @ptrToInt(@as(?*Node, null));
                    ready = true;
                }
            }

            if (ready) {
                lock.release();
            } else {
                suspend {
                    var node = &Node{ .frame = @frame() };
                    inline while (j < set_count) : (j += 1) {
                        if (set_bits & (1 << j) != 0) self.append(j, node);
                    }
                    lock.release();
                }
            }
        }

        pub fn set(self: *Self, comptime event: Set) ?*Node {
            comptime const set_bits = @bitCast(set_int, event);

            const lock = self.lock.acquire();
            defer lock.release();

            return blk: {
                comptime var i = 0;

                inline while (i < set_count) : (i += 1) {
                    if (set_bits & (1 << i) == 0) continue;

                    if (self.head[i] & IS_READY == 0 and self.head[i] != @ptrToInt(@as(?*Node, null))) {
                        const node_ptr = self.shift(i);

                        if (node_ptr) |node| {
                            comptime var j = 0;

                            inline while (j < set_count) : (j += 1) {
                                if (j == i) continue;

                                if (node.prev[j]) |prev| {
                                    prev.next[j] = node.next[j];
                                } else if (self.head[j] == @ptrToInt(node_ptr)) {
                                    self.head[j] = @ptrToInt(node.next[j]);
                                    if (self.head[j] == @ptrToInt(@as(?*Node, null))) {
                                        self.tail[j] = @ptrToInt(@as(?*Node, null));
                                    }
                                }
                            }
                        }

                        comptime var k = 0;

                        inline while (k < set_count) : (k += 1) {
                            if (k == i) continue;

                            if (set_bits & (1 << k) != 0 and self.head[k] == @ptrToInt(@as(?*Node, null))) {
                                self.head[k] = IS_READY;
                            }
                        }

                        break :blk node_ptr;
                    }
                }

                comptime var l = 0;

                inline while (l < set_count) : (l += 1) {
                    if (set_bits & (1 << l) == 0) continue;

                    if (self.head[l] == @ptrToInt(@as(?*Node, null))) {
                        self.head[l] = IS_READY;
                    }
                }

                break :blk null;
            };
        }
    };
}

var waker: Waker(Event) = .{};

const Self = @This();

const Event = packed struct {
    terminate: bool = false,
    interrupt: bool = false,
    quit: bool = false,
    hup: bool = false,
};

file: pike.File,

fn handler(dwCtrlType: windows.DWORD) callconv(.Stdcall) windows.BOOL {
    std.debug.print("Got console command: {}\n", .{dwCtrlType});

    switch (dwCtrlType) {
        pike.os.CTRL_C_EVENT => {
            @atomicStore(bool, &stopped, true, .SeqCst);
            return windows.TRUE;
        },
        else => return windows.FALSE,
    }
}

pub fn init(driver: *pike.Driver, comptime event: Event) !Self {
    return Self{ .file = .{ .handle = windows.INVALID_HANDLE_VALUE, .driver = driver } };
}

pub fn deinit(self: *Self) void {
    // TODO(kenta): implement
}

pub fn wait(self: *Self) callconv(.Async) !void {
    // TODO(kenta): implement
}
