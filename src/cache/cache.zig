// Cache interface
//
// Defines the polymorphic Cache interface using Zig's vtable pattern,
// plus a CacheEntry struct and a deterministic cache-key builder.

const std = @import("std");

/// A cached image blob together with metadata.
pub const CacheEntry = struct {
    data: []const u8,
    content_type: []const u8,
    created_at: i64, // unix timestamp (seconds)
};

/// Type-erased cache interface.  Concrete implementations (MemoryCache,
/// NoopCache, ...) return a `Cache` via their `.cache()` method.
pub const Cache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, key: []const u8) ?CacheEntry,
        put: *const fn (ptr: *anyopaque, key: []const u8, entry: CacheEntry) void,
        delete: *const fn (ptr: *anyopaque, key: []const u8) bool,
        clear: *const fn (ptr: *anyopaque) void,
        size: *const fn (ptr: *anyopaque) usize,
    };

    /// Look up a cached entry by key.  Returns `null` on miss.
    pub fn get(self: Cache, key: []const u8) ?CacheEntry {
        return self.vtable.get(self.ptr, key);
    }

    /// Store an entry under the given key.
    pub fn put(self: Cache, key: []const u8, entry: CacheEntry) void {
        self.vtable.put(self.ptr, key, entry);
    }

    /// Remove the entry for `key`.  Returns `true` if it existed.
    pub fn delete(self: Cache, key: []const u8) bool {
        return self.vtable.delete(self.ptr, key);
    }

    /// Drop every entry in the cache.
    pub fn clear(self: Cache) void {
        self.vtable.clear(self.ptr);
    }

    /// Current number of entries.
    pub fn size(self: Cache) usize {
        return self.vtable.size(self.ptr);
    }
};

/// Build a deterministic cache key from image path, transform descriptor
/// and output format.  The result is written into `buf` and a slice of
/// the written portion is returned.
///
/// Key format:  `<path>|<transforms>|<format>`
///
/// If the concatenated key would exceed `buf.len`, the result is
/// truncated (callers should provide a buffer of at least 512 bytes).
pub fn computeCacheKey(
    image_path: []const u8,
    transform_string: []const u8,
    format: []const u8,
    buf: []u8,
) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.writeAll(image_path) catch {};
    writer.writeByte('|') catch {};
    writer.writeAll(transform_string) catch {};
    writer.writeByte('|') catch {};
    writer.writeAll(format) catch {};
    return buf[0..stream.pos];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "computeCacheKey is deterministic" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const k1 = computeCacheKey("/img/photo.jpg", "w=200,h=100", "webp", &buf1);
    const k2 = computeCacheKey("/img/photo.jpg", "w=200,h=100", "webp", &buf2);
    try std.testing.expectEqualStrings(k1, k2);
}

test "computeCacheKey differs for different paths" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const k1 = computeCacheKey("/a.jpg", "w=100", "png", &buf1);
    const k2 = computeCacheKey("/b.jpg", "w=100", "png", &buf2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "computeCacheKey differs for different transforms" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const k1 = computeCacheKey("/a.jpg", "w=100", "png", &buf1);
    const k2 = computeCacheKey("/a.jpg", "w=200", "png", &buf2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "computeCacheKey differs for different formats" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const k1 = computeCacheKey("/a.jpg", "w=100", "png", &buf1);
    const k2 = computeCacheKey("/a.jpg", "w=100", "webp", &buf2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "computeCacheKey includes all components separated by pipe" {
    var buf: [256]u8 = undefined;
    const key = computeCacheKey("path", "transforms", "fmt", &buf);
    try std.testing.expectEqualStrings("path|transforms|fmt", key);
}
