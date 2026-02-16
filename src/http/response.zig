// HTTP response helpers
//
// Utilities for building HTTP response metadata: content-type mapping,
// ETag generation, Cache-Control header construction, and conditional
// request (304 Not Modified) support.

const std = @import("std");
const params = @import("../transform/params.zig");
const OutputFormat = params.OutputFormat;

/// Metadata attached to every image response.
pub const ResponseMeta = struct {
    content_type: []const u8,
    cache_control: []const u8,
    etag: ?[]const u8,
    vary: []const u8 = "Accept",
};

/// Map an OutputFormat to its MIME content-type string.
/// Delegates to `OutputFormat.contentType()` to maintain a single source of truth.
pub fn contentTypeFromFormat(format: OutputFormat) []const u8 {
    return format.contentType();
}

/// Generate a short hex-encoded ETag from the given data.
///
/// Uses Wyhash over the first 8192 bytes (or all bytes if shorter) and
/// returns the 64-bit hash formatted as a 16-character lower-case hex
/// string stored in a fixed-size `[16]u8` array.
pub fn generateEtag(data: []const u8) [16]u8 {
    const limit = @min(data.len, 8192);
    const hash = std.hash.Wyhash.hash(data.len, data[0..limit]);
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{hash}) catch unreachable;
    return buf;
}

/// Build a Cache-Control header value into the caller-provided buffer.
///
/// Returns a slice of `buf` containing the formatted header, e.g.
/// `"public, max-age=3600"` or `"private, max-age=60"`.
pub fn buildCacheControl(max_age: u32, is_public: bool, buf: []u8) []const u8 {
    const visibility: []const u8 = if (is_public) "public" else "private";
    const result = std.fmt.bufPrint(buf, "{s}, max-age={d}", .{ visibility, max_age }) catch
        return "public, max-age=0";
    return result;
}

/// Determine whether the client's `If-None-Match` value matches the
/// current response ETag, indicating a 304 Not Modified response is
/// appropriate.
///
/// Handles:
/// - Exact match
/// - Quoted ETags (`"abc123"`)
/// - Weak ETags (`W/"abc123"`)
pub fn shouldReturn304(request_etag: ?[]const u8, response_etag: []const u8) bool {
    const raw = request_etag orelse return false;
    const stripped = stripEtagDecorations(raw);
    const clean_response = stripEtagDecorations(response_etag);
    return std.mem.eql(u8, stripped, clean_response);
}

/// Remove the optional `W/` weak prefix and surrounding double-quotes
/// from an ETag value, returning the bare identifier.
fn stripEtagDecorations(etag: []const u8) []const u8 {
    var s = etag;

    // Strip weak prefix
    if (s.len >= 2 and s[0] == 'W' and s[1] == '/') {
        s = s[2..];
    }

    // Strip surrounding quotes
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        s = s[1 .. s.len - 1];
    }

    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "contentTypeFromFormat maps jpeg" {
    try std.testing.expectEqualStrings("image/jpeg", contentTypeFromFormat(.jpeg));
}

test "contentTypeFromFormat maps png" {
    try std.testing.expectEqualStrings("image/png", contentTypeFromFormat(.png));
}

test "contentTypeFromFormat maps webp" {
    try std.testing.expectEqualStrings("image/webp", contentTypeFromFormat(.webp));
}

test "contentTypeFromFormat maps avif" {
    try std.testing.expectEqualStrings("image/avif", contentTypeFromFormat(.avif));
}

test "contentTypeFromFormat maps gif" {
    try std.testing.expectEqualStrings("image/gif", contentTypeFromFormat(.gif));
}

test "contentTypeFromFormat maps auto to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", contentTypeFromFormat(.auto));
}

test "generateEtag produces consistent output" {
    const data = "hello world";
    const etag1 = generateEtag(data);
    const etag2 = generateEtag(data);
    try std.testing.expectEqualStrings(&etag1, &etag2);
}

test "generateEtag differs for different data" {
    const etag_a = generateEtag("aaa");
    const etag_b = generateEtag("bbb");
    try std.testing.expect(!std.mem.eql(u8, &etag_a, &etag_b));
}

test "generateEtag returns 16-character hex string" {
    const etag = generateEtag("test data");
    try std.testing.expectEqual(@as(usize, 16), etag.len);
    for (etag) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "buildCacheControl public" {
    var buf: [64]u8 = undefined;
    const result = buildCacheControl(3600, true, &buf);
    try std.testing.expectEqualStrings("public, max-age=3600", result);
}

test "buildCacheControl private" {
    var buf: [64]u8 = undefined;
    const result = buildCacheControl(60, false, &buf);
    try std.testing.expectEqualStrings("private, max-age=60", result);
}

test "buildCacheControl zero max-age" {
    var buf: [64]u8 = undefined;
    const result = buildCacheControl(0, true, &buf);
    try std.testing.expectEqualStrings("public, max-age=0", result);
}

test "shouldReturn304 exact match returns true" {
    const etag = generateEtag("some image data");
    try std.testing.expect(shouldReturn304(&etag, &etag));
}

test "shouldReturn304 no request etag returns false" {
    const etag = generateEtag("some image data");
    try std.testing.expect(!shouldReturn304(null, &etag));
}

test "shouldReturn304 mismatch returns false" {
    const etag_a = generateEtag("data a");
    const etag_b = generateEtag("data b");
    try std.testing.expect(!shouldReturn304(&etag_a, &etag_b));
}

test "shouldReturn304 quoted etag handling" {
    const etag = generateEtag("image bytes");
    // Wrap in quotes as a browser would send
    var quoted_buf: [18]u8 = undefined;
    quoted_buf[0] = '"';
    @memcpy(quoted_buf[1..17], &etag);
    quoted_buf[17] = '"';
    try std.testing.expect(shouldReturn304(&quoted_buf, &etag));
}

test "shouldReturn304 weak etag handling" {
    const etag = generateEtag("image bytes");
    // Wrap as weak etag: W/"..."
    var weak_buf: [20]u8 = undefined;
    weak_buf[0] = 'W';
    weak_buf[1] = '/';
    weak_buf[2] = '"';
    @memcpy(weak_buf[3..19], &etag);
    weak_buf[19] = '"';
    try std.testing.expect(shouldReturn304(&weak_buf, &etag));
}

test "ResponseMeta default vary is Accept" {
    const meta = ResponseMeta{
        .content_type = "image/png",
        .cache_control = "public, max-age=3600",
        .etag = null,
    };
    try std.testing.expectEqualStrings("Accept", meta.vary);
}
