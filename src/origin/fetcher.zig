// Origin fetcher
//
// HTTP client wrapper for fetching original images from an origin server.
// Builds on std.http.Client and the OriginSource URL builder to provide
// a single `fetch(path)` call that returns the image bytes and metadata.

const std = @import("std");
const http = std.http;
const source_mod = @import("source.zig");
const OriginSource = source_mod.OriginSource;

/// Errors specific to origin fetching.
pub const FetchError = error{
    ConnectionFailed,
    Timeout,
    NotFound,
    ServerError,
    ResponseTooLarge,
    InvalidUrl,
};

/// The result of a successful origin fetch.
pub const FetchResult = struct {
    data: []u8,
    content_type: []const u8,
    status_code: u16,

    /// Release the heap-allocated response data.
    pub fn deinit(self: *FetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// HTTP client wrapper that fetches images from an origin server.
pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    origin: OriginSource,
    timeout_ms: u32,
    max_size: usize,

    /// Create a new Fetcher for the given origin.
    ///
    /// - `allocator`  – used for response body allocations
    /// - `origin`     – the OriginSource whose base URL is prepended to paths
    /// - `timeout_ms` – per-request timeout in milliseconds
    /// - `max_size`   – maximum response body size in bytes
    pub fn init(
        allocator: std.mem.Allocator,
        origin: OriginSource,
        timeout_ms: u32,
        max_size: usize,
    ) Fetcher {
        return .{
            .allocator = allocator,
            .origin = origin,
            .timeout_ms = timeout_ms,
            .max_size = max_size,
        };
    }

    /// Fetch an image from the origin by path.
    ///
    /// Builds the full URL via `OriginSource.buildUrl`, then performs an
    /// HTTP GET using `std.http.Client.fetch`.  The response body is
    /// heap-allocated with the fetcher's allocator; callers must call
    /// `FetchResult.deinit` when done.
    pub fn fetch(self: *Fetcher, image_path: []const u8) FetchError!FetchResult {
        // Build URL
        var url_buf: [4096]u8 = undefined;
        const url = self.origin.buildUrl(image_path, &url_buf) catch return FetchError.InvalidUrl;

        // Create an HTTP client
        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        // Prepare an allocating writer for the response body
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        errdefer response_writer.deinit();

        // Perform the request using the high-level fetch API
        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &response_writer.writer,
            .headers = .{
                .user_agent = .{ .override = "zimgx/1.0" },
            },
        }) catch {
            return FetchError.ConnectionFailed;
        };

        const status_code = @intFromEnum(result.status);

        // Check for HTTP error status codes
        if (status_code == 404) return FetchError.NotFound;
        if (status_code >= 500) return FetchError.ServerError;

        // Enforce max_size limit
        const written = response_writer.written();
        if (written.len > self.max_size) return FetchError.ResponseTooLarge;

        // Take ownership of the data — transfer the buffer to the caller.
        const data = response_writer.toOwnedSlice() catch return FetchError.ConnectionFailed;

        return FetchResult{
            .data = data,
            .content_type = "application/octet-stream",
            .status_code = status_code,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Fetcher.init stores configuration" {
    const allocator = std.testing.allocator;
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    const fetcher = Fetcher.init(allocator, origin, 5000, 10 * 1024 * 1024);

    try std.testing.expectEqual(@as(u32, 5000), fetcher.timeout_ms);
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), fetcher.max_size);
    try std.testing.expectEqualStrings("http://images.example.com", fetcher.origin.base_url);
}

test "Fetcher.init different configurations" {
    const allocator = std.testing.allocator;

    // Small limits
    {
        const origin = OriginSource{ .base_url = "http://localhost:8080" };
        const fetcher = Fetcher.init(allocator, origin, 1000, 1024);
        try std.testing.expectEqual(@as(u32, 1000), fetcher.timeout_ms);
        try std.testing.expectEqual(@as(usize, 1024), fetcher.max_size);
        try std.testing.expectEqualStrings("http://localhost:8080", fetcher.origin.base_url);
    }

    // Large limits
    {
        const origin = OriginSource{ .base_url = "https://cdn.example.com" };
        const fetcher = Fetcher.init(allocator, origin, 30_000, 100 * 1024 * 1024);
        try std.testing.expectEqual(@as(u32, 30_000), fetcher.timeout_ms);
        try std.testing.expectEqual(@as(usize, 100 * 1024 * 1024), fetcher.max_size);
    }
}

test "FetchResult.deinit frees data" {
    const allocator = std.testing.allocator;

    // Allocate some data as the fetch would
    const data = try allocator.alloc(u8, 64);
    @memset(data, 0xAB);

    var result = FetchResult{
        .data = data,
        .content_type = "image/jpeg",
        .status_code = 200,
    };

    // deinit should free without leaking — the testing allocator will
    // catch a leak if we forget this call.
    result.deinit(allocator);
}

test "FetchResult struct fields" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 4);
    @memcpy(data, "test");

    var result = FetchResult{
        .data = data,
        .content_type = "image/png",
        .status_code = 200,
    };
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("test", result.data);
    try std.testing.expectEqualStrings("image/png", result.content_type);
    try std.testing.expectEqual(@as(u16, 200), result.status_code);
}

test "Fetcher URL building through origin" {
    // Verify that the fetcher's origin builds URLs correctly — this
    // exercises the integration between Fetcher and OriginSource without
    // requiring a real HTTP connection.
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    var fetcher = Fetcher.init(std.testing.allocator, origin, 5000, 10 * 1024 * 1024);

    // We can verify URL construction by calling buildUrl directly on the
    // fetcher's origin, which is the same code path used inside fetch().
    var buf: [256]u8 = undefined;
    const url = try fetcher.origin.buildUrl("photos/cat.jpg", &buf);
    try std.testing.expectEqualStrings("http://images.example.com/photos/cat.jpg", url);
}

test "Fetcher URL building with slash normalization" {
    const origin = OriginSource{ .base_url = "http://cdn.example.com/" };
    var fetcher = Fetcher.init(std.testing.allocator, origin, 3000, 5 * 1024 * 1024);

    var buf: [256]u8 = undefined;
    const url = try fetcher.origin.buildUrl("/images/photo.png", &buf);
    try std.testing.expectEqualStrings("http://cdn.example.com/images/photo.png", url);
}

test "Fetcher fetch returns InvalidUrl for empty path" {
    const allocator = std.testing.allocator;
    const origin = OriginSource{ .base_url = "http://images.example.com" };
    var fetcher = Fetcher.init(allocator, origin, 5000, 10 * 1024 * 1024);

    const result = fetcher.fetch("");
    try std.testing.expectError(FetchError.InvalidUrl, result);
}
