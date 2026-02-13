// No-op cache
//
// Every operation is a no-op.  Useful as a default when caching is
// disabled, or as a stand-in during testing.

const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const CacheEntry = cache_mod.CacheEntry;

pub const NoopCache = struct {
    /// Create a NoopCache.  No resources are allocated.
    pub fn init() NoopCache {
        return .{};
    }

    /// Return the type-erased `Cache` interface backed by this instance.
    pub fn cache(self: *NoopCache) Cache {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Cache.VTable{
        .get = get,
        .put = put,
        .delete = delete,
        .clear = clear,
        .size = size,
    };

    fn get(_: *anyopaque, _: []const u8) ?CacheEntry {
        return null;
    }

    fn put(_: *anyopaque, _: []const u8, _: CacheEntry) void {}

    fn delete(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn clear(_: *anyopaque) void {}

    fn size(_: *anyopaque) usize {
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");

test "noop get always returns null" {
    var nc = NoopCache.init();
    const c = nc.cache();
    try std.testing.expect(c.get("any-key") == null);
    try std.testing.expect(c.get("another-key") == null);
}

test "noop put does not error" {
    var nc = NoopCache.init();
    const c = nc.cache();
    const entry = CacheEntry{
        .data = "hello",
        .content_type = "text/plain",
        .created_at = 1000,
    };
    // Should not panic or error.
    c.put("key", entry);
    // Still nothing stored.
    try std.testing.expect(c.get("key") == null);
}

test "noop delete returns false" {
    var nc = NoopCache.init();
    const c = nc.cache();
    try std.testing.expect(c.delete("nonexistent") == false);
    // Even after a put, delete still returns false.
    c.put("key", .{ .data = "d", .content_type = "t", .created_at = 0 });
    try std.testing.expect(c.delete("key") == false);
}

test "noop size is always 0" {
    var nc = NoopCache.init();
    const c = nc.cache();
    try std.testing.expectEqual(@as(usize, 0), c.size());
    c.put("key", .{ .data = "d", .content_type = "t", .created_at = 0 });
    try std.testing.expectEqual(@as(usize, 0), c.size());
}

test "noop clear does not error" {
    var nc = NoopCache.init();
    const c = nc.cache();
    c.clear(); // should not panic
    try std.testing.expectEqual(@as(usize, 0), c.size());
}
