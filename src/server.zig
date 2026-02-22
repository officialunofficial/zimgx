// HTTP server module for the zimgx image proxy.
//
// Provides the `Server` struct with request handling logic and the `run`
// entry point that binds to a port and serves HTTP requests.  The design
// separates pure logic (testable without network I/O) from the actual
// server loop.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Allocator = std.mem.Allocator;

const router = @import("router.zig");
const Route = router.Route;

const config_mod = @import("config.zig");
const Config = config_mod.Config;

const cache_mod = @import("cache/cache.zig");
const Cache = cache_mod.Cache;
const CacheEntry = cache_mod.CacheEntry;

const memory_cache = @import("cache/memory.zig");
const MemoryCache = memory_cache.MemoryCache;

const noop_cache = @import("cache/noop.zig");
const NoopCache = noop_cache.NoopCache;

const response_mod = @import("http/response.zig");
const errors_mod = @import("http/errors.zig");
const HttpError = errors_mod.HttpError;

const params_mod = @import("transform/params.zig");
const TransformParams = params_mod.TransformParams;
const OutputFormat = params_mod.OutputFormat;

const negotiate_mod = @import("transform/negotiate.zig");

const origin_mod = @import("origin/fetcher.zig");
const Fetcher = origin_mod.Fetcher;
const FetchError = origin_mod.FetchError;

const source_mod = @import("origin/source.zig");
const OriginSource = source_mod.OriginSource;

const r2_origin = @import("origin/r2.zig");
const R2Fetcher = r2_origin.R2Fetcher;

const tiered_cache = @import("cache/tiered.zig");
const TieredCache = tiered_cache.TieredCache;

const r2_cache_mod = @import("cache/r2.zig");
const R2Cache = r2_cache_mod.R2Cache;

const s3_mod = @import("s3/client.zig");
const S3Client = s3_mod.S3Client;

const signing = @import("s3/signing.zig");

const pipeline = @import("transform/pipeline.zig");

const alloc_mod = @import("allocator.zig");
const RequestArena = alloc_mod.RequestArena;

const vips = @import("vips/bindings.zig");

// ---------------------------------------------------------------------------
// Response types for testable logic
// ---------------------------------------------------------------------------

/// Represents a fully-formed HTTP response ready to be sent over the wire.
/// This intermediate representation allows the request handling logic to
/// be tested without any network I/O.
pub const ServerResponse = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
    cache_control: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    vary: ?[]const u8 = null,
    /// Optional owned body for uncached fallback responses. Call `deinit`
    /// after the response is sent to free this memory.
    owned_body: ?[]u8 = null,

    pub fn deinit(self: *ServerResponse, allocator: Allocator) void {
        if (self.owned_body) |owned| {
            allocator.free(owned);
            self.owned_body = null;
        }
    }

    pub const health_ok = ServerResponse{
        .status = 200,
        .content_type = "application/json",
        .body = "{\"status\":\"ok\"}",
    };

    pub const ready_ok = ServerResponse{
        .status = 200,
        .content_type = "application/json",
        .body = "{\"ready\":true}",
    };

    pub const not_modified = ServerResponse{
        .status = 304,
        .content_type = "text/plain",
        .body = "",
    };
};

/// Statistics about the running server, exposed via /metrics.
pub const ServerStats = struct {
    requests_total: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_entries: usize = 0,
    uptime_seconds: i64 = 0,

    pub fn toJson(self: ServerStats, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf,
            \\{{"requests_total":{d},"cache_hits":{d},"cache_misses":{d},"cache_entries":{d},"uptime_seconds":{d}}}
        , .{
            self.requests_total,
            self.cache_hits,
            self.cache_misses,
            self.cache_entries,
            self.uptime_seconds,
        }) catch "{\"error\":\"metrics serialization failed\"}";
    }
};

// ---------------------------------------------------------------------------
// Server struct
// ---------------------------------------------------------------------------

pub const Server = struct {
    allocator: Allocator,
    config: Config,
    image_cache: Cache,
    stats: ServerStats = .{},
    start_time: i64,
    /// Optional R2 origin fetcher (set when origin_type == .r2).
    r2_fetcher: ?*R2Fetcher = null,
    /// Active connection count for rate limiting.
    active_connections: u32 = 0,

    pub fn init(allocator: Allocator, cfg: Config, image_cache: Cache) Server {
        return .{
            .allocator = allocator,
            .config = cfg,
            .image_cache = image_cache,
            .stats = .{},
            .start_time = std.time.timestamp(),
        };
    }

    // -----------------------------------------------------------------
    // Pure logic: route dispatch (testable without I/O)
    // -----------------------------------------------------------------

    /// Dispatch a parsed route to the appropriate handler and return a
    /// ServerResponse.  This function is pure logic -- no network I/O.
    /// Thread-safe: called concurrently from worker threads.
    pub fn dispatchRoute(self: *Server, route: Route, if_none_match: ?[]const u8, accept_header: ?[]const u8) ServerResponse {
        _ = @atomicRmw(u64, &self.stats.requests_total, .Add, 1, .monotonic);

        return switch (route) {
            .health => ServerResponse.health_ok,
            .ready => ServerResponse.ready_ok,
            .metrics => self.buildMetricsResponse(),
            .not_found => self.buildErrorResponse(HttpError.notFound(null)),
            .image_request => |req| self.handleImageRequest(req, if_none_match, accept_header),
        };
    }

    // -----------------------------------------------------------------
    // Health / Ready / Metrics
    // -----------------------------------------------------------------

    fn buildMetricsResponse(self: *Server) ServerResponse {
        // Snapshot volatile stats for metrics — reads are non-atomic
        // because exact precision is not required for monitoring.
        var stats = self.stats;
        stats.uptime_seconds = std.time.timestamp() - self.start_time;
        stats.cache_entries = self.image_cache.size();

        var buf: [512]u8 = undefined;
        const json = stats.toJson(&buf);

        // Copy into thread-local buffer so the slice outlives this frame.
        const tl_buf = &metrics_tl_buf;
        @memcpy(tl_buf[0..json.len], json);

        return .{
            .status = 200,
            .content_type = "application/json",
            .body = tl_buf[0..json.len],
        };
    }

    // -----------------------------------------------------------------
    // Error response
    // -----------------------------------------------------------------

    pub fn buildErrorResponse(_: *Server, err: HttpError) ServerResponse {
        // Use a comptime-known error format to avoid dynamic allocation.
        // The error JSON is small enough to fit in a fixed buffer.
        return .{
            .status = err.status,
            .content_type = "application/json",
            .body = errorToStaticJson(err),
        };
    }

    // -----------------------------------------------------------------
    // Image request handling
    // -----------------------------------------------------------------

    fn handleImageRequest(self: *Server, req: router.ImageRequest, if_none_match: ?[]const u8, accept_header: ?[]const u8) ServerResponse {
        // 1. Parse transform params
        const transform_string = req.transform_string orelse "";
        const params = params_mod.parse(transform_string) catch {
            return self.buildErrorResponse(HttpError.badRequest("invalid transform parameters"));
        };

        // 2. Validate params
        params.validate() catch {
            return self.buildErrorResponse(HttpError.unprocessableEntity("transform parameters out of range"));
        };

        // 3. Compute cache key
        const format_str = if (params.format) |f| f.toString() else "auto";
        var cache_key_buf: [512]u8 = undefined;
        const cache_key = cache_mod.computeCacheKey(
            req.image_path,
            transform_string,
            format_str,
            &cache_key_buf,
        );

        // 4. Check cache
        if (self.image_cache.get(cache_key)) |entry| {
            _ = @atomicRmw(u64, &self.stats.cache_hits, .Add, 1, .monotonic);
            return self.serveCachedEntry(entry, if_none_match);
        }

        _ = @atomicRmw(u64, &self.stats.cache_misses, .Add, 1, .monotonic);

        // 5. Fetch from origin (HTTP or R2)
        var fetch_result = self.fetchFromOrigin(req.image_path) catch |err| {
            return switch (err) {
                FetchError.NotFound => self.buildErrorResponse(HttpError.notFound("image not found at origin")),
                FetchError.Timeout => self.buildErrorResponse(HttpError.gatewayTimeout("origin server timed out")),
                FetchError.ResponseTooLarge => self.buildErrorResponse(HttpError.payloadTooLarge("image exceeds size limit")),
                else => self.buildErrorResponse(HttpError.badGateway("failed to fetch from origin")),
            };
        };

        // 6. Transform image via the pipeline
        const anim_cfg = pipeline.AnimConfig{
            .max_frames = self.config.transform.max_frames,
            .max_animated_pixels = self.config.transform.max_animated_pixels,
        };
        var transform_result = pipeline.transform(fetch_result.data, params, accept_header, anim_cfg) catch {
            // Transform failed — cache and serve the original
            const ct = if (params.format) |f| response_mod.contentTypeFromFormat(f) else "application/octet-stream";
            self.image_cache.put(cache_key, .{
                .data = fetch_result.data,
                .content_type = ct,
                .created_at = std.time.timestamp(),
            });
            const resp = self.serveCachedOrBody(cache_key, if_none_match, fetch_result.data, ct);
            fetch_result.deinit(self.allocator);
            return resp;
        };

        // Free the original fetch data (pipeline made its own copy via vips)
        fetch_result.deinit(self.allocator);

        // 7. Cache the transformed result
        const content_type = response_mod.contentTypeFromFormat(transform_result.format);
        self.image_cache.put(cache_key, .{
            .data = transform_result.data,
            .content_type = content_type,
            .created_at = std.time.timestamp(),
        });

        const resp = self.serveCachedOrBody(cache_key, if_none_match, transform_result.data, content_type);

        // Free the vips-allocated transform data (cache made its own copy)
        transform_result.deinit();

        // 8. Serve cached copy, or the uncached body if backend skipped write
        return resp;
    }

    /// Fetch an image from the configured origin (HTTP or R2).
    /// When `origin.path_prefix` is set, strips that prefix from the
    /// image path before fetching so Cloudflare-style account-id
    /// prefixed URLs resolve to the correct origin key.
    fn fetchFromOrigin(self: *Server, image_path: []const u8) FetchError!origin_mod.FetchResult {
        const effective_path = self.stripPathPrefix(image_path);

        if (self.r2_fetcher) |r2f| {
            return r2f.fetch(effective_path);
        }

        const origin = OriginSource{ .base_url = self.config.origin.base_url };
        var fetcher = Fetcher.init(
            self.allocator,
            origin,
            self.config.origin.timeout_ms,
            self.config.server.max_request_size,
        );
        return fetcher.fetch(effective_path);
    }

    /// Strip the configured path prefix from an image path. If the path
    /// starts with `<prefix>/`, the prefix and separator are removed.
    fn stripPathPrefix(self: *Server, path: []const u8) []const u8 {
        const prefix = self.config.origin.path_prefix;
        if (prefix.len == 0) return path;
        if (mem.startsWith(u8, path, prefix)) {
            const rest = path[prefix.len..];
            if (rest.len > 0 and rest[0] == '/') {
                return rest[1..];
            }
            if (rest.len == 0) return path;
        }
        return path;
    }

    /// Build a response from a cache entry, using thread-local buffers
    /// for ETag and Cache-Control so the slices outlive this function.
    fn serveCachedEntry(self: *Server, entry: CacheEntry, if_none_match: ?[]const u8) ServerResponse {
        // Generate ETag into thread-local buffer
        const etag_raw = response_mod.generateEtag(entry.data);
        const etag_buf = &etag_tl_buf;
        @memcpy(etag_buf, &etag_raw);

        // Check If-None-Match for 304
        if (response_mod.shouldReturn304(if_none_match, etag_buf)) {
            return .{
                .status = 304,
                .content_type = entry.content_type,
                .body = "",
                .etag = etag_buf,
            };
        }

        // Build Cache-Control into thread-local buffer
        const cc_buf = &cc_tl_buf;
        const cc = response_mod.buildCacheControl(
            self.config.cache.default_ttl_seconds,
            true,
            cc_buf,
        );

        return .{
            .status = 200,
            .content_type = entry.content_type,
            .body = entry.data,
            .cache_control = cc,
            .etag = etag_buf,
            .vary = "Accept",
        };
    }

    /// Retrieve from cache and serve, or fall back to a direct body response.
    fn serveCachedOrBody(
        self: *Server,
        cache_key: []const u8,
        if_none_match: ?[]const u8,
        body: []const u8,
        content_type: []const u8,
    ) ServerResponse {
        if (self.image_cache.get(cache_key)) |entry| {
            return self.serveCachedEntry(entry, if_none_match);
        }

        return self.serveUncachedBody(body, content_type, if_none_match);
    }

    /// Build a direct response when cache backends intentionally skip writes.
    fn serveUncachedBody(
        self: *Server,
        body: []const u8,
        content_type: []const u8,
        if_none_match: ?[]const u8,
    ) ServerResponse {
        const owned_body = self.allocator.dupe(u8, body) catch {
            return self.buildErrorResponse(HttpError.internalError("failed to allocate response body"));
        };

        // Generate ETag into thread-local buffer
        const etag_raw = response_mod.generateEtag(owned_body);
        const etag_buf = &etag_tl_buf;
        @memcpy(etag_buf, &etag_raw);

        // Check If-None-Match for 304
        if (response_mod.shouldReturn304(if_none_match, etag_buf)) {
            self.allocator.free(owned_body);
            return .{
                .status = 304,
                .content_type = content_type,
                .body = "",
                .etag = etag_buf,
            };
        }

        // Build Cache-Control into thread-local buffer
        const cc_buf = &cc_tl_buf;
        const cc = response_mod.buildCacheControl(
            self.config.cache.default_ttl_seconds,
            true,
            cc_buf,
        );

        return .{
            .status = 200,
            .content_type = content_type,
            .body = owned_body,
            .cache_control = cc,
            .etag = etag_buf,
            .vary = "Accept",
            .owned_body = owned_body,
        };
    }
};

// ---------------------------------------------------------------------------
// Static error JSON helper
// ---------------------------------------------------------------------------

/// Convert an HttpError to a static JSON string.  Uses a set of
/// comptime-known strings so no dynamic allocation is needed.
fn errorToStaticJson(err: HttpError) []const u8 {
    // For well-known errors, return compile-time string literals.
    // For others, fall back to a generic message.
    if (err.detail != null) {
        // Detail requires dynamic formatting; copy into thread-local
        // storage so the slice outlives this function.
        var buf: [512]u8 = undefined;
        const json = err.toJsonResponse(&buf);
        @memcpy(error_tl_buf[0..json.len], json);
        return error_tl_buf[0..json.len];
    }

    return switch (err.status) {
        400 => "{\"error\":{\"status\":400,\"message\":\"Bad Request\"}}",
        404 => "{\"error\":{\"status\":404,\"message\":\"Not Found\"}}",
        413 => "{\"error\":{\"status\":413,\"message\":\"Payload Too Large\"}}",
        422 => "{\"error\":{\"status\":422,\"message\":\"Unprocessable Entity\"}}",
        500 => "{\"error\":{\"status\":500,\"message\":\"Internal Server Error\"}}",
        502 => "{\"error\":{\"status\":502,\"message\":\"Bad Gateway\"}}",
        504 => "{\"error\":{\"status\":504,\"message\":\"Gateway Timeout\"}}",
        else => "{\"error\":{\"status\":0,\"message\":\"Unknown Error\"}}",
    };
}

// Thread-local buffers for response construction. Each worker thread
// gets its own copy so there are no data races.
threadlocal var error_tl_buf: [512]u8 = undefined;
threadlocal var metrics_tl_buf: [512]u8 = undefined;
threadlocal var etag_tl_buf: [16]u8 = undefined;
threadlocal var cc_tl_buf: [64]u8 = undefined;

// ---------------------------------------------------------------------------
// HTTP header extraction helpers
// ---------------------------------------------------------------------------

/// Extract specific header values from the raw HTTP head buffer by
/// iterating over all headers.
pub const RequestHeaders = struct {
    if_none_match: ?[]const u8 = null,
    accept: ?[]const u8 = null,
};

pub fn extractHeaders(head_buffer: []const u8) RequestHeaders {
    var result = RequestHeaders{};
    var it = http.HeaderIterator.init(head_buffer);
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
            result.if_none_match = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
            result.accept = header.value;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// HTTP Server run loop
// ---------------------------------------------------------------------------

pub fn run(allocator: Allocator) !void {
    // 1. Load config
    const cfg = Config.loadFromEnv(allocator) catch {
        std.log.err("Failed to load configuration from environment", .{});
        return error.ConfigError;
    };

    // 2. Validate config
    cfg.validate() catch {
        std.log.err("Invalid configuration", .{});
        return error.ConfigError;
    };

    // 3. Create cache (with optional R2 tiered cache)
    const use_r2 = cfg.origin.origin_type == .r2;

    const r2_creds: signing.Credentials = if (use_r2) .{
        .access_key = cfg.r2.access_key_id,
        .secret_key = cfg.r2.secret_access_key,
        .region = "auto",
    } else undefined;

    var mc: MemoryCache = undefined;
    var nc: NoopCache = undefined;
    var r2_variants_client: S3Client = undefined;
    var r2c: R2Cache = undefined;
    var tc: TieredCache = undefined;
    var r2_originals_client: S3Client = undefined;
    var r2_fetcher: R2Fetcher = undefined;

    const image_cache: Cache = if (cfg.cache.enabled) blk: {
        mc = MemoryCache.init(allocator, cfg.cache.max_size_bytes);

        if (use_r2) {
            r2_variants_client = S3Client.init(allocator, cfg.r2.endpoint, cfg.r2.bucket_variants, r2_creds);
            r2c = R2Cache.init(allocator, &r2_variants_client);
            tc = TieredCache.init(mc.cache(), r2c.cache(), allocator);
            break :blk tc.cache();
        }

        break :blk mc.cache();
    } else blk: {
        nc = NoopCache.init();
        break :blk nc.cache();
    };
    defer if (cfg.cache.enabled) mc.deinit();
    defer if (use_r2 and cfg.cache.enabled) r2c.deinit();

    // 4. Create R2 origin fetcher (if using R2)
    if (use_r2) {
        r2_originals_client = S3Client.init(allocator, cfg.r2.endpoint, cfg.r2.bucket_originals, r2_creds);
        r2_fetcher = R2Fetcher.init(&r2_originals_client);
    }

    // 5. Create server
    var server = Server.init(allocator, cfg, image_cache);
    if (use_r2) {
        server.r2_fetcher = &r2_fetcher;
    }

    // 6. Bind and listen
    const address = net.Address.parseIp4(cfg.server.host, cfg.server.port) catch {
        std.log.err("Failed to parse listen address: {s}:{d}", .{ cfg.server.host, cfg.server.port });
        return error.AddressError;
    };

    var listener = address.listen(.{
        .reuse_address = true,
    }) catch {
        std.log.err("Failed to bind to {s}:{d}", .{ cfg.server.host, cfg.server.port });
        return error.BindError;
    };
    defer listener.deinit();

    // 7. Create thread pool for connection handling.
    // Explicit stack size: musl (Alpine) defaults to ~128KB which is too
    // small for the deep call stacks through HTTP client + TLS + S3.
    var pool: std.Thread.Pool = undefined;
    pool.init(.{
        .allocator = allocator,
        .n_jobs = cfg.server.max_connections,
        .stack_size = 2 * 1024 * 1024, // 2 MiB per worker
    }) catch {
        std.log.err("Failed to create thread pool", .{});
        return error.ThreadPoolError;
    };
    defer pool.deinit();

    // Wire thread pool to tiered cache for async L2 writes.
    if (use_r2 and cfg.cache.enabled) {
        tc.pool = &pool;
    }

    std.log.info("zimgx listening on {s}:{d} (workers={d})", .{ cfg.server.host, cfg.server.port, cfg.server.max_connections });

    // 8. Accept loop — queue connections to the thread pool. Workers are
    // reused across connections; when all are busy, new jobs queue internally.
    while (true) {
        const conn = listener.accept() catch {
            std.log.warn("Failed to accept connection", .{});
            continue;
        };

        // Rate limit: reject when at capacity.
        const current = @atomicLoad(u32, &server.active_connections, .monotonic);
        if (current >= cfg.server.max_connections) {
            conn.stream.close();
            std.log.warn("Connection rejected: at capacity ({d}/{d})", .{ current, cfg.server.max_connections });
            continue;
        }

        pool.spawn(handleConnection, .{ &server, conn }) catch {
            conn.stream.close();
            std.log.warn("Failed to queue connection", .{});
            continue;
        };
    }
}

fn handleConnection(server: *Server, conn: net.Server.Connection) void {
    _ = @atomicRmw(u32, &server.active_connections, .Add, 1, .monotonic);
    defer _ = @atomicRmw(u32, &server.active_connections, .Sub, 1, .monotonic);
    defer conn.stream.close();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var stream_reader = conn.stream.reader(&read_buf);
    var stream_writer = conn.stream.writer(&write_buf);

    var http_server = http.Server.init(stream_reader.interface(), &stream_writer.interface);

    // Keep-alive: handle multiple requests per connection
    while (true) {
        var request = http_server.receiveHead() catch return;

        const headers = extractHeaders(request.head_buffer);
        const route = router.resolve(request.head.target);
        var resp = server.dispatchRoute(route, headers.if_none_match, headers.accept);
        defer resp.deinit(server.allocator);
        const status = std.meta.intToEnum(http.Status, resp.status) catch .internal_server_error;

        var extra_headers_buf: [4]http.Header = undefined;
        var num_extra: usize = 0;

        extra_headers_buf[num_extra] = .{ .name = "content-type", .value = resp.content_type };
        num_extra += 1;

        if (resp.cache_control) |cc| {
            extra_headers_buf[num_extra] = .{ .name = "cache-control", .value = cc };
            num_extra += 1;
        }

        if (resp.etag) |etag| {
            extra_headers_buf[num_extra] = .{ .name = "etag", .value = etag };
            num_extra += 1;
        }

        if (resp.vary) |vary| {
            extra_headers_buf[num_extra] = .{ .name = "vary", .value = vary };
            num_extra += 1;
        }

        request.respond(resp.body, .{
            .status = status,
            .extra_headers = extra_headers_buf[0..num_extra],
        }) catch return;

        if (!request.head.keep_alive) return;
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// ---------------------------------------------------------------------------
// Test helper: create a Server with a noop or memory cache for testing
// ---------------------------------------------------------------------------

const TestContext = struct {
    server: Server,
    nc: NoopCache,
};

fn testServer() TestContext {
    var ctx = TestContext{
        .nc = NoopCache.init(),
        .server = undefined,
    };
    ctx.server = Server.init(testing.allocator, Config.defaults(), ctx.nc.cache());
    ctx.server.start_time = 1700000000; // fixed time for deterministic tests
    return ctx;
}

fn testServerWithCache(mc: *MemoryCache) Server {
    var server = Server.init(testing.allocator, Config.defaults(), mc.cache());
    server.start_time = 1700000000;
    return server;
}

// ---------------------------------------------------------------------------
// Health endpoint tests
// ---------------------------------------------------------------------------

test "health endpoint returns 200 with ok JSON" {
    var ctx = testServer();
    const resp = ctx.server.dispatchRoute(.health, null, null);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("application/json", resp.content_type);
    try testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}

test "health endpoint increments request counter" {
    var ctx = testServer();
    try testing.expectEqual(@as(u64, 0), ctx.server.stats.requests_total);
    _ = ctx.server.dispatchRoute(.health, null, null);
    try testing.expectEqual(@as(u64, 1), ctx.server.stats.requests_total);
    _ = ctx.server.dispatchRoute(.health, null, null);
    try testing.expectEqual(@as(u64, 2), ctx.server.stats.requests_total);
}

// ---------------------------------------------------------------------------
// Ready endpoint tests
// ---------------------------------------------------------------------------

test "ready endpoint returns 200 with ready JSON" {
    var ctx = testServer();
    const resp = ctx.server.dispatchRoute(.ready, null, null);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("application/json", resp.content_type);
    try testing.expectEqualStrings("{\"ready\":true}", resp.body);
}

// ---------------------------------------------------------------------------
// Metrics endpoint tests
// ---------------------------------------------------------------------------

test "metrics endpoint returns 200 with JSON stats" {
    var ctx = testServer();
    // Make a few requests to populate stats
    _ = ctx.server.dispatchRoute(.health, null, null);
    _ = ctx.server.dispatchRoute(.ready, null, null);

    const resp = ctx.server.dispatchRoute(.metrics, null, null);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("application/json", resp.content_type);

    // The body should contain JSON with requests_total = 3 (2 previous + 1 for metrics itself)
    try testing.expect(resp.body.len > 0);
    // Verify it contains the requests_total field
    try testing.expect(mem.indexOf(u8, resp.body, "\"requests_total\":3") != null);
}

// ---------------------------------------------------------------------------
// Not found tests
// ---------------------------------------------------------------------------

test "not_found route returns 404 JSON error" {
    var ctx = testServer();
    const resp = ctx.server.dispatchRoute(.not_found, null, null);
    try testing.expectEqual(@as(u16, 404), resp.status);
    try testing.expectEqualStrings("application/json", resp.content_type);
    try testing.expectEqualStrings(
        "{\"error\":{\"status\":404,\"message\":\"Not Found\"}}",
        resp.body,
    );
}

// ---------------------------------------------------------------------------
// Error response serialization tests
// ---------------------------------------------------------------------------

test "error response for bad request" {
    var ctx = testServer();
    const resp = ctx.server.buildErrorResponse(HttpError.badRequest(null));
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expectEqualStrings("application/json", resp.content_type);
    try testing.expectEqualStrings(
        "{\"error\":{\"status\":400,\"message\":\"Bad Request\"}}",
        resp.body,
    );
}

test "error response for internal server error" {
    var ctx = testServer();
    const resp = ctx.server.buildErrorResponse(HttpError.internalError(null));
    try testing.expectEqual(@as(u16, 500), resp.status);
    try testing.expectEqualStrings(
        "{\"error\":{\"status\":500,\"message\":\"Internal Server Error\"}}",
        resp.body,
    );
}

test "error response for bad gateway" {
    var ctx = testServer();
    const resp = ctx.server.buildErrorResponse(HttpError.badGateway(null));
    try testing.expectEqual(@as(u16, 502), resp.status);
    try testing.expectEqualStrings(
        "{\"error\":{\"status\":502,\"message\":\"Bad Gateway\"}}",
        resp.body,
    );
}

test "error response with detail includes detail field" {
    var ctx = testServer();
    const resp = ctx.server.buildErrorResponse(HttpError.badRequest("invalid width"));
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(mem.indexOf(u8, resp.body, "invalid width") != null);
}

// ---------------------------------------------------------------------------
// Image request: cache key construction tests
// ---------------------------------------------------------------------------

test "image request builds correct cache key" {
    // Verify the cache key computation logic via cache_mod directly
    var buf: [512]u8 = undefined;
    const key = cache_mod.computeCacheKey("photos/cat.jpg", "w=400,h=300", "webp", &buf);
    try testing.expectEqualStrings("photos/cat.jpg|w=400,h=300|webp", key);
}

test "image request cache key includes format auto when no format specified" {
    var buf: [512]u8 = undefined;
    const key = cache_mod.computeCacheKey("img.jpg", "w=100", "auto", &buf);
    try testing.expectEqualStrings("img.jpg|w=100|auto", key);
}

// ---------------------------------------------------------------------------
// 304 Not Modified tests
// ---------------------------------------------------------------------------

test "304 not modified when etag matches" {
    const data = "fake image data for etag test";
    const etag = response_mod.generateEtag(data);
    try testing.expect(response_mod.shouldReturn304(&etag, &etag));
}

test "no 304 when etag does not match" {
    const etag_a = response_mod.generateEtag("data a");
    const etag_b = response_mod.generateEtag("data b");
    try testing.expect(!response_mod.shouldReturn304(&etag_a, &etag_b));
}

test "no 304 when no If-None-Match header" {
    const etag = response_mod.generateEtag("some data");
    try testing.expect(!response_mod.shouldReturn304(null, &etag));
}

// ---------------------------------------------------------------------------
// Route dispatch integration tests
// ---------------------------------------------------------------------------

test "route dispatch for /health path" {
    const route = router.resolve("/health");
    var ctx = testServer();
    const resp = ctx.server.dispatchRoute(route, null, null);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}

test "route dispatch for /ready path" {
    const route = router.resolve("/ready");
    var ctx = testServer();
    const resp = ctx.server.dispatchRoute(route, null, null);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("{\"ready\":true}", resp.body);
}

test "route dispatch for unknown path returns not found" {
    const route = router.resolve("/");
    var ctx = testServer();
    const resp = ctx.server.dispatchRoute(route, null, null);
    try testing.expectEqual(@as(u16, 404), resp.status);
}

// ---------------------------------------------------------------------------
// Image request with invalid transforms
// ---------------------------------------------------------------------------

test "image request with invalid transform returns 400" {
    var ctx = testServer();
    const route = Route{ .image_request = .{
        .image_path = "test.jpg",
        .transform_string = "banana=42",
    } };
    const resp = ctx.server.dispatchRoute(route, null, null);
    try testing.expectEqual(@as(u16, 400), resp.status);
    try testing.expect(mem.indexOf(u8, resp.body, "invalid transform parameters") != null);
}

test "image request with out of range transform returns 422" {
    var ctx = testServer();
    const route = Route{ .image_request = .{
        .image_path = "test.jpg",
        .transform_string = "w=0",
    } };
    const resp = ctx.server.dispatchRoute(route, null, null);
    try testing.expectEqual(@as(u16, 422), resp.status);
    try testing.expect(mem.indexOf(u8, resp.body, "out of range") != null);
}

// ---------------------------------------------------------------------------
// ServerStats JSON serialization tests
// ---------------------------------------------------------------------------

test "ServerStats toJson produces valid JSON" {
    const stats = ServerStats{
        .requests_total = 42,
        .cache_hits = 10,
        .cache_misses = 32,
        .cache_entries = 5,
        .uptime_seconds = 3600,
    };
    var buf: [512]u8 = undefined;
    const json = stats.toJson(&buf);

    try testing.expect(json.len > 0);
    try testing.expect(mem.indexOf(u8, json, "\"requests_total\":42") != null);
    try testing.expect(mem.indexOf(u8, json, "\"cache_hits\":10") != null);
    try testing.expect(mem.indexOf(u8, json, "\"cache_misses\":32") != null);
    try testing.expect(mem.indexOf(u8, json, "\"cache_entries\":5") != null);
    try testing.expect(mem.indexOf(u8, json, "\"uptime_seconds\":3600") != null);
}

test "ServerStats toJson with zero values" {
    const stats = ServerStats{};
    var buf: [512]u8 = undefined;
    const json = stats.toJson(&buf);

    try testing.expect(json.len > 0);
    try testing.expect(mem.indexOf(u8, json, "\"requests_total\":0") != null);
}

// ---------------------------------------------------------------------------
// Header extraction tests
// ---------------------------------------------------------------------------

test "extractHeaders finds If-None-Match" {
    const raw = "GET /img.jpg HTTP/1.1\r\nIf-None-Match: abc123\r\nHost: localhost\r\n\r\n";
    const headers = extractHeaders(raw);
    try testing.expect(headers.if_none_match != null);
    try testing.expectEqualStrings("abc123", headers.if_none_match.?);
}

test "extractHeaders finds Accept header" {
    const raw = "GET /img.jpg HTTP/1.1\r\nAccept: image/webp,image/avif\r\nHost: localhost\r\n\r\n";
    const headers = extractHeaders(raw);
    try testing.expect(headers.accept != null);
    try testing.expectEqualStrings("image/webp,image/avif", headers.accept.?);
}

test "extractHeaders with no matching headers" {
    const raw = "GET /img.jpg HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const headers = extractHeaders(raw);
    try testing.expect(headers.if_none_match == null);
    try testing.expect(headers.accept == null);
}

test "extractHeaders case insensitive" {
    const raw = "GET /img.jpg HTTP/1.1\r\nif-none-match: etag123\r\naccept: image/webp\r\n\r\n";
    const headers = extractHeaders(raw);
    try testing.expect(headers.if_none_match != null);
    try testing.expectEqualStrings("etag123", headers.if_none_match.?);
    try testing.expect(headers.accept != null);
    try testing.expectEqualStrings("image/webp", headers.accept.?);
}

// ---------------------------------------------------------------------------
// Server init tests
// ---------------------------------------------------------------------------

test "Server init sets config and cache" {
    var nc = NoopCache.init();
    const cfg = Config.defaults();
    const server = Server.init(testing.allocator, cfg, nc.cache());
    try testing.expectEqual(@as(u16, 8080), server.config.server.port);
    try testing.expectEqual(@as(u64, 0), server.stats.requests_total);
}

test "Server init with memory cache" {
    var mc = MemoryCache.init(testing.allocator, 1024);
    defer mc.deinit();
    const cfg = Config.defaults();
    const server = Server.init(testing.allocator, cfg, mc.cache());
    try testing.expectEqual(@as(u16, 8080), server.config.server.port);
}

// ---------------------------------------------------------------------------
// Cache integration tests (with real memory cache)
// ---------------------------------------------------------------------------

test "image request cache miss increments counter" {
    var ctx = testServer();
    // An image request that will fail at fetch (no origin available in test)
    // should still increment cache_misses
    const route = Route{ .image_request = .{
        .image_path = "test.jpg",
        .transform_string = null,
    } };
    _ = ctx.server.dispatchRoute(route, null, null);
    try testing.expectEqual(@as(u64, 1), ctx.server.stats.cache_misses);
}

test "cache disabled falls back to direct response instead of 500" {
    var ctx = testServer();

    var resp = ctx.server.serveCachedOrBody(
        "k",
        null,
        "image-bytes",
        "image/jpeg",
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("image/jpeg", resp.content_type);
    try testing.expectEqualStrings("image-bytes", resp.body);
    try testing.expect(resp.cache_control != null);
    try testing.expect(resp.etag != null);
}

test "oversized memory cache entry falls back to direct response" {
    var mc = MemoryCache.init(testing.allocator, 4);
    defer mc.deinit();

    var server = Server.init(testing.allocator, Config.defaults(), mc.cache());

    const key = "oversized";
    const body = "payload larger than max cache size";

    server.image_cache.put(key, .{
        .data = body,
        .content_type = "image/webp",
        .created_at = std.time.timestamp(),
    });

    try testing.expect(server.image_cache.get(key) == null);

    var resp = server.serveCachedOrBody(
        key,
        null,
        body,
        "image/webp",
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("image/webp", resp.content_type);
    try testing.expectEqualStrings(body, resp.body);
    try testing.expect(resp.cache_control != null);
    try testing.expect(resp.etag != null);
}

// ---------------------------------------------------------------------------
// Content type negotiation integration
// ---------------------------------------------------------------------------

test "content type from format mapping" {
    try testing.expectEqualStrings("image/jpeg", response_mod.contentTypeFromFormat(.jpeg));
    try testing.expectEqualStrings("image/webp", response_mod.contentTypeFromFormat(.webp));
    try testing.expectEqualStrings("image/png", response_mod.contentTypeFromFormat(.png));
    try testing.expectEqualStrings("image/avif", response_mod.contentTypeFromFormat(.avif));
}

test "format negotiation prefers avif when supported" {
    const format = negotiate_mod.negotiateFormat("image/avif,image/webp", false, null);
    try testing.expectEqual(OutputFormat.avif, format);
}

test "format negotiation returns explicit format when set" {
    const format = negotiate_mod.negotiateFormat("image/avif", false, .jpeg);
    try testing.expectEqual(OutputFormat.jpeg, format);
}

// ---------------------------------------------------------------------------
// buildCacheControl integration
// ---------------------------------------------------------------------------

test "buildCacheControl with default TTL" {
    const cfg = Config.defaults();
    var buf: [64]u8 = undefined;
    const cc = response_mod.buildCacheControl(cfg.cache.default_ttl_seconds, true, &buf);
    try testing.expectEqualStrings("public, max-age=3600", cc);
}

// ---------------------------------------------------------------------------
// ETag generation integration
// ---------------------------------------------------------------------------

test "etag generation is deterministic" {
    const data = "test image bytes";
    const etag1 = response_mod.generateEtag(data);
    const etag2 = response_mod.generateEtag(data);
    try testing.expectEqualStrings(&etag1, &etag2);
}

test "etag generation differs for different data" {
    const etag_a = response_mod.generateEtag("image a");
    const etag_b = response_mod.generateEtag("image b");
    try testing.expect(!mem.eql(u8, &etag_a, &etag_b));
}

// ---------------------------------------------------------------------------
// Path prefix stripping tests
// ---------------------------------------------------------------------------

test "stripPathPrefix strips matching prefix" {
    var ctx = testServer();
    ctx.server.config.origin.path_prefix = "abc123";
    try testing.expectEqualStrings("photo-id", ctx.server.stripPathPrefix("abc123/photo-id"));
}

test "stripPathPrefix returns original when no prefix configured" {
    var ctx = testServer();
    try testing.expectEqualStrings("abc123/photo-id", ctx.server.stripPathPrefix("abc123/photo-id"));
}

test "stripPathPrefix returns original when prefix does not match" {
    var ctx = testServer();
    ctx.server.config.origin.path_prefix = "xyz";
    try testing.expectEqualStrings("abc123/photo-id", ctx.server.stripPathPrefix("abc123/photo-id"));
}

test "stripPathPrefix requires slash after prefix" {
    var ctx = testServer();
    ctx.server.config.origin.path_prefix = "abc";
    try testing.expectEqualStrings("abc123/photo-id", ctx.server.stripPathPrefix("abc123/photo-id"));
}

test "stripPathPrefix handles nested path after prefix" {
    var ctx = testServer();
    ctx.server.config.origin.path_prefix = "account-id";
    try testing.expectEqualStrings("folder/image.jpg", ctx.server.stripPathPrefix("account-id/folder/image.jpg"));
}
