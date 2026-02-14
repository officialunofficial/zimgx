const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const RouterError = error{
    PathTraversal,
    InvalidPath,
    EmptyPath,
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const ImageRequest = struct {
    /// The path to the image, with leading `/` stripped.
    /// Everything before the optional transform segment.
    image_path: []const u8,

    /// The last path segment if it looks like a transform string (contains `=`).
    /// `null` when the URL has no transform segment.
    transform_string: ?[]const u8,
};

pub const Route = union(enum) {
    image_request: ImageRequest,
    health,
    metrics,
    ready,
    not_found,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Resolve a raw request path into a `Route`.
///
/// Well-known paths (`/health`, `/metrics`, `/ready`) are matched first.
/// Everything else is treated as a potential image request.  The last path
/// segment is considered a transform string when it contains an `=`
/// character.
pub fn resolve(path: []const u8) Route {
    // Sanitize — if sanitization fails the path is invalid / dangerous.
    const clean = sanitizePath(path) catch return .not_found;

    // After sanitization the leading `/` has been stripped, so the
    // well-known endpoints are bare words.
    if (mem.eql(u8, clean, "health")) return .health;
    if (mem.eql(u8, clean, "metrics")) return .metrics;
    if (mem.eql(u8, clean, "ready")) return .ready;

    // Split off the last segment and decide whether it is a transform.
    if (mem.lastIndexOfScalar(u8, clean, '/')) |sep| {
        const prefix = clean[0..sep];
        const last = clean[sep + 1 ..];

        if (containsEquals(last)) {
            // Last segment is a transform string.  The image path is
            // everything before it.
            if (prefix.len == 0) {
                // Path was something like "/w=400" — no actual image path.
                return .not_found;
            }
            return .{ .image_request = .{
                .image_path = prefix,
                .transform_string = last,
            } };
        }

        // Last segment is NOT a transform — entire cleaned path is image path.
        return .{ .image_request = .{
            .image_path = clean,
            .transform_string = null,
        } };
    }

    // No `/` in the cleaned path — single segment.
    // If it looks like a transform with no image path, that's not valid.
    if (containsEquals(clean)) {
        return .not_found;
    }

    // Single-segment image path (e.g. "cat.jpg").
    if (clean.len == 0) {
        return .not_found;
    }

    return .{ .image_request = .{
        .image_path = clean,
        .transform_string = null,
    } };
}

/// Sanitize a URL path for safe filesystem use.
///
/// - Strips the leading `/`.
/// - Rejects paths containing `..` (directory traversal).
/// - Rejects paths containing null bytes.
/// - Rejects paths that are empty after stripping.
/// - Rejects paths that still begin with `/` after stripping (embedded
///   absolute paths such as `//etc/passwd`).
pub fn sanitizePath(path: []const u8) RouterError![]const u8 {
    // Reject null bytes anywhere in the path.
    if (mem.indexOfScalar(u8, path, 0)) |_| {
        return RouterError.InvalidPath;
    }

    // Strip leading slash.
    const stripped = if (path.len > 0 and path[0] == '/')
        path[1..]
    else
        path;

    // Empty after stripping → error.
    if (stripped.len == 0) {
        return RouterError.EmptyPath;
    }

    // Reject embedded absolute paths (double leading slash → stripped starts
    // with `/`).
    if (stripped[0] == '/') {
        return RouterError.InvalidPath;
    }

    // Reject directory traversal — both literal (`..`) and
    // percent-encoded (`%2e`, `%2f`, `%00`) forms.
    if (containsTraversal(stripped) or containsEncodedTraversal(stripped)) {
        return RouterError.PathTraversal;
    }

    return stripped;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns `true` when `segment` contains at least one `=` character.
fn containsEquals(segment: []const u8) bool {
    return mem.indexOfScalar(u8, segment, '=') != null;
}

/// Returns `true` when `path` contains a `..` traversal component.
///
/// Matches:
///   - `..` as the entire path
///   - `../` at the start
///   - `/../` or `/..` anywhere inside
///   - `/..` at the end
fn containsTraversal(path: []const u8) bool {
    // Check for exact ".."
    if (mem.eql(u8, path, "..")) return true;

    // Check for "../" prefix
    if (mem.startsWith(u8, path, "../")) return true;

    // Check for "/.." at the end
    if (mem.endsWith(u8, path, "/..")) return true;

    // Check for "/../" anywhere
    if (mem.indexOf(u8, path, "/../")) |_| return true;

    return false;
}

/// Returns `true` when `path` contains percent-encoded sequences that
/// could bypass literal traversal/null-byte checks after URL decoding.
///
/// Rejects: %2e/%2E (dot), %2f/%2F (slash), %00 (null byte).
fn containsEncodedTraversal(path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '%' or i + 2 >= path.len) continue;

        const hi = path[i + 1];
        const lo = path[i + 2];

        // %2e / %2E (dot), %2f / %2F (slash)
        if (hi == '2' and (lo == 'e' or lo == 'E' or lo == 'f' or lo == 'F')) return true;
        // %00 (null byte)
        if (hi == '0' and lo == '0') return true;
    }
    return false;
}

// ===========================================================================
// Tests
// ===========================================================================

test "health endpoint" {
    const route = resolve("/health");
    try testing.expect(route == .health);
}

test "metrics endpoint" {
    const route = resolve("/metrics");
    try testing.expect(route == .metrics);
}

test "ready endpoint" {
    const route = resolve("/ready");
    try testing.expect(route == .ready);
}

test "image with transforms" {
    const route = resolve("/photos/cat.jpg/w=400,h=300");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("photos/cat.jpg", req.image_path);
            try testing.expectEqualStrings("w=400,h=300", req.transform_string.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "image without transforms" {
    const route = resolve("/photos/cat.jpg");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("photos/cat.jpg", req.image_path);
            try testing.expect(req.transform_string == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nested path with transforms" {
    const route = resolve("/a/b/c/d.jpg/w=100");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("a/b/c/d.jpg", req.image_path);
            try testing.expectEqualStrings("w=100", req.transform_string.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "root path returns not_found" {
    const route = resolve("/");
    try testing.expect(route == .not_found);
}

test "empty path returns not_found" {
    const route = resolve("");
    try testing.expect(route == .not_found);
}

test "path traversal is rejected by sanitizePath" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/photos/../etc/passwd"));
}

test "path traversal in resolve returns not_found" {
    const route = resolve("/photos/../etc/passwd/w=100");
    try testing.expect(route == .not_found);
}

test "null byte is rejected by sanitizePath" {
    try testing.expectError(RouterError.InvalidPath, sanitizePath("/photos/cat\x00.jpg"));
}

test "null byte in resolve returns not_found" {
    const route = resolve("/photos/cat\x00.jpg");
    try testing.expect(route == .not_found);
}

test "transform detection — segment with = is transform" {
    const route = resolve("/img.png/quality=80");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("img.png", req.image_path);
            try testing.expectEqualStrings("quality=80", req.transform_string.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "transform detection — segment without = is part of path" {
    const route = resolve("/photos/vacation/beach.jpg");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("photos/vacation/beach.jpg", req.image_path);
            try testing.expect(req.transform_string == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "path with only transforms and no image path returns not_found" {
    const route = resolve("/w=400");
    try testing.expect(route == .not_found);
}

test "sanitizePath strips leading slash" {
    const result = try sanitizePath("/photos/cat.jpg");
    try testing.expectEqualStrings("photos/cat.jpg", result);
}

test "sanitizePath rejects empty path" {
    try testing.expectError(RouterError.EmptyPath, sanitizePath(""));
}

test "sanitizePath rejects bare slash" {
    try testing.expectError(RouterError.EmptyPath, sanitizePath("/"));
}

test "sanitizePath rejects embedded absolute path" {
    try testing.expectError(RouterError.InvalidPath, sanitizePath("//etc/passwd"));
}

test "sanitizePath rejects dot-dot at start" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/../etc/passwd"));
}

test "sanitizePath rejects dot-dot at end" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/photos/.."));
}

test "sanitizePath rejects bare dot-dot" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/.."));
}

test "sanitizePath accepts normal paths" {
    const result = try sanitizePath("/a/b/c/file.jpg");
    try testing.expectEqualStrings("a/b/c/file.jpg", result);
}

test "single segment image path" {
    const route = resolve("/cat.jpg");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("cat.jpg", req.image_path);
            try testing.expect(req.transform_string == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "multiple transform-like segments — only last is treated as transform" {
    // "/a=1/b=2" — last segment "b=2" is the transform, "a=1" is part of image path.
    const route = resolve("/a=1/b=2");
    switch (route) {
        .image_request => |req| {
            try testing.expectEqualStrings("a=1", req.image_path);
            try testing.expectEqualStrings("b=2", req.transform_string.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "sanitizePath rejects percent-encoded dot traversal" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/photos/%2e%2e/etc/passwd"));
}

test "sanitizePath rejects uppercase percent-encoded dot" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/photos/%2E%2E/etc/passwd"));
}

test "sanitizePath rejects encoded null byte" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/photos/cat%00.jpg"));
}

test "sanitizePath rejects encoded slash" {
    try testing.expectError(RouterError.PathTraversal, sanitizePath("/photos%2Fcat.jpg"));
}

test "encoded traversal in resolve returns not_found" {
    const route = resolve("/photos/%2e%2e/etc/passwd");
    try testing.expect(route == .not_found);
}
