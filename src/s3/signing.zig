// AWS Signature V4 signing for S3 requests
//
// Pure-logic module with no I/O. Computes cryptographic signatures for
// authenticating S3-compatible API requests (AWS S3, Cloudflare R2, etc.)
// using HMAC-SHA256 and SHA-256 from the Zig standard library.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const service = "s3";
const algorithm = "AWS4-HMAC-SHA256";
const signed_headers = "host;x-amz-content-sha256;x-amz-date";

pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8, // "auto" for R2
};

pub const SignedHeaders = struct {
    authorization: []const u8,
    x_amz_date: []const u8,
    x_amz_content_sha256: []const u8,
};

/// SHA-256 hex hash of the given data, written into the 64-byte output buffer.
pub fn hashPayload(data: []const u8, out: *[64]u8) void {
    var hasher = Sha256.init(.{});
    hasher.update(data);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    out.* = hex;
}

/// Returns a pointer to the comptime-computed SHA-256 hex hash of the empty string.
pub fn emptyPayloadHash() *const [64]u8 {
    const hash = comptime blk: {
        @setEvalBranchQuota(10000);
        var out: [64]u8 = undefined;
        hashPayload("", &out);
        break :blk out;
    };
    return &hash;
}

/// Sign an S3 request using AWS Signature V4.
///
/// All string building happens in `buf`, and the returned `SignedHeaders`
/// slices point into that buffer. The caller must ensure `buf` outlives
/// the returned struct.
pub fn signRequest(
    method: []const u8,
    path: []const u8,
    host: []const u8,
    payload_hash: []const u8,
    credentials: Credentials,
    timestamp: []const u8,
    buf: []u8,
) !SignedHeaders {
    const date = timestamp[0..8]; // YYYYMMDD

    // -- Step 1: Canonical request --
    var canonical_buf: [2048]u8 = undefined;
    const canonical_request = try buildCanonicalRequest(
        &canonical_buf,
        method,
        path,
        host,
        payload_hash,
        timestamp,
    );

    // -- Step 2: String to sign --
    var sts_buf: [512]u8 = undefined;
    const string_to_sign = try buildStringToSign(
        &sts_buf,
        timestamp,
        date,
        credentials.region,
        canonical_request,
    );

    // -- Step 3: Signing key derivation --
    const signing_key = deriveSigningKey(
        credentials.secret_key,
        date,
        credentials.region,
    );

    // -- Step 4: Signature --
    var sig_hmac: [HmacSha256.mac_length]u8 = undefined;
    var mac = HmacSha256.init(&signing_key);
    mac.update(string_to_sign);
    mac.final(&sig_hmac);

    const hex_signature = std.fmt.bytesToHex(sig_hmac, .lower);

    // -- Step 5: Build authorization header into caller's buf --
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    try writer.writeAll(algorithm);
    try writer.writeAll(" Credential=");
    try writer.writeAll(credentials.access_key);
    try writer.writeByte('/');
    try writer.writeAll(date);
    try writer.writeByte('/');
    try writer.writeAll(credentials.region);
    try writer.writeByte('/');
    try writer.writeAll(service);
    try writer.writeAll("/aws4_request, SignedHeaders=");
    try writer.writeAll(signed_headers);
    try writer.writeAll(", Signature=");
    try writer.writeAll(&hex_signature);

    const auth_len = stream.pos;
    const authorization = buf[0..auth_len];

    return SignedHeaders{
        .authorization = authorization,
        .x_amz_date = timestamp,
        .x_amz_content_sha256 = payload_hash,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// URI-encode a path for the canonical request per AWS SigV4 spec.
///
/// Encodes every byte except unreserved characters (A-Z, a-z, 0-9,
/// '-', '.', '_', '~') and forward slash '/'.  Uses uppercase hex
/// encoding (e.g., '=' → '%3D').
fn uriEncodePath(writer: anytype, path: []const u8) !void {
    for (path) |c| {
        if (isUnreserved(c) or c == '/') {
            try writer.writeByte(c);
        } else {
            try writer.writeByte('%');
            const hex = "0123456789ABCDEF";
            try writer.writeByte(hex[c >> 4]);
            try writer.writeByte(hex[c & 0x0F]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

/// Build the canonical request string per AWS Sig V4 spec.
///
/// Format:
///   METHOD\n
///   /path\n
///   \n                          (empty query string)
///   host:value\n
///   x-amz-content-sha256:value\n
///   x-amz-date:value\n
///   \n
///   host;x-amz-content-sha256;x-amz-date\n
///   payload_hash
fn buildCanonicalRequest(
    buf: *[2048]u8,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    payload_hash: []const u8,
    timestamp: []const u8,
) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    // HTTP method
    try writer.writeAll(method);
    try writer.writeByte('\n');
    // Canonical URI — URI-encode each byte except unreserved chars and '/'
    try uriEncodePath(writer, path);
    try writer.writeByte('\n');
    // Canonical query string (empty for simple S3 operations)
    try writer.writeByte('\n');
    // Canonical headers — sorted alphabetically, lowercase
    try writer.writeAll("host:");
    try writer.writeAll(host);
    try writer.writeByte('\n');
    try writer.writeAll("x-amz-content-sha256:");
    try writer.writeAll(payload_hash);
    try writer.writeByte('\n');
    try writer.writeAll("x-amz-date:");
    try writer.writeAll(timestamp);
    try writer.writeByte('\n');
    // Blank line after headers
    try writer.writeByte('\n');
    // Signed headers list
    try writer.writeAll(signed_headers);
    try writer.writeByte('\n');
    // Hashed payload
    try writer.writeAll(payload_hash);

    return buf[0..stream.pos];
}

/// Build the "string to sign" for AWS Sig V4.
///
/// Format:
///   AWS4-HMAC-SHA256\n
///   timestamp\n
///   date/region/s3/aws4_request\n
///   hex(SHA-256(canonical_request))
fn buildStringToSign(
    buf: *[512]u8,
    timestamp: []const u8,
    date: []const u8,
    region: []const u8,
    canonical_request: []const u8,
) ![]const u8 {
    // Hash the canonical request
    var hasher = Sha256.init(.{});
    hasher.update(canonical_request);
    const digest = hasher.finalResult();
    const hex_hash = std.fmt.bytesToHex(digest, .lower);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    try writer.writeAll(algorithm);
    try writer.writeByte('\n');
    try writer.writeAll(timestamp);
    try writer.writeByte('\n');
    // Credential scope
    try writer.writeAll(date);
    try writer.writeByte('/');
    try writer.writeAll(region);
    try writer.writeByte('/');
    try writer.writeAll(service);
    try writer.writeAll("/aws4_request");
    try writer.writeByte('\n');
    try writer.writeAll(&hex_hash);

    return buf[0..stream.pos];
}

/// Derive the signing key by chaining HMAC-SHA256 operations.
///
///   date_key    = HMAC("AWS4" + secret_key, date)
///   region_key  = HMAC(date_key, region)
///   service_key = HMAC(region_key, "s3")
///   signing_key = HMAC(service_key, "aws4_request")
fn deriveSigningKey(
    secret_key: []const u8,
    date: []const u8,
    region: []const u8,
) [HmacSha256.mac_length]u8 {
    // Build "AWS4" + secret_key as the initial key
    var prefix_buf: [256]u8 = undefined;
    const prefix = "AWS4";
    @memcpy(prefix_buf[0..prefix.len], prefix);
    @memcpy(prefix_buf[prefix.len..][0..secret_key.len], secret_key);
    const initial_key = prefix_buf[0 .. prefix.len + secret_key.len];

    // date_key = HMAC(initial_key, date)
    var date_key: [HmacSha256.mac_length]u8 = undefined;
    var mac = HmacSha256.init(initial_key);
    mac.update(date);
    mac.final(&date_key);

    // region_key = HMAC(date_key, region)
    var region_key: [HmacSha256.mac_length]u8 = undefined;
    mac = HmacSha256.init(&date_key);
    mac.update(region);
    mac.final(&region_key);

    // service_key = HMAC(region_key, "s3")
    var service_key: [HmacSha256.mac_length]u8 = undefined;
    mac = HmacSha256.init(&region_key);
    mac.update(service);
    mac.final(&service_key);

    // signing_key = HMAC(service_key, "aws4_request")
    var signing_key: [HmacSha256.mac_length]u8 = undefined;
    mac = HmacSha256.init(&service_key);
    mac.update("aws4_request");
    mac.final(&signing_key);

    return signing_key;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hashPayload produces correct hex for empty string" {
    var out: [64]u8 = undefined;
    hashPayload("", &out);
    const expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expectEqualStrings(expected, &out);
}

test "emptyPayloadHash returns same value as hashing empty string" {
    var out: [64]u8 = undefined;
    hashPayload("", &out);
    try std.testing.expectEqualStrings(&out, emptyPayloadHash());
}

test "signRequest returns authorization starting with AWS4-HMAC-SHA256" {
    var buf: [1024]u8 = undefined;
    const result = try signRequest(
        "GET",
        "/my-bucket/my-key.jpg",
        "accountid.r2.cloudflarestorage.com",
        emptyPayloadHash(),
        .{
            .access_key = "AKIAIOSFODNN7EXAMPLE",
            .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            .region = "auto",
        },
        "20240101T120000Z",
        &buf,
    );
    try std.testing.expect(std.mem.startsWith(u8, result.authorization, "AWS4-HMAC-SHA256"));
}

test "signRequest authorization contains Credential=" {
    var buf: [1024]u8 = undefined;
    const result = try signRequest(
        "GET",
        "/my-bucket/my-key.jpg",
        "accountid.r2.cloudflarestorage.com",
        emptyPayloadHash(),
        .{
            .access_key = "AKIAIOSFODNN7EXAMPLE",
            .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            .region = "auto",
        },
        "20240101T120000Z",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.authorization, "Credential=") != null);
}

test "signRequest authorization contains SignedHeaders=host;x-amz-content-sha256;x-amz-date" {
    var buf: [1024]u8 = undefined;
    const result = try signRequest(
        "GET",
        "/my-bucket/my-key.jpg",
        "accountid.r2.cloudflarestorage.com",
        emptyPayloadHash(),
        .{
            .access_key = "AKIAIOSFODNN7EXAMPLE",
            .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            .region = "auto",
        },
        "20240101T120000Z",
        &buf,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.authorization, "SignedHeaders=host;x-amz-content-sha256;x-amz-date") != null,
    );
}

test "signRequest authorization contains Signature= followed by 64 hex chars" {
    var buf: [1024]u8 = undefined;
    const result = try signRequest(
        "GET",
        "/my-bucket/my-key.jpg",
        "accountid.r2.cloudflarestorage.com",
        emptyPayloadHash(),
        .{
            .access_key = "AKIAIOSFODNN7EXAMPLE",
            .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            .region = "auto",
        },
        "20240101T120000Z",
        &buf,
    );

    const marker = "Signature=";
    const idx = std.mem.indexOf(u8, result.authorization, marker);
    try std.testing.expect(idx != null);

    const sig_start = idx.? + marker.len;
    const sig_slice = result.authorization[sig_start..];
    // Signature must be exactly 64 hex characters
    try std.testing.expectEqual(@as(usize, 64), sig_slice.len);
    for (sig_slice) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "same inputs produce same signature (deterministic)" {
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const creds = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
    };
    const result1 = try signRequest(
        "PUT",
        "/bucket/object.png",
        "s3.amazonaws.com",
        emptyPayloadHash(),
        creds,
        "20240615T083000Z",
        &buf1,
    );
    const result2 = try signRequest(
        "PUT",
        "/bucket/object.png",
        "s3.amazonaws.com",
        emptyPayloadHash(),
        creds,
        "20240615T083000Z",
        &buf2,
    );
    try std.testing.expectEqualStrings(result1.authorization, result2.authorization);
}

test "different timestamps produce different signatures" {
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const creds = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
    };
    const result1 = try signRequest(
        "GET",
        "/bucket/object.png",
        "s3.amazonaws.com",
        emptyPayloadHash(),
        creds,
        "20240101T120000Z",
        &buf1,
    );
    const result2 = try signRequest(
        "GET",
        "/bucket/object.png",
        "s3.amazonaws.com",
        emptyPayloadHash(),
        creds,
        "20240202T130000Z",
        &buf2,
    );
    try std.testing.expect(!std.mem.eql(u8, result1.authorization, result2.authorization));
}
