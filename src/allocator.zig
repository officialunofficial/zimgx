// Per-request arena allocator for the zimgx image proxy.
//
// Provides a `RequestArena` struct that wraps `std.heap.ArenaAllocator` for
// fast bump-pointer allocation during a single HTTP request cycle.  After the
// response is sent the arena is reset in one operation, avoiding per-object
// free overhead while still reclaiming memory between requests.

const std = @import("std");

/// A resettable arena intended for one HTTP request cycle.
///
/// Usage pattern:
///   1. Create once at server start (or per-thread).
///   2. For each request, call `allocator()` to get a `std.mem.Allocator`.
///   3. After the response is sent, call `reset()` to free all request memory at once.
///
/// This avoids per-object free overhead during request processing while
/// still reclaiming memory between requests.
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,

    /// Create a new RequestArena backed by the given allocator.
    pub fn init(backing_allocator: std.mem.Allocator) RequestArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    /// Free all arena memory.  After this, the RequestArena should not be used.
    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }

    /// Get a `std.mem.Allocator` backed by this arena.
    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena, freeing all allocations at once.
    /// The arena can be reused after this call.  The underlying OS pages
    /// are retained so subsequent allocations avoid new mmap calls.
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Create a RequestArena using the page allocator (for production use).
pub fn createRequestArena() RequestArena {
    return RequestArena.init(std.heap.page_allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RequestArena init and deinit" {
    // Creating and immediately deinit-ing must not leak.
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();
}

test "RequestArena basic allocation" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();

    const alloc = ra.allocator();
    const buf = try alloc.alloc(u8, 128);

    // Verify we got a valid, correctly-sized slice.
    try std.testing.expectEqual(@as(usize, 128), buf.len);

    // Write to every byte to prove the memory is accessible.
    @memset(buf, 0xAB);
    for (buf) |b| {
        try std.testing.expectEqual(@as(u8, 0xAB), b);
    }
}

test "RequestArena multiple allocations" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();

    const alloc = ra.allocator();

    // Allocate several different sizes, mimicking varied request work.
    const small = try alloc.alloc(u8, 16);
    const medium = try alloc.alloc(u8, 1024);
    const large = try alloc.alloc(u8, 64 * 1024);

    try std.testing.expectEqual(@as(usize, 16), small.len);
    try std.testing.expectEqual(@as(usize, 1024), medium.len);
    try std.testing.expectEqual(@as(usize, 64 * 1024), large.len);

    // Ensure the slices do not overlap by writing distinct patterns.
    @memset(small, 0x11);
    @memset(medium, 0x22);
    @memset(large, 0x33);

    try std.testing.expectEqual(@as(u8, 0x11), small[0]);
    try std.testing.expectEqual(@as(u8, 0x22), medium[0]);
    try std.testing.expectEqual(@as(u8, 0x33), large[0]);
}

test "RequestArena reset frees all" {
    // The testing allocator will detect leaks on deinit.  By allocating,
    // resetting, then deinit-ing we prove that reset + deinit properly
    // frees everything.
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();

    const alloc = ra.allocator();
    _ = try alloc.alloc(u8, 4096);
    _ = try alloc.alloc(u8, 4096);

    // Reset -- all prior allocations are logically freed.
    ra.reset();

    // Allocate again after reset to verify the arena is still usable.
    const after = try alloc.alloc(u8, 256);
    try std.testing.expectEqual(@as(usize, 256), after.len);
}

test "RequestArena allocator works with std containers" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();

    const alloc = ra.allocator();

    // Use an ArrayList (unmanaged in Zig 0.15) -- a realistic container
    // used during request handling.  The allocator is passed per-call.
    var list: std.ArrayList(u32) = .empty;
    // Note: no defer list.deinit() needed -- the arena owns the memory.

    try list.append(alloc, 10);
    try list.append(alloc, 20);
    try list.append(alloc, 30);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(u32, 10), list.items[0]);
    try std.testing.expectEqual(@as(u32, 20), list.items[1]);
    try std.testing.expectEqual(@as(u32, 30), list.items[2]);
}

test "RequestArena reset allows reuse" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();

    const alloc = ra.allocator();

    // Simulate two sequential requests sharing the same arena.
    // -- Request 1 --
    const req1_data = try alloc.alloc(u8, 512);
    @memset(req1_data, 0xFF);

    ra.reset();

    // -- Request 2 --
    const req2_data = try alloc.alloc(u8, 512);
    @memset(req2_data, 0x00);

    // The second allocation must succeed and be independently writable.
    try std.testing.expectEqual(@as(usize, 512), req2_data.len);
    try std.testing.expectEqual(@as(u8, 0x00), req2_data[0]);
}

test "createRequestArena uses page allocator" {
    // The factory function must return a valid arena backed by the page
    // allocator.  We verify by performing an allocation and deinit.
    var ra = createRequestArena();
    defer ra.deinit();

    const alloc = ra.allocator();
    const buf = try alloc.alloc(u8, 64);

    try std.testing.expectEqual(@as(usize, 64), buf.len);

    // Write to the buffer to prove the memory is real.
    @memset(buf, 0xCD);
    try std.testing.expectEqual(@as(u8, 0xCD), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), buf[63]);
}
