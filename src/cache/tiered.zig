// Tiered cache
//
// Composes two Cache instances into a two-level hierarchy: a fast L1
// (e.g. in-memory) and a persistent L2 (e.g. R2 / disk).  Implements
// the same Cache.VTable interface so it can be used transparently
// wherever a Cache is expected.
//
// Writes go to L1 synchronously (fast path).  L2 writes are deferred
// to `putL2` which callers can run asynchronously (e.g. on a thread
// pool) to keep L2 latency off the critical path.

const std = @import("std");
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const CacheEntry = cache_mod.CacheEntry;

pub const TieredCache = struct {
    l1: Cache, // fast layer (e.g. MemoryCache)
    l2: Cache, // persistent layer (e.g. R2Cache)
    allocator: std.mem.Allocator,
    pool: ?*std.Thread.Pool = null,

    /// Create a TieredCache from two existing Cache interfaces.
    pub fn init(l1: Cache, l2: Cache, allocator: std.mem.Allocator) TieredCache {
        return .{ .l1 = l1, .l2 = l2, .allocator = allocator };
    }

    /// Return the type-erased `Cache` interface backed by this instance.
    pub fn cache(self: *TieredCache) Cache {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Write an entry to L2 (persistent layer) only.  Intended to be
    /// called from a background thread after the response has been sent.
    pub fn putL2(self: *TieredCache, key: []const u8, entry: CacheEntry) void {
        self.l2.put(key, entry);
    }

    /// Schedule an async L2 write on the thread pool.  Copies key and
    /// data so the caller can free the originals immediately.  If the
    /// copy or spawn fails, the write is silently skipped (best-effort).
    pub fn putL2Async(self: *TieredCache, key: []const u8, entry: CacheEntry) void {
        const p = self.pool orelse {
            // No pool — fall back to synchronous write.
            self.l2.put(key, entry);
            return;
        };

        const key_copy = self.allocator.dupe(u8, key) catch return;
        const data_copy = self.allocator.dupe(u8, entry.data) catch {
            self.allocator.free(key_copy);
            return;
        };

        p.spawn(asyncL2Worker, .{ self, key_copy, data_copy, entry.content_type, entry.created_at }) catch {
            self.allocator.free(key_copy);
            self.allocator.free(data_copy);
        };
    }

    fn asyncL2Worker(self: *TieredCache, key_copy: []u8, data_copy: []u8, content_type: []const u8, created_at: i64) void {
        defer self.allocator.free(key_copy);
        defer self.allocator.free(data_copy);

        self.l2.put(key_copy, .{
            .data = data_copy,
            .content_type = content_type,
            .created_at = created_at,
        });
    }

    // ----- vtable implementation -----

    const vtable = Cache.VTable{
        .get = vtableGet,
        .put = vtablePut,
        .delete = vtableDelete,
        .clear = vtableClear,
        .size = vtableSize,
    };

    fn vtableGet(ptr: *anyopaque, key: []const u8) ?CacheEntry {
        const self: *TieredCache = @ptrCast(@alignCast(ptr));

        // Check L1 first (fast path).
        if (self.l1.get(key)) |entry| {
            return entry;
        }

        // L1 miss -- try L2.
        if (self.l2.get(key)) |entry| {
            // Promote to L1 so subsequent reads are fast.
            self.l1.put(key, entry);
            return entry;
        }

        return null;
    }

    fn vtablePut(ptr: *anyopaque, key: []const u8, entry: CacheEntry) void {
        const self: *TieredCache = @ptrCast(@alignCast(ptr));

        // Write L1 synchronously (fast).  L2 is written asynchronously
        // via putL2Async to keep the R2 upload off the response path.
        self.l1.put(key, entry);
        self.putL2Async(key, entry);
    }

    fn vtableDelete(ptr: *anyopaque, key: []const u8) bool {
        const self: *TieredCache = @ptrCast(@alignCast(ptr));

        // Delete from both.  Use separate variables so both calls
        // always execute (short-circuit `or` would skip the second).
        const d1 = self.l1.delete(key);
        const d2 = self.l2.delete(key);
        return d1 or d2;
    }

    fn vtableClear(ptr: *anyopaque) void {
        const self: *TieredCache = @ptrCast(@alignCast(ptr));
        self.l1.clear();
        self.l2.clear();
    }

    fn vtableSize(ptr: *anyopaque) usize {
        const self: *TieredCache = @ptrCast(@alignCast(ptr));
        // Return L1 size -- the fast, trackable layer.
        return self.l1.size();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const memory_cache = @import("memory.zig");
const MemoryCache = memory_cache.MemoryCache;

test "tiered get miss on both returns null" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    try std.testing.expect(c.get("nonexistent") == null);
}

test "tiered put stores in both L1 and L2" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    const entry = CacheEntry{
        .data = "image-bytes",
        .content_type = "image/png",
        .created_at = 1700000000,
    };
    c.put("photo1", entry);

    // Both layers should have the entry.
    const l1_got = mc1.cache().get("photo1");
    try std.testing.expect(l1_got != null);
    try std.testing.expectEqualStrings("image-bytes", l1_got.?.data);
    try std.testing.expectEqualStrings("image/png", l1_got.?.content_type);
    try std.testing.expectEqual(@as(i64, 1700000000), l1_got.?.created_at);

    const l2_got = mc2.cache().get("photo1");
    try std.testing.expect(l2_got != null);
    try std.testing.expectEqualStrings("image-bytes", l2_got.?.data);
    try std.testing.expectEqualStrings("image/png", l2_got.?.content_type);
    try std.testing.expectEqual(@as(i64, 1700000000), l2_got.?.created_at);
}

test "tiered get from L1 (L1 hit)" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    // Put directly into L1 only.
    mc1.cache().put("key", .{ .data = "l1-data", .content_type = "text/plain", .created_at = 42 });

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    const got = c.get("key");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("l1-data", got.?.data);
    try std.testing.expectEqual(@as(i64, 42), got.?.created_at);

    // L2 should still be empty (no write-back on L1 hit).
    try std.testing.expect(mc2.cache().get("key") == null);
}

test "tiered get promotes from L2 to L1" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    // Put directly into L2 only.
    mc2.cache().put("key", .{ .data = "l2-data", .content_type = "image/webp", .created_at = 99 });

    // Verify L1 is empty before the tiered get.
    try std.testing.expect(mc1.cache().get("key") == null);

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    const got = c.get("key");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("l2-data", got.?.data);
    try std.testing.expectEqualStrings("image/webp", got.?.content_type);
    try std.testing.expectEqual(@as(i64, 99), got.?.created_at);

    // L1 should now have it too (promoted).
    const l1_got = mc1.cache().get("key");
    try std.testing.expect(l1_got != null);
    try std.testing.expectEqualStrings("l2-data", l1_got.?.data);
}

test "tiered delete removes from both" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    c.put("key", .{ .data = "data", .content_type = "ct", .created_at = 0 });

    // Sanity: both should have it.
    try std.testing.expectEqual(@as(usize, 1), mc1.cache().size());
    try std.testing.expectEqual(@as(usize, 1), mc2.cache().size());

    _ = c.delete("key");

    // Both should be empty now.
    try std.testing.expect(mc1.cache().get("key") == null);
    try std.testing.expect(mc2.cache().get("key") == null);
    try std.testing.expectEqual(@as(usize, 0), mc1.cache().size());
    try std.testing.expectEqual(@as(usize, 0), mc2.cache().size());
}

test "tiered delete returns true when entry exists, false when it doesn't" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    // Delete on empty cache should return false.
    try std.testing.expect(c.delete("nope") == false);

    // Put an entry, delete should return true.
    c.put("key", .{ .data = "d", .content_type = "t", .created_at = 0 });
    try std.testing.expect(c.delete("key") == true);

    // Second delete should return false (already gone).
    try std.testing.expect(c.delete("key") == false);
}

test "tiered clear empties both" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    c.put("a", .{ .data = "1", .content_type = "t", .created_at = 0 });
    c.put("b", .{ .data = "2", .content_type = "t", .created_at = 0 });

    try std.testing.expectEqual(@as(usize, 2), mc1.cache().size());
    try std.testing.expectEqual(@as(usize, 2), mc2.cache().size());

    c.clear();

    try std.testing.expectEqual(@as(usize, 0), mc1.cache().size());
    try std.testing.expectEqual(@as(usize, 0), mc2.cache().size());
    try std.testing.expect(mc1.cache().get("a") == null);
    try std.testing.expect(mc2.cache().get("a") == null);
}

test "tiered size returns L1 size" {
    var mc1 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc1.deinit();
    var mc2 = MemoryCache.init(std.testing.allocator, 4096);
    defer mc2.deinit();

    var tc = TieredCache.init(mc1.cache(), mc2.cache(), std.testing.allocator);
    const c = tc.cache();

    try std.testing.expectEqual(@as(usize, 0), c.size());

    c.put("a", .{ .data = "1", .content_type = "t", .created_at = 0 });
    try std.testing.expectEqual(@as(usize, 1), c.size());

    // Put directly into L2 -- tiered size should still reflect L1 only.
    mc2.cache().put("extra", .{ .data = "x", .content_type = "t", .created_at = 0 });
    try std.testing.expectEqual(@as(usize, 1), c.size());
    try std.testing.expectEqual(@as(usize, 2), mc2.cache().size());
}
