// Configuration for the zimgx image proxy.
//
// Provides a `Config` struct with sensible defaults, environment-variable
// loading (`ZIMGX_` prefix convention), and validation.

const std = @import("std");

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const ConfigError = error{
    InvalidPort,
    InvalidTimeout,
    InvalidDimension,
    InvalidQuality,
    InvalidUrl,
    InvalidValue,
    MissingR2Config,
};

// ---------------------------------------------------------------------------
// Config struct with nested sub-structs
// ---------------------------------------------------------------------------

pub const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "0.0.0.0",
    request_timeout_ms: u32 = 30_000,
    max_request_size: usize = 50 * 1024 * 1024,
    max_connections: u16 = 64,
};

pub const OriginType = enum {
    http,
    r2,
};

pub const OriginConfig = struct {
    base_url: []const u8 = "http://localhost:9000",
    timeout_ms: u32 = 10_000,
    max_retries: u8 = 2,
    origin_type: OriginType = .http,
    path_prefix: []const u8 = "",
};

pub const R2Config = struct {
    endpoint: []const u8 = "",
    access_key_id: []const u8 = "",
    secret_access_key: []const u8 = "",
    bucket_originals: []const u8 = "originals",
    bucket_variants: []const u8 = "variants",
};

pub const TransformConfig = struct {
    max_width: u32 = 8192,
    max_height: u32 = 8192,
    default_quality: u8 = 80,
    max_pixels: u64 = 71_000_000,
    strip_metadata: bool = true,
    max_frames: u32 = 100,
    max_animated_pixels: u64 = 50_000_000,
};

pub const CacheConfig = struct {
    enabled: bool = true,
    max_size_bytes: usize = 512 * 1024 * 1024,
    default_ttl_seconds: u32 = 3600,
};

pub const Config = struct {
    server: ServerConfig = .{},
    origin: OriginConfig = .{},
    transform: TransformConfig = .{},
    cache: CacheConfig = .{},
    r2: R2Config = .{},

    // -----------------------------------------------------------------
    // defaults
    // -----------------------------------------------------------------

    /// Returns a Config with all default values.
    pub fn defaults() Config {
        return .{};
    }

    // -----------------------------------------------------------------
    // loadFromEnv
    // -----------------------------------------------------------------

    /// Load configuration from environment variables. Missing variables
    /// keep their default values. Invalid values (e.g. non-numeric string
    /// for a port) return `ConfigError.InvalidValue`.
    ///
    /// The allocator is accepted for API-forward-compatibility (e.g.
    /// future string duplication) but is currently unused for the
    /// default-string-literal path.
    pub fn loadFromEnv(_: std.mem.Allocator) ConfigError!Config {
        var cfg = Config.defaults();

        // -- server --
        if (getEnvSlice("ZIMGX_SERVER_PORT")) |v| {
            cfg.server.port = parseNum(u16, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_SERVER_HOST")) |v| {
            cfg.server.host = v;
        }
        if (getEnvSlice("ZIMGX_SERVER_REQUEST_TIMEOUT_MS")) |v| {
            cfg.server.request_timeout_ms = parseNum(u32, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_SERVER_MAX_REQUEST_SIZE")) |v| {
            cfg.server.max_request_size = parseNum(usize, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_SERVER_MAX_CONNECTIONS")) |v| {
            cfg.server.max_connections = parseNum(u16, v) orelse return ConfigError.InvalidValue;
        }

        // -- origin --
        if (getEnvSlice("ZIMGX_ORIGIN_BASE_URL")) |v| {
            cfg.origin.base_url = v;
        }
        if (getEnvSlice("ZIMGX_ORIGIN_TIMEOUT_MS")) |v| {
            cfg.origin.timeout_ms = parseNum(u32, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_ORIGIN_MAX_RETRIES")) |v| {
            cfg.origin.max_retries = parseNum(u8, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_ORIGIN_PATH_PREFIX")) |v| {
            cfg.origin.path_prefix = v;
        }

        // -- transform --
        if (getEnvSlice("ZIMGX_TRANSFORM_MAX_WIDTH")) |v| {
            cfg.transform.max_width = parseNum(u32, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_TRANSFORM_MAX_HEIGHT")) |v| {
            cfg.transform.max_height = parseNum(u32, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_TRANSFORM_DEFAULT_QUALITY")) |v| {
            cfg.transform.default_quality = parseNum(u8, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_TRANSFORM_MAX_PIXELS")) |v| {
            cfg.transform.max_pixels = parseNum(u64, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_TRANSFORM_STRIP_METADATA")) |v| {
            cfg.transform.strip_metadata = parseBool(v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_TRANSFORM_MAX_FRAMES")) |v| {
            cfg.transform.max_frames = parseNum(u32, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_TRANSFORM_MAX_ANIMATED_PIXELS")) |v| {
            cfg.transform.max_animated_pixels = parseNum(u64, v) orelse return ConfigError.InvalidValue;
        }

        // -- cache --
        if (getEnvSlice("ZIMGX_CACHE_ENABLED")) |v| {
            cfg.cache.enabled = parseBool(v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_CACHE_MAX_SIZE_BYTES")) |v| {
            cfg.cache.max_size_bytes = parseNum(usize, v) orelse return ConfigError.InvalidValue;
        }
        if (getEnvSlice("ZIMGX_CACHE_DEFAULT_TTL_SECONDS")) |v| {
            cfg.cache.default_ttl_seconds = parseNum(u32, v) orelse return ConfigError.InvalidValue;
        }

        // -- origin type --
        if (getEnvSlice("ZIMGX_ORIGIN_TYPE")) |v| {
            if (std.mem.eql(u8, v, "r2")) {
                cfg.origin.origin_type = .r2;
            } else if (std.mem.eql(u8, v, "http")) {
                cfg.origin.origin_type = .http;
            } else {
                return ConfigError.InvalidValue;
            }
        }

        // -- R2 --
        if (getEnvSlice("ZIMGX_R2_ENDPOINT")) |v| {
            cfg.r2.endpoint = v;
        }
        if (getEnvSlice("ZIMGX_R2_ACCESS_KEY_ID")) |v| {
            cfg.r2.access_key_id = v;
        }
        if (getEnvSlice("ZIMGX_R2_SECRET_ACCESS_KEY")) |v| {
            cfg.r2.secret_access_key = v;
        }
        if (getEnvSlice("ZIMGX_R2_BUCKET_ORIGINALS")) |v| {
            cfg.r2.bucket_originals = v;
        }
        if (getEnvSlice("ZIMGX_R2_BUCKET_VARIANTS")) |v| {
            cfg.r2.bucket_variants = v;
        }

        return cfg;
    }

    // -----------------------------------------------------------------
    // validate
    // -----------------------------------------------------------------

    /// Validates the configuration, returning a `ConfigError` on the
    /// first invalid field encountered.
    pub fn validate(self: Config) ConfigError!void {
        // Port must be > 0
        if (self.server.port == 0) return ConfigError.InvalidPort;

        // Timeouts must be > 0
        if (self.server.request_timeout_ms == 0) return ConfigError.InvalidTimeout;
        if (self.origin.timeout_ms == 0) return ConfigError.InvalidTimeout;

        // Dimensions must be >= 1
        if (self.transform.max_width < 1) return ConfigError.InvalidDimension;
        if (self.transform.max_height < 1) return ConfigError.InvalidDimension;

        // Quality must be 1-100
        if (self.transform.default_quality < 1 or self.transform.default_quality > 100) {
            return ConfigError.InvalidQuality;
        }

        // base_url must not be empty (when using HTTP origin)
        if (self.origin.origin_type == .http and self.origin.base_url.len == 0) return ConfigError.InvalidUrl;

        // When origin_type is .r2, R2 fields must be non-empty
        if (self.origin.origin_type == .r2) {
            if (self.r2.endpoint.len == 0) return ConfigError.MissingR2Config;
            if (self.r2.access_key_id.len == 0) return ConfigError.MissingR2Config;
            if (self.r2.secret_access_key.len == 0) return ConfigError.MissingR2Config;
            if (self.r2.bucket_originals.len == 0) return ConfigError.MissingR2Config;
            if (self.r2.bucket_variants.len == 0) return ConfigError.MissingR2Config;
        }
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    /// Retrieve an environment variable as a Zig slice, or null if unset.
    fn getEnvSlice(name: []const u8) ?[]const u8 {
        const raw: [:0]const u8 = std.posix.getenv(name) orelse return null;
        return raw;
    }

    /// Parse a numeric type from a string slice, returning null on failure.
    fn parseNum(comptime T: type, s: []const u8) ?T {
        return std.fmt.parseInt(T, s, 10) catch null;
    }

    /// Parse a boolean from a string slice ("true"/"1" -> true,
    /// "false"/"0" -> false, anything else -> null).
    fn parseBool(s: []const u8) ?bool {
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return false;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "defaults returns expected values" {
    const cfg = Config.defaults();

    // server
    try std.testing.expectEqual(@as(u16, 8080), cfg.server.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.server.host);
    try std.testing.expectEqual(@as(u32, 30_000), cfg.server.request_timeout_ms);
    try std.testing.expectEqual(@as(usize, 50 * 1024 * 1024), cfg.server.max_request_size);
    try std.testing.expectEqual(@as(u16, 64), cfg.server.max_connections);

    // origin
    try std.testing.expectEqualStrings("http://localhost:9000", cfg.origin.base_url);
    try std.testing.expectEqual(@as(u32, 10_000), cfg.origin.timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), cfg.origin.max_retries);

    // transform
    try std.testing.expectEqual(@as(u32, 8192), cfg.transform.max_width);
    try std.testing.expectEqual(@as(u32, 8192), cfg.transform.max_height);
    try std.testing.expectEqual(@as(u8, 80), cfg.transform.default_quality);
    try std.testing.expectEqual(@as(u64, 71_000_000), cfg.transform.max_pixels);
    try std.testing.expect(cfg.transform.strip_metadata);

    // cache
    try std.testing.expect(cfg.cache.enabled);
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 1024), cfg.cache.max_size_bytes);
    try std.testing.expectEqual(@as(u32, 3600), cfg.cache.default_ttl_seconds);
}

test "validate accepts default config" {
    const cfg = Config.defaults();
    try cfg.validate();
}

test "validate rejects port 0" {
    var cfg = Config.defaults();
    cfg.server.port = 0;
    try std.testing.expectError(ConfigError.InvalidPort, cfg.validate());
}

test "validate rejects empty base_url" {
    var cfg = Config.defaults();
    cfg.origin.base_url = "";
    try std.testing.expectError(ConfigError.InvalidUrl, cfg.validate());
}

test "validate rejects quality 0" {
    var cfg = Config.defaults();
    cfg.transform.default_quality = 0;
    try std.testing.expectError(ConfigError.InvalidQuality, cfg.validate());
}

test "validate rejects quality 101" {
    var cfg = Config.defaults();
    cfg.transform.default_quality = 101;
    try std.testing.expectError(ConfigError.InvalidQuality, cfg.validate());
}

test "validate accepts quality at boundaries" {
    var cfg = Config.defaults();

    cfg.transform.default_quality = 1;
    try cfg.validate();

    cfg.transform.default_quality = 100;
    try cfg.validate();
}

test "validate rejects zero request_timeout_ms" {
    var cfg = Config.defaults();
    cfg.server.request_timeout_ms = 0;
    try std.testing.expectError(ConfigError.InvalidTimeout, cfg.validate());
}

test "validate rejects zero origin timeout_ms" {
    var cfg = Config.defaults();
    cfg.origin.timeout_ms = 0;
    try std.testing.expectError(ConfigError.InvalidTimeout, cfg.validate());
}

test "validate rejects zero max_width" {
    var cfg = Config.defaults();
    cfg.transform.max_width = 0;
    try std.testing.expectError(ConfigError.InvalidDimension, cfg.validate());
}

test "validate rejects zero max_height" {
    var cfg = Config.defaults();
    cfg.transform.max_height = 0;
    try std.testing.expectError(ConfigError.InvalidDimension, cfg.validate());
}

test "loadFromEnv with no env vars returns defaults" {
    // When none of the ZIMGX_* environment variables are set the
    // result must equal a freshly-constructed default config.
    const cfg = try Config.loadFromEnv(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 8080), cfg.server.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.server.host);
    try std.testing.expectEqual(@as(u32, 30_000), cfg.server.request_timeout_ms);
    try std.testing.expectEqualStrings("http://localhost:9000", cfg.origin.base_url);
    try std.testing.expectEqual(@as(u32, 10_000), cfg.origin.timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), cfg.origin.max_retries);
    try std.testing.expectEqual(@as(u32, 8192), cfg.transform.max_width);
    try std.testing.expectEqual(@as(u8, 80), cfg.transform.default_quality);
    try std.testing.expect(cfg.transform.strip_metadata);
    try std.testing.expect(cfg.cache.enabled);
    try std.testing.expectEqual(@as(u32, 3600), cfg.cache.default_ttl_seconds);
}

test "parseBool helper" {
    try std.testing.expectEqual(true, Config.parseBool("true").?);
    try std.testing.expectEqual(true, Config.parseBool("1").?);
    try std.testing.expectEqual(false, Config.parseBool("false").?);
    try std.testing.expectEqual(false, Config.parseBool("0").?);
    try std.testing.expectEqual(@as(?bool, null), Config.parseBool("yes"));
    try std.testing.expectEqual(@as(?bool, null), Config.parseBool(""));
}

test "parseNum helper" {
    try std.testing.expectEqual(@as(u16, 3000), Config.parseNum(u16, "3000").?);
    try std.testing.expectEqual(@as(u32, 0), Config.parseNum(u32, "0").?);
    try std.testing.expectEqual(@as(?u16, null), Config.parseNum(u16, "not_a_number"));
    try std.testing.expectEqual(@as(?u16, null), Config.parseNum(u16, ""));
    // Overflow: 70000 does not fit in u16
    try std.testing.expectEqual(@as(?u16, null), Config.parseNum(u16, "70000"));
}
