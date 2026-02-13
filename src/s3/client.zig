// S3 HTTP client
//
// Authenticated S3 operations (GET, PUT, DELETE, HEAD) using std.http.Client
// and the signing module for AWS Signature V4. Compatible with AWS S3,
// Cloudflare R2, and other S3-compatible services.

const std = @import("std");
const http = std.http;
const signing = @import("signing.zig");

/// Errors specific to S3 operations.
pub const S3Error = error{
    ConnectionFailed,
    SigningFailed,
    NotFound,
    AccessDenied,
    ServerError,
    InvalidEndpoint,
};

/// The result of a successful S3 GET operation.
pub const S3Response = struct {
    data: []u8,
    content_type: []const u8,
    status: u16,

    /// Release the heap-allocated response body.
    pub fn deinit(self: *S3Response, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// HTTP client wrapper for authenticated S3 requests.
pub const S3Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    bucket: []const u8,
    credentials: signing.Credentials,

    /// Create a new S3Client.
    ///
    /// - `allocator`   - used for response body allocations
    /// - `endpoint`    - S3/R2 endpoint URL (e.g., "https://accountid.r2.cloudflarestorage.com")
    /// - `bucket`      - bucket name
    /// - `credentials` - AWS/R2 access key, secret key, and region
    pub fn init(
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        bucket: []const u8,
        credentials: signing.Credentials,
    ) S3Client {
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .bucket = bucket,
            .credentials = credentials,
        };
    }

    /// Fetch an object from S3 by key.
    ///
    /// Returns the response body, content type, and status on success.
    /// Returns `null` if the object does not exist (404).
    pub fn getObject(self: *S3Client, key: []const u8) S3Error!?S3Response {
        var path_buf: [4096]u8 = undefined;
        var url_buf: [4096]u8 = undefined;
        var ts_buf: [16]u8 = undefined;
        var sign_buf: [1024]u8 = undefined;

        const path = buildPath(self.bucket, key, &path_buf) catch return S3Error.InvalidEndpoint;
        const url = buildUrl(self.endpoint, self.bucket, key, &url_buf) catch return S3Error.InvalidEndpoint;
        formatTimestamp(std.time.timestamp(), &ts_buf);

        const signed = signing.signRequest(
            "GET",
            path,
            extractHost(self.endpoint),
            signing.emptyPayloadHash(),
            self.credentials,
            &ts_buf,
            &sign_buf,
        ) catch return S3Error.SigningFailed;

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var response_writer = std.Io.Writer.Allocating.init(self.allocator);

        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &response_writer.writer,
            .headers = .{ .user_agent = .{ .override = "zimgx/1.0" } },
            .extra_headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "x-amz-date", .value = signed.x_amz_date },
                .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
            },
        }) catch {
            response_writer.deinit();
            return S3Error.ConnectionFailed;
        };

        const status_code: u16 = @intFromEnum(result.status);

        if (status_code == 404) {
            response_writer.deinit();
            return null;
        }
        if (status_code == 403) {
            response_writer.deinit();
            return S3Error.AccessDenied;
        }
        if (status_code >= 500) {
            response_writer.deinit();
            return S3Error.ServerError;
        }

        const data = response_writer.toOwnedSlice() catch {
            response_writer.deinit();
            return S3Error.ConnectionFailed;
        };

        return S3Response{
            .data = data,
            .content_type = "application/octet-stream",
            .status = status_code,
        };
    }

    /// Upload an object to S3.
    ///
    /// Returns `true` on success (200 or 201), or an error on failure.
    pub fn putObject(
        self: *S3Client,
        key: []const u8,
        data: []const u8,
        content_type: []const u8,
    ) S3Error!bool {
        var path_buf: [4096]u8 = undefined;
        var url_buf: [4096]u8 = undefined;
        var ts_buf: [16]u8 = undefined;
        var sign_buf: [1024]u8 = undefined;

        const path = buildPath(self.bucket, key, &path_buf) catch return S3Error.InvalidEndpoint;
        const url = buildUrl(self.endpoint, self.bucket, key, &url_buf) catch return S3Error.InvalidEndpoint;
        formatTimestamp(std.time.timestamp(), &ts_buf);

        var payload_hash: [64]u8 = undefined;
        signing.hashPayload(data, &payload_hash);

        const signed = signing.signRequest(
            "PUT",
            path,
            extractHost(self.endpoint),
            &payload_hash,
            self.credentials,
            &ts_buf,
            &sign_buf,
        ) catch return S3Error.SigningFailed;

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = data,
            .headers = .{
                .user_agent = .{ .override = "zimgx/1.0" },
                .content_type = .{ .override = content_type },
            },
            .extra_headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "x-amz-date", .value = signed.x_amz_date },
                .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
            },
        }) catch return S3Error.ConnectionFailed;

        return checkStatus(@intFromEnum(result.status), 200, 201);
    }

    /// Delete an object from S3.
    ///
    /// Returns `true` on success (200 or 204), or an error on failure.
    pub fn deleteObject(self: *S3Client, key: []const u8) S3Error!bool {
        var path_buf: [4096]u8 = undefined;
        var url_buf: [4096]u8 = undefined;
        var ts_buf: [16]u8 = undefined;
        var sign_buf: [1024]u8 = undefined;

        const path = buildPath(self.bucket, key, &path_buf) catch return S3Error.InvalidEndpoint;
        const url = buildUrl(self.endpoint, self.bucket, key, &url_buf) catch return S3Error.InvalidEndpoint;
        formatTimestamp(std.time.timestamp(), &ts_buf);

        const signed = signing.signRequest(
            "DELETE",
            path,
            extractHost(self.endpoint),
            signing.emptyPayloadHash(),
            self.credentials,
            &ts_buf,
            &sign_buf,
        ) catch return S3Error.SigningFailed;

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .DELETE,
            .headers = .{ .user_agent = .{ .override = "zimgx/1.0" } },
            .extra_headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "x-amz-date", .value = signed.x_amz_date },
                .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
            },
        }) catch return S3Error.ConnectionFailed;

        return checkStatus(@intFromEnum(result.status), 200, 204);
    }

    /// Check whether an object exists in S3 via HEAD.
    ///
    /// Returns `true` if the object exists (200), `false` if not found (404).
    pub fn headObject(self: *S3Client, key: []const u8) S3Error!bool {
        var path_buf: [4096]u8 = undefined;
        var url_buf: [4096]u8 = undefined;
        var ts_buf: [16]u8 = undefined;
        var sign_buf: [1024]u8 = undefined;

        const path = buildPath(self.bucket, key, &path_buf) catch return S3Error.InvalidEndpoint;
        const url = buildUrl(self.endpoint, self.bucket, key, &url_buf) catch return S3Error.InvalidEndpoint;
        formatTimestamp(std.time.timestamp(), &ts_buf);

        const signed = signing.signRequest(
            "HEAD",
            path,
            extractHost(self.endpoint),
            signing.emptyPayloadHash(),
            self.credentials,
            &ts_buf,
            &sign_buf,
        ) catch return S3Error.SigningFailed;

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .HEAD,
            .headers = .{ .user_agent = .{ .override = "zimgx/1.0" } },
            .extra_headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "x-amz-date", .value = signed.x_amz_date },
                .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
            },
        }) catch return S3Error.ConnectionFailed;

        return checkStatus(@intFromEnum(result.status), 200, 200);
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Check an HTTP status code for common S3 error patterns, returning
/// `true` if the status matches either success code.
fn checkStatus(status: u16, success1: u16, success2: u16) S3Error!bool {
    if (status == 403) return S3Error.AccessDenied;
    if (status >= 500) return S3Error.ServerError;
    return (status == success1 or status == success2);
}

/// Format epoch seconds as an AWS-style timestamp: "YYYYMMDDTHHMMSSZ" (16 chars).
fn formatTimestamp(epoch: i64, buf: *[16]u8) void {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch) };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    const year: u16 = @intCast(year_day.year);
    const month: u8 = @intFromEnum(month_day.month);
    const day: u8 = month_day.day_index + 1; // day_index is 0-based
    const hour: u8 = day_secs.getHoursIntoDay();
    const minute: u8 = day_secs.getMinutesIntoHour();
    const second: u8 = day_secs.getSecondsIntoMinute();

    _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    }) catch unreachable;
}

/// Extract the host portion from an endpoint URL.
///
/// Strips `https://` or `http://` prefix and any trailing `/`.
fn extractHost(endpoint: []const u8) []const u8 {
    var host = endpoint;

    if (std.mem.startsWith(u8, host, "https://")) {
        host = host["https://".len..];
    } else if (std.mem.startsWith(u8, host, "http://")) {
        host = host["http://".len..];
    }

    if (host.len > 0 and host[host.len - 1] == '/') {
        host = host[0 .. host.len - 1];
    }

    return host;
}

/// Build the S3 object path: `/{bucket}/{key}`.
fn buildPath(bucket: []const u8, key: []const u8, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    try writer.writeByte('/');
    try writer.writeAll(bucket);
    try writer.writeByte('/');
    try writer.writeAll(key);
    return buf[0..stream.pos];
}

/// Build the full URL: `{endpoint}/{bucket}/{key}`.
fn buildUrl(endpoint: []const u8, bucket: []const u8, key: []const u8, buf: []u8) ![]const u8 {
    const base = if (endpoint.len > 0 and endpoint[endpoint.len - 1] == '/')
        endpoint[0 .. endpoint.len - 1]
    else
        endpoint;

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    try writer.writeAll(base);
    try writer.writeByte('/');
    try writer.writeAll(bucket);
    try writer.writeByte('/');
    try writer.writeAll(key);
    return buf[0..stream.pos];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractHost strips https prefix" {
    const host = extractHost("https://account.r2.cloudflarestorage.com");
    try std.testing.expectEqualStrings("account.r2.cloudflarestorage.com", host);
}

test "extractHost strips http prefix" {
    const host = extractHost("http://s3.amazonaws.com");
    try std.testing.expectEqualStrings("s3.amazonaws.com", host);
}

test "extractHost strips trailing slash" {
    const host = extractHost("https://account.r2.cloudflarestorage.com/");
    try std.testing.expectEqualStrings("account.r2.cloudflarestorage.com", host);
}

test "buildUrl constructs correct URL" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl("https://account.r2.cloudflarestorage.com", "my-bucket", "images/photo.jpg", &buf);
    try std.testing.expectEqualStrings("https://account.r2.cloudflarestorage.com/my-bucket/images/photo.jpg", url);
}

test "buildUrl strips trailing slash from endpoint" {
    var buf: [256]u8 = undefined;
    const url = try buildUrl("https://account.r2.cloudflarestorage.com/", "my-bucket", "key.txt", &buf);
    try std.testing.expectEqualStrings("https://account.r2.cloudflarestorage.com/my-bucket/key.txt", url);
}

test "formatTimestamp produces 16-char string" {
    var buf: [16]u8 = undefined;
    formatTimestamp(1704067200, &buf);
    try std.testing.expectEqualStrings("20240101T000000Z", &buf);
}

test "formatTimestamp mid-day" {
    var buf: [16]u8 = undefined;
    formatTimestamp(1718461845, &buf);
    try std.testing.expectEqualStrings("20240615T143045Z", &buf);
}

test "S3Client.init stores configuration" {
    const allocator = std.testing.allocator;
    const creds = signing.Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "auto",
    };
    const client = S3Client.init(
        allocator,
        "https://accountid.r2.cloudflarestorage.com",
        "my-bucket",
        creds,
    );

    try std.testing.expectEqualStrings("https://accountid.r2.cloudflarestorage.com", client.endpoint);
    try std.testing.expectEqualStrings("my-bucket", client.bucket);
    try std.testing.expectEqualStrings("AKIAIOSFODNN7EXAMPLE", client.credentials.access_key);
    try std.testing.expectEqualStrings("auto", client.credentials.region);
}

test "buildPath constructs /{bucket}/{key}" {
    var buf: [256]u8 = undefined;
    const path = try buildPath("my-bucket", "images/photo.jpg", &buf);
    try std.testing.expectEqualStrings("/my-bucket/images/photo.jpg", path);
}

test "S3Response.deinit frees data" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 64);
    @memset(data, 0xAB);

    var response = S3Response{
        .data = data,
        .content_type = "image/jpeg",
        .status = 200,
    };

    response.deinit(allocator);
}
