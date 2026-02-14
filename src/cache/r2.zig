// R2/S3-backed cache
//
// Wraps an S3Client to provide persistent variant storage as a Cache
// implementation.  All S3 errors are caught and handled gracefully:
// get returns null, put is best-effort, delete returns false.
//
// Thread-safe via Mutex.  The last-fetched response is stored in the
// struct itself (no "release" in the Cache vtable) and freed on the
// next get call; the mutex serializes access to this shared state.

const std = @import("std");
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const CacheEntry = cache_mod.CacheEntry;
const s3_client = @import("../s3/client.zig");
const S3Client = s3_client.S3Client;

pub const R2Cache = struct {
    client: *S3Client,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Last-fetched data buffer, kept alive so the CacheEntry returned
    /// by get() remains valid until the next get() call.
    last_data: ?[]u8 = null,

    /// Last-fetched content-type string, same lifetime as last_data.
    last_content_type: ?[]u8 = null,

    /// Create an R2Cache backed by the given S3Client.
    pub fn init(allocator: std.mem.Allocator, client: *S3Client) R2Cache {
        return .{
            .client = client,
            .allocator = allocator,
        };
    }

    /// Free any outstanding last-fetched buffers.
    pub fn deinit(self: *R2Cache) void {
        self.freeLastFetched();
    }

    /// Return the type-erased `Cache` interface backed by this instance.
    pub fn cache(self: *R2Cache) Cache {
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
        const self: *R2Cache = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free previous last-fetched buffers.
        self.freeLastFetched();

        // Sanitize the cache key for S3.
        var key_buf: [1024]u8 = undefined;
        const s3_key = sanitizeKey(key, &key_buf);

        // Attempt S3 fetch; any error is a cache miss.
        var response = self.client.getObject(s3_key) catch return null;
        const resp = &(response orelse return null);

        // Take ownership of resp.data (heap-allocated by S3Client).
        self.last_data = resp.data;

        // S3 response content_type is always "application/octet-stream"
        // because Zig's http.Client doesn't expose response headers.
        // Detect the real type from magic bytes instead.
        const detected_ct = detectContentType(resp.data);
        self.last_content_type = self.allocator.dupe(u8, detected_ct) catch {
            self.allocator.free(resp.data);
            self.last_data = null;
            return null;
        };

        return CacheEntry{
            .data = self.last_data.?,
            .content_type = self.last_content_type.?,
            .created_at = std.time.timestamp(),
        };
    }

    fn vtablePut(ptr: *anyopaque, key: []const u8, entry: CacheEntry) void {
        const self: *R2Cache = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf: [1024]u8 = undefined;
        const s3_key = sanitizeKey(key, &key_buf);

        // Best-effort write; errors are silently ignored.
        _ = self.client.putObject(s3_key, entry.data, entry.content_type) catch {};
    }

    fn vtableDelete(ptr: *anyopaque, key: []const u8) bool {
        const self: *R2Cache = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf: [1024]u8 = undefined;
        const s3_key = sanitizeKey(key, &key_buf);

        return self.client.deleteObject(s3_key) catch false;
    }

    fn vtableClear(_: *anyopaque) void {
        // No-op: bulk delete is not needed for MVP.
    }

    fn vtableSize(_: *anyopaque) usize {
        // Not trackable via S3.
        return 0;
    }

    // ----- helpers -----

    /// Free the last-fetched response buffers, resetting them to null.
    fn freeLastFetched(self: *R2Cache) void {
        if (self.last_data) |d| self.allocator.free(d);
        if (self.last_content_type) |ct| self.allocator.free(ct);
        self.last_data = null;
        self.last_content_type = null;
    }

    /// Detect content type from the first bytes (magic number) of image data.
    fn detectContentType(data: []const u8) []const u8 {
        if (data.len < 2) return "application/octet-stream";

        // 12+ byte signatures
        if (data.len >= 12) {
            // WebP: "RIFF" + 4 size bytes + "WEBP"
            if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP"))
                return "image/webp";

            // AVIF/HEIF: ftyp box at offset 4
            if (std.mem.eql(u8, data[4..8], "ftyp")) {
                const brand = data[8..12];
                if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis"))
                    return "image/avif";
                if (std.mem.eql(u8, brand, "heic") or std.mem.eql(u8, brand, "heix") or
                    std.mem.eql(u8, brand, "mif1"))
                    return "image/avif";
            }
        }

        // 4+ byte signatures
        if (data.len >= 4) {
            // PNG: \x89PNG
            if (data[0] == 0x89 and std.mem.eql(u8, data[1..4], "PNG"))
                return "image/png";

            // GIF: GIF8 (GIF87a or GIF89a)
            if (std.mem.eql(u8, data[0..4], "GIF8"))
                return "image/gif";
        }

        // 2+ byte signatures
        // JPEG: \xFF\xD8
        if (data[0] == 0xFF and data[1] == 0xD8)
            return "image/jpeg";

        return "application/octet-stream";
    }

    /// Sanitize a cache key for use as an S3 object key.
    ///
    /// Replaces `|` with `/` and collapses consecutive `/` so that
    /// empty segments (e.g. `path||format` → `path/format`) don't
    /// create double-slash S3 keys.
    pub fn sanitizeKey(key: []const u8, buf: []u8) []const u8 {
        var out: usize = 0;
        var prev_slash = false;
        for (key) |raw| {
            const c: u8 = if (raw == '|') '/' else raw;
            if (c == '/' and prev_slash) continue;
            if (out >= buf.len) break;
            buf[out] = c;
            out += 1;
            prev_slash = (c == '/');
        }
        return buf[0..out];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "R2Cache struct init sets fields" {
    // We cannot construct a real S3Client without the module being fully
    // available, so we test with an undefined pointer and only verify
    // the allocator field and default values.
    var dummy_client: S3Client = undefined;
    var rc = R2Cache.init(std.testing.allocator, &dummy_client);

    try std.testing.expect(rc.last_data == null);
    try std.testing.expect(rc.last_content_type == null);
    try std.testing.expectEqual(std.testing.allocator, rc.allocator);

    // Clean up (no-op since nothing allocated).
    rc.deinit();
}

test "vtable wiring — get returns null when S3 is unreachable" {
    var dummy_client = S3Client.init(
        std.testing.allocator,
        "http://localhost:1234",
        "test-bucket",
        .{ .access_key = "test", .secret_key = "test", .region = "auto" },
    );
    var rc = R2Cache.init(std.testing.allocator, &dummy_client);
    defer rc.deinit();

    const c = rc.cache();

    // getObject will fail with a connection error; vtableGet catches
    // the error and returns null.
    try std.testing.expect(c.get("some-key") == null);
}

test "sanitizeKey replaces pipes with slashes" {
    var buf: [256]u8 = undefined;
    const result = R2Cache.sanitizeKey("path|transforms|format", &buf);
    try std.testing.expectEqualStrings("path/transforms/format", result);
}

test "sanitizeKey collapses double pipes (empty segment)" {
    var buf: [256]u8 = undefined;
    const result = R2Cache.sanitizeKey("test.png||auto", &buf);
    try std.testing.expectEqualStrings("test.png/auto", result);
}

test "sanitizeKey leaves key unchanged when no pipes" {
    var buf: [256]u8 = undefined;
    const result = R2Cache.sanitizeKey("simple-key", &buf);
    try std.testing.expectEqualStrings("simple-key", result);
}

test "size returns 0" {
    var dummy_client: S3Client = undefined;
    var rc = R2Cache.init(std.testing.allocator, &dummy_client);
    defer rc.deinit();

    const c = rc.cache();
    try std.testing.expectEqual(@as(usize, 0), c.size());
}

test "clear does not panic" {
    var dummy_client: S3Client = undefined;
    var rc = R2Cache.init(std.testing.allocator, &dummy_client);
    defer rc.deinit();

    const c = rc.cache();
    c.clear(); // should not panic
}

test "detectContentType identifies PNG" {
    const png = "\x89PNG\r\n\x1a\n" ++ "\x00" ** 4;
    try std.testing.expectEqualStrings("image/png", R2Cache.detectContentType(png));
}

test "detectContentType identifies JPEG" {
    const jpeg = "\xFF\xD8\xFF\xE0" ++ "\x00" ** 8;
    try std.testing.expectEqualStrings("image/jpeg", R2Cache.detectContentType(jpeg));
}

test "detectContentType identifies WebP" {
    try std.testing.expectEqualStrings("image/webp", R2Cache.detectContentType("RIFF\x00\x00\x00\x00WEBP"));
}

test "detectContentType identifies AVIF" {
    try std.testing.expectEqualStrings("image/avif", R2Cache.detectContentType("\x00\x00\x00\x1cftypavif"));
}

test "detectContentType identifies GIF" {
    try std.testing.expectEqualStrings("image/gif", R2Cache.detectContentType("GIF89a" ++ "\x00" ** 6));
    try std.testing.expectEqualStrings("image/gif", R2Cache.detectContentType("GIF87a" ++ "\x00" ** 6));
}

test "detectContentType returns octet-stream for unknown" {
    try std.testing.expectEqualStrings("application/octet-stream", R2Cache.detectContentType("unknown"));
}

test "detectContentType returns octet-stream for short data" {
    try std.testing.expectEqualStrings("application/octet-stream", R2Cache.detectContentType("x"));
    try std.testing.expectEqualStrings("application/octet-stream", R2Cache.detectContentType(""));
}
