// Origin source configuration
//
// Defines the OriginSource struct which holds the base URL for an image
// origin server and provides URL construction from image paths.

const std = @import("std");

/// Configuration for an origin source (where original images live).
pub const OriginSource = struct {
    base_url: []const u8,

    /// Build the full URL for an image path.
    /// Template: `{base_url}/{path}`
    ///
    /// Handles edge cases:
    /// - Trailing slash on base_url
    /// - Leading slash on path
    /// - Empty path (returns error)
    /// - Buffer too small (returns error)
    pub fn buildUrl(self: OriginSource, path: []const u8, buf: []u8) error{ EmptyPath, NoSpaceLeft }![]const u8 {
        if (path.len == 0) return error.EmptyPath;

        // Strip trailing slash from base_url
        const base = if (self.base_url.len > 0 and self.base_url[self.base_url.len - 1] == '/')
            self.base_url[0 .. self.base_url.len - 1]
        else
            self.base_url;

        // Strip leading slash from path
        const clean_path = if (path[0] == '/')
            path[1..]
        else
            path;

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        writer.writeAll(base) catch return error.NoSpaceLeft;
        writer.writeByte('/') catch return error.NoSpaceLeft;
        writer.writeAll(clean_path) catch return error.NoSpaceLeft;
        return buf[0..stream.pos];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildUrl basic" {
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    var buf: [256]u8 = undefined;
    const url = try origin.buildUrl("photos/cat.jpg", &buf);
    try std.testing.expectEqualStrings("http://images.example.com/photos/cat.jpg", url);
}

test "buildUrl trailing slash on base" {
    const origin = OriginSource{ .base_url = "http://images.example.com/" };
    var buf: [256]u8 = undefined;
    const url = try origin.buildUrl("cat.jpg", &buf);
    try std.testing.expectEqualStrings("http://images.example.com/cat.jpg", url);
}

test "buildUrl leading slash on path" {
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    var buf: [256]u8 = undefined;
    const url = try origin.buildUrl("/cat.jpg", &buf);
    try std.testing.expectEqualStrings("http://images.example.com/cat.jpg", url);
}

test "buildUrl both slashes" {
    const origin = OriginSource{ .base_url = "http://images.example.com/" };
    var buf: [256]u8 = undefined;
    const url = try origin.buildUrl("/cat.jpg", &buf);
    try std.testing.expectEqualStrings("http://images.example.com/cat.jpg", url);
}

test "buildUrl nested path" {
    const origin = OriginSource{ .base_url = "http://cdn.example.com" };
    var buf: [256]u8 = undefined;
    const url = try origin.buildUrl("a/b/c/photo.jpg", &buf);
    try std.testing.expectEqualStrings("http://cdn.example.com/a/b/c/photo.jpg", url);
}

test "buildUrl empty path returns error" {
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    var buf: [256]u8 = undefined;
    const result = origin.buildUrl("", &buf);
    try std.testing.expectError(error.EmptyPath, result);
}

test "buildUrl buffer too small" {
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    var buf: [10]u8 = undefined;
    const result = origin.buildUrl("photos/cat.jpg", &buf);
    try std.testing.expectError(error.NoSpaceLeft, result);
}
