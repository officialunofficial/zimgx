// In-memory LRU cache
//
// Fixed maximum size in bytes.  When a `put` would exceed the limit the
// least-recently-used entries are evicted until there is room.
// Thread-safe via `std.Thread.RwLock`.

const std = @import("std");
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const CacheEntry = cache_mod.CacheEntry;

/// Internal entry stored in the hash map.  Owns copies of both the key
/// and the CacheEntry data so the caller does not need to keep the
/// original slices alive.
const StoredEntry = struct {
    /// Allocated copy of the data payload.
    data: []u8,
    /// Allocated copy of the content-type string.
    content_type: []u8,
    /// Original creation timestamp from the CacheEntry.
    created_at: i64,
    /// Monotonically increasing access counter used for LRU eviction.
    last_access: u64,

    fn dataSize(self: StoredEntry) usize {
        return self.data.len + self.content_type.len;
    }
};

pub const MemoryCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(StoredEntry),
    max_size_bytes: usize,
    current_size_bytes: usize,
    access_counter: u64,
    lock: std.Thread.RwLock,

    /// Create a new MemoryCache that will hold at most `max_size_bytes`
    /// bytes of payload data (keys and content-type strings are counted
    /// toward the total as well).
    pub fn init(allocator: std.mem.Allocator, max_size_bytes: usize) MemoryCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(StoredEntry).init(allocator),
            .max_size_bytes = max_size_bytes,
            .current_size_bytes = 0,
            .access_counter = 0,
            .lock = .{},
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *MemoryCache) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.value_ptr.data);
            self.allocator.free(kv.value_ptr.content_type);
            // Keys are allocated copies too.
            self.allocator.free(kv.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Return the type-erased `Cache` interface backed by this instance.
    pub fn cache(self: *MemoryCache) Cache {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
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
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        return self.getEntry(key);
    }

    fn vtablePut(ptr: *anyopaque, key: []const u8, entry: CacheEntry) void {
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        self.putEntry(key, entry);
    }

    fn vtableDelete(ptr: *anyopaque, key: []const u8) bool {
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        return self.deleteEntry(key);
    }

    fn vtableClear(ptr: *anyopaque) void {
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        self.clearAll();
    }

    fn vtableSize(ptr: *anyopaque) usize {
        const self: *MemoryCache = @ptrCast(@alignCast(ptr));
        return self.entryCount();
    }

    // ----- actual logic -----

    fn getEntry(self: *MemoryCache, key: []const u8) ?CacheEntry {
        self.lock.lock();
        defer self.lock.unlock();

        const ptr = self.map.getPtr(key) orelse return null;

        self.access_counter += 1;
        ptr.last_access = self.access_counter;

        return CacheEntry{
            .data = ptr.data,
            .content_type = ptr.content_type,
            .created_at = ptr.created_at,
        };
    }

    fn putEntry(self: *MemoryCache, key: []const u8, entry: CacheEntry) void {
        self.lock.lock();
        defer self.lock.unlock();

        const new_size = entry.data.len + entry.content_type.len;

        // If the key already exists, remove it first (we'll replace it).
        if (self.map.fetchRemove(key)) |kv| {
            self.current_size_bytes -= kv.value.dataSize();
            self.allocator.free(kv.value.data);
            self.allocator.free(kv.value.content_type);
            self.allocator.free(kv.key);
        }

        // Evict LRU entries until there is room (or the map is empty).
        while (self.current_size_bytes + new_size > self.max_size_bytes and self.map.count() > 0) {
            self.evictLru();
        }

        // If the single entry is bigger than the whole cache, skip storing.
        if (new_size > self.max_size_bytes) return;

        // Allocate owned copies.
        const owned_data = self.allocator.dupe(u8, entry.data) catch return;
        const owned_ct = self.allocator.dupe(u8, entry.content_type) catch {
            self.allocator.free(owned_data);
            return;
        };
        const owned_key = self.allocator.dupe(u8, key) catch {
            self.allocator.free(owned_data);
            self.allocator.free(owned_ct);
            return;
        };

        self.access_counter += 1;

        self.map.put(owned_key, .{
            .data = owned_data,
            .content_type = owned_ct,
            .created_at = entry.created_at,
            .last_access = self.access_counter,
        }) catch {
            self.allocator.free(owned_key);
            self.allocator.free(owned_data);
            self.allocator.free(owned_ct);
            return;
        };

        self.current_size_bytes += new_size;
    }

    fn deleteEntry(self: *MemoryCache, key: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.map.fetchRemove(key) orelse return false;
        self.current_size_bytes -= kv.value.dataSize();
        self.allocator.free(kv.value.data);
        self.allocator.free(kv.value.content_type);
        self.allocator.free(kv.key);
        return true;
    }

    fn clearAll(self: *MemoryCache) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.value_ptr.data);
            self.allocator.free(kv.value_ptr.content_type);
            self.allocator.free(kv.key_ptr.*);
        }
        self.map.clearAndFree();
        self.current_size_bytes = 0;
    }

    fn entryCount(self: *MemoryCache) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.map.count();
    }

    /// Evict the entry with the smallest `last_access` value.
    /// Caller must hold the exclusive lock.
    fn evictLru(self: *MemoryCache) void {
        var min_access: u64 = std.math.maxInt(u64);
        var victim_key: ?[]const u8 = null;

        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_access < min_access) {
                min_access = kv.value_ptr.last_access;
                victim_key = kv.key_ptr.*;
            }
        }

        if (victim_key) |vk| {
            const kv = self.map.fetchRemove(vk).?;
            self.current_size_bytes -= kv.value.dataSize();
            self.allocator.free(kv.value.data);
            self.allocator.free(kv.value.content_type);
            self.allocator.free(kv.key);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "memory cache put and get a value" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    const entry = CacheEntry{
        .data = "image-bytes",
        .content_type = "image/png",
        .created_at = 1700000000,
    };
    c.put("photo1", entry);

    const got = c.get("photo1");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("image-bytes", got.?.data);
    try std.testing.expectEqualStrings("image/png", got.?.content_type);
    try std.testing.expectEqual(@as(i64, 1700000000), got.?.created_at);
}

test "memory cache get missing key returns null" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    try std.testing.expect(c.get("nonexistent") == null);
}

test "memory cache delete existing key returns true" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    c.put("k", .{ .data = "v", .content_type = "t", .created_at = 0 });
    try std.testing.expect(c.delete("k") == true);
    try std.testing.expect(c.get("k") == null);
}

test "memory cache delete missing key returns false" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    try std.testing.expect(c.delete("nope") == false);
}

test "memory cache size tracks correctly" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    try std.testing.expectEqual(@as(usize, 0), c.size());

    c.put("a", .{ .data = "1", .content_type = "t", .created_at = 0 });
    try std.testing.expectEqual(@as(usize, 1), c.size());

    c.put("b", .{ .data = "2", .content_type = "t", .created_at = 0 });
    try std.testing.expectEqual(@as(usize, 2), c.size());

    _ = c.delete("a");
    try std.testing.expectEqual(@as(usize, 1), c.size());
}

test "memory cache eviction when max size exceeded" {
    // Max size = 20 bytes.  Each entry has data.len + content_type.len
    // counted toward the total.
    var mc = MemoryCache.init(std.testing.allocator, 20);
    defer mc.deinit();
    const c = mc.cache();

    // Entry A: 10 bytes data + 1 byte ct = 11 bytes  (total 11)
    c.put("a", .{ .data = "0123456789", .content_type = "t", .created_at = 1 });
    try std.testing.expectEqual(@as(usize, 1), c.size());

    // Entry B: 10 bytes data + 1 byte ct = 11 bytes  (total 22 > 20)
    // This should evict entry A to make room.
    c.put("b", .{ .data = "abcdefghij", .content_type = "t", .created_at = 2 });
    try std.testing.expectEqual(@as(usize, 1), c.size());
    try std.testing.expect(c.get("a") == null); // evicted
    try std.testing.expect(c.get("b") != null); // still present
}

test "memory cache eviction evicts least recently used" {
    // Max size = 30 bytes.
    var mc = MemoryCache.init(std.testing.allocator, 30);
    defer mc.deinit();
    const c = mc.cache();

    // Entry A: 5+1=6 bytes (total 6)
    c.put("a", .{ .data = "aaaaa", .content_type = "t", .created_at = 1 });
    // Entry B: 5+1=6 bytes (total 12)
    c.put("b", .{ .data = "bbbbb", .content_type = "t", .created_at = 2 });
    // Entry C: 5+1=6 bytes (total 18)
    c.put("c", .{ .data = "ccccc", .content_type = "t", .created_at = 3 });

    // Access A so it becomes recently used (B is now LRU).
    _ = c.get("a");

    // Entry D: 15+1=16 bytes.  Need to free at least 16+18-30=4 bytes.
    // LRU is B (6 bytes freed -> total becomes 12+16=28, fits).
    c.put("d", .{ .data = "ddddddddddddddd", .content_type = "t", .created_at = 4 });

    try std.testing.expect(c.get("b") == null); // evicted (was LRU)
    try std.testing.expect(c.get("a") != null); // kept (was accessed)
    try std.testing.expect(c.get("d") != null); // newly added
}

test "memory cache clear empties cache" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    c.put("x", .{ .data = "data", .content_type = "ct", .created_at = 0 });
    c.put("y", .{ .data = "data", .content_type = "ct", .created_at = 0 });
    try std.testing.expectEqual(@as(usize, 2), c.size());

    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.size());
    try std.testing.expect(c.get("x") == null);
    try std.testing.expect(c.get("y") == null);
}

test "memory cache overwrite existing key" {
    var mc = MemoryCache.init(std.testing.allocator, 4096);
    defer mc.deinit();
    const c = mc.cache();

    c.put("key", .{ .data = "old", .content_type = "t", .created_at = 1 });
    c.put("key", .{ .data = "new", .content_type = "t", .created_at = 2 });

    try std.testing.expectEqual(@as(usize, 1), c.size());
    const got = c.get("key").?;
    try std.testing.expectEqualStrings("new", got.data);
    try std.testing.expectEqual(@as(i64, 2), got.created_at);
}
