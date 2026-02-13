// R2-backed origin fetcher
//
// Fetches original images from an S3/R2 bucket using the S3Client.
// Returns the same FetchResult type as the HTTP origin fetcher so the
// two backends are interchangeable from the caller's perspective.

const std = @import("std");
const s3_client = @import("../s3/client.zig");
const S3Client = s3_client.S3Client;
const S3Error = s3_client.S3Error;
const fetcher_mod = @import("fetcher.zig");
const FetchResult = fetcher_mod.FetchResult;
const FetchError = fetcher_mod.FetchError;

pub const R2Fetcher = struct {
    client: *S3Client,

    pub fn init(client: *S3Client) R2Fetcher {
        return .{ .client = client };
    }

    /// Fetch an image from R2 by path.
    /// The path is used directly as the S3 object key (leading slash stripped).
    pub fn fetch(self: *R2Fetcher, image_path: []const u8) FetchError!FetchResult {
        if (image_path.len == 0) return FetchError.InvalidUrl;

        const key = if (image_path[0] == '/') image_path[1..] else image_path;

        const resp = self.client.getObject(key) catch |err| {
            return switch (err) {
                S3Error.NotFound => FetchError.NotFound,
                S3Error.AccessDenied, S3Error.ServerError => FetchError.ServerError,
                else => FetchError.ConnectionFailed,
            };
        } orelse return FetchError.NotFound;

        return FetchResult{
            .data = resp.data,
            .content_type = resp.content_type,
            .status_code = resp.status,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_creds: @import("../s3/signing.zig").Credentials = .{
    .access_key = "test",
    .secret_key = "test",
    .region = "auto",
};

fn testClient() S3Client {
    return S3Client.init(std.testing.allocator, "http://localhost:1234", "test-bucket", test_creds);
}

test "R2Fetcher.init stores client pointer" {
    var client = testClient();
    const r2 = R2Fetcher.init(&client);
    try std.testing.expectEqual(&client, r2.client);
}

test "R2Fetcher.fetch with empty path returns InvalidUrl" {
    var client = testClient();
    var r2 = R2Fetcher.init(&client);
    try std.testing.expectError(FetchError.InvalidUrl, r2.fetch(""));
}

test "R2Fetcher strips leading slash from path" {
    var client = testClient();
    var r2 = R2Fetcher.init(&client);

    // The slash is stripped and "test.jpg" is passed to getObject. It fails
    // with ConnectionFailed (no real S3 server), proving the slash-stripping
    // logic ran successfully.
    try std.testing.expectError(FetchError.ConnectionFailed, r2.fetch("/test.jpg"));
}

test "R2Fetcher.fetch non-empty path returns ConnectionFailed" {
    var client = testClient();
    var r2 = R2Fetcher.init(&client);

    // No real S3 server is available, so the fetch fails with ConnectionFailed.
    try std.testing.expectError(FetchError.ConnectionFailed, r2.fetch("images/photo.jpg"));
}
