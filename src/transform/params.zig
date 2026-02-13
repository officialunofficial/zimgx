// Transform parameter parsing
//
// Defines output-format enum, transform parameter structs, and query-string
// parameter extraction used by the image transformation pipeline.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;

/// Errors returned when parsing or validating transform parameters.
pub const ParseError = error{
    InvalidWidth,
    InvalidHeight,
    InvalidFormat,
    InvalidQuality,
    InvalidFitMode,
    InvalidGravity,
    InvalidSharpen,
    InvalidBlur,
    InvalidDpr,
    InvalidRotation,
    InvalidFlip,
    InvalidBrightness,
    InvalidContrast,
    InvalidSaturation,
    InvalidGamma,
    InvalidBackground,
    InvalidMetadata,
    InvalidTrim,
    InvalidAnim,
    InvalidFrame,
    InvalidParameter,
    EmptyValue,
};

/// Supported output image formats.
/// `.auto` means the format should be negotiated from the client's
/// Accept header (see negotiate.zig).
pub const OutputFormat = enum {
    auto,
    jpeg,
    png,
    webp,
    avif,
    gif,

    /// Return the MIME content-type string for this format.
    /// `.auto` has no fixed content-type -- callers must resolve it
    /// to a concrete format first via negotiateFormat().
    pub fn contentType(self: OutputFormat) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .webp => "image/webp",
            .avif => "image/avif",
            .gif => "image/gif",
            .auto => "application/octet-stream",
        };
    }

    /// File extension (without leading dot) for the format.
    pub fn extension(self: OutputFormat) []const u8 {
        return switch (self) {
            .jpeg => "jpg",
            .png => "png",
            .webp => "webp",
            .avif => "avif",
            .gif => "gif",
            .auto => "",
        };
    }

    /// Parse a format name string into an OutputFormat enum value.
    pub fn fromString(s: []const u8) ParseError!OutputFormat {
        if (mem.eql(u8, s, "jpeg") or mem.eql(u8, s, "jpg")) return .jpeg;
        if (mem.eql(u8, s, "png")) return .png;
        if (mem.eql(u8, s, "webp")) return .webp;
        if (mem.eql(u8, s, "avif")) return .avif;
        if (mem.eql(u8, s, "gif")) return .gif;
        if (mem.eql(u8, s, "auto")) return .auto;
        return ParseError.InvalidFormat;
    }

    /// Return the canonical string name for this format.
    pub fn toString(self: OutputFormat) []const u8 {
        return switch (self) {
            .jpeg => "jpeg",
            .png => "png",
            .webp => "webp",
            .avif => "avif",
            .gif => "gif",
            .auto => "auto",
        };
    }

    /// Whether this format supports animated output (multiple frames).
    pub fn supportsAnimation(self: OutputFormat) bool {
        return self == .gif or self == .webp;
    }
};

/// Rotation angle (multiples of 90 degrees).
pub const Rotation = enum {
    @"0",
    @"90",
    @"180",
    @"270",

    pub fn fromString(s: []const u8) ParseError!Rotation {
        if (mem.eql(u8, s, "0")) return .@"0";
        if (mem.eql(u8, s, "90")) return .@"90";
        if (mem.eql(u8, s, "180")) return .@"180";
        if (mem.eql(u8, s, "270")) return .@"270";
        return ParseError.InvalidRotation;
    }

    pub fn toString(self: Rotation) []const u8 {
        return switch (self) {
            .@"0" => "0",
            .@"90" => "90",
            .@"180" => "180",
            .@"270" => "270",
        };
    }
};

/// Flip/mirror direction.
pub const FlipMode = enum {
    h,
    v,
    hv,

    pub fn fromString(s: []const u8) ParseError!FlipMode {
        if (mem.eql(u8, s, "h")) return .h;
        if (mem.eql(u8, s, "v")) return .v;
        if (mem.eql(u8, s, "hv") or mem.eql(u8, s, "vh")) return .hv;
        return ParseError.InvalidFlip;
    }

    pub fn toString(self: FlipMode) []const u8 {
        return switch (self) {
            .h => "h",
            .v => "v",
            .hv => "hv",
        };
    }
};

/// Metadata preservation mode for encoded output.
pub const MetadataMode = enum {
    strip,
    keep,
    copyright,

    pub fn fromString(s: []const u8) ParseError!MetadataMode {
        if (mem.eql(u8, s, "strip") or mem.eql(u8, s, "none")) return .strip;
        if (mem.eql(u8, s, "keep") or mem.eql(u8, s, "all")) return .keep;
        if (mem.eql(u8, s, "copyright")) return .copyright;
        return ParseError.InvalidMetadata;
    }

    pub fn toString(self: MetadataMode) []const u8 {
        return switch (self) {
            .strip => "strip",
            .keep => "keep",
            .copyright => "copyright",
        };
    }
};

/// Animation mode controlling how animated images are handled.
pub const AnimMode = enum {
    /// Preserve animation when input is animated AND output format supports it.
    auto,
    /// Always strip animation, serve first frame only.
    static,
    /// Request animated output; degrade to static if format can't animate.
    animate,

    pub fn fromString(s: []const u8) ParseError!AnimMode {
        if (mem.eql(u8, s, "auto") or mem.eql(u8, s, "true")) return .auto;
        if (mem.eql(u8, s, "static") or mem.eql(u8, s, "false")) return .static;
        if (mem.eql(u8, s, "animate")) return .animate;
        return ParseError.InvalidAnim;
    }

    pub fn toString(self: AnimMode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .static => "static",
            .animate => "animate",
        };
    }
};

/// How the image should be resized to fit the target dimensions.
pub const FitMode = enum {
    contain,
    cover,
    fill,
    inside,
    outside,
    pad,

    pub fn fromString(s: []const u8) ParseError!FitMode {
        if (mem.eql(u8, s, "contain")) return .contain;
        if (mem.eql(u8, s, "cover")) return .cover;
        if (mem.eql(u8, s, "fill")) return .fill;
        if (mem.eql(u8, s, "inside")) return .inside;
        if (mem.eql(u8, s, "outside")) return .outside;
        if (mem.eql(u8, s, "pad")) return .pad;
        return ParseError.InvalidFitMode;
    }

    pub fn toString(self: FitMode) []const u8 {
        return switch (self) {
            .contain => "contain",
            .cover => "cover",
            .fill => "fill",
            .inside => "inside",
            .outside => "outside",
            .pad => "pad",
        };
    }
};

/// Where to anchor the crop when fit mode requires cropping.
pub const Gravity = enum {
    center,
    north,
    south,
    east,
    west,
    northeast,
    northwest,
    southeast,
    southwest,
    smart,
    attention,

    pub fn fromString(s: []const u8) ParseError!Gravity {
        if (mem.eql(u8, s, "center") or mem.eql(u8, s, "centre")) return .center;
        if (mem.eql(u8, s, "north") or mem.eql(u8, s, "n")) return .north;
        if (mem.eql(u8, s, "south") or mem.eql(u8, s, "s")) return .south;
        if (mem.eql(u8, s, "east") or mem.eql(u8, s, "e")) return .east;
        if (mem.eql(u8, s, "west") or mem.eql(u8, s, "w")) return .west;
        if (mem.eql(u8, s, "northeast") or mem.eql(u8, s, "ne")) return .northeast;
        if (mem.eql(u8, s, "northwest") or mem.eql(u8, s, "nw")) return .northwest;
        if (mem.eql(u8, s, "southeast") or mem.eql(u8, s, "se")) return .southeast;
        if (mem.eql(u8, s, "southwest") or mem.eql(u8, s, "sw")) return .southwest;
        if (mem.eql(u8, s, "smart")) return .smart;
        if (mem.eql(u8, s, "attention") or mem.eql(u8, s, "att")) return .attention;
        return ParseError.InvalidGravity;
    }

    pub fn toString(self: Gravity) []const u8 {
        return switch (self) {
            .center => "center",
            .north => "north",
            .south => "south",
            .east => "east",
            .west => "west",
            .northeast => "northeast",
            .northwest => "northwest",
            .southeast => "southeast",
            .southwest => "southwest",
            .smart => "smart",
            .attention => "attention",
        };
    }
};

/// Parameters controlling image transformation.
pub const TransformParams = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    quality: u8 = 80,
    format: ?OutputFormat = null,
    fit: FitMode = .contain,
    gravity: Gravity = .center,
    sharpen: ?f32 = null,
    blur: ?f32 = null,
    dpr: f32 = 1.0,
    rotate: ?Rotation = null,
    flip: ?FlipMode = null,
    brightness: ?f32 = null,
    contrast: ?f32 = null,
    saturation: ?f32 = null,
    gamma: ?f32 = null,
    background: ?[3]u8 = null,
    metadata: MetadataMode = .strip,
    trim: ?f32 = null,
    anim: AnimMode = .auto,
    frame: ?u32 = null,

    /// Returns the effective width after applying the DPR multiplier.
    pub fn effectiveWidth(self: TransformParams) ?u32 {
        const w = self.width orelse return null;
        const result = @as(f32, @floatFromInt(w)) * self.dpr;
        const clamped = @min(result, 8192.0);
        return @intFromFloat(clamped);
    }

    /// Returns the effective height after applying the DPR multiplier.
    pub fn effectiveHeight(self: TransformParams) ?u32 {
        const h = self.height orelse return null;
        const result = @as(f32, @floatFromInt(h)) * self.dpr;
        const clamped = @min(result, 8192.0);
        return @intFromFloat(clamped);
    }

    /// Validate that all parameter values are within acceptable bounds.
    pub fn validate(self: TransformParams) ParseError!void {
        if (self.width) |w| {
            if (w < 1 or w > 8192) return ParseError.InvalidWidth;
        }
        if (self.height) |h| {
            if (h < 1 or h > 8192) return ParseError.InvalidHeight;
        }
        if (self.quality < 1 or self.quality > 100) return ParseError.InvalidQuality;
        if (self.dpr < 1.0 or self.dpr > 5.0) return ParseError.InvalidDpr;
        if (self.sharpen) |sv| {
            if (sv < 0.0 or sv > 10.0) return ParseError.InvalidSharpen;
        }
        if (self.blur) |bv| {
            if (bv < 0.1 or bv > 250.0) return ParseError.InvalidBlur;
        }
        if (self.brightness) |v| {
            if (v < 0.0 or v > 2.0) return ParseError.InvalidBrightness;
        }
        if (self.contrast) |v| {
            if (v < 0.0 or v > 2.0) return ParseError.InvalidContrast;
        }
        if (self.saturation) |v| {
            if (v < 0.0 or v > 2.0) return ParseError.InvalidSaturation;
        }
        if (self.gamma) |v| {
            if (v < 0.1 or v > 10.0) return ParseError.InvalidGamma;
        }
        if (self.trim) |v| {
            if (v < 1.0 or v > 100.0) return ParseError.InvalidTrim;
        }
        if (self.frame) |f| {
            if (f > 999) return ParseError.InvalidFrame;
        }
    }

    /// Serialize parameters into a deterministic cache key string.
    /// Fields are written in a fixed canonical order. Optional fields that
    /// are null are omitted. The resulting slice borrows from `buf`.
    pub fn toCacheKey(self: TransformParams, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        self.writeCacheKey(writer) catch return buf[0..0];
        return stream.getWritten();
    }

    fn writeCacheKey(self: TransformParams, writer: anytype) !void {
        var sep = SeparatorWriter(@TypeOf(writer)){ .writer = writer };

        // Deterministic order: always-present fields first, then optionals.
        if (self.width) |w| try sep.field("w={d}", .{w});
        if (self.height) |h| try sep.field("h={d}", .{h});
        try sep.field("q={d}", .{self.quality});
        if (self.format) |f| try sep.field("f={s}", .{f.toString()});
        try sep.field("fit={s}", .{self.fit.toString()});
        try sep.field("g={s}", .{self.gravity.toString()});
        if (self.sharpen) |v| try sep.field("sharpen={d:.2}", .{v});
        if (self.blur) |v| try sep.field("blur={d:.2}", .{v});
        try sep.field("dpr={d:.1}", .{self.dpr});
        if (self.rotate) |r| try sep.field("rotate={s}", .{r.toString()});
        if (self.flip) |fl| try sep.field("flip={s}", .{fl.toString()});
        if (self.brightness) |v| try sep.field("brightness={d:.2}", .{v});
        if (self.contrast) |v| try sep.field("contrast={d:.2}", .{v});
        if (self.saturation) |v| try sep.field("saturation={d:.2}", .{v});
        if (self.gamma) |v| try sep.field("gamma={d:.2}", .{v});
        if (self.background) |bg| try sep.field("bg={X:0>2}{X:0>2}{X:0>2}", .{ bg[0], bg[1], bg[2] });
        if (self.metadata != .strip) try sep.field("metadata={s}", .{self.metadata.toString()});
        if (self.trim) |v| try sep.field("trim={d:.1}", .{v});
        if (self.anim != .auto) try sep.field("anim={s}", .{self.anim.toString()});
        if (self.frame) |f| try sep.field("frame={d}", .{f});
    }
};

/// Writes a comma separator before each entry except the first.
fn SeparatorWriter(Writer: type) type {
    return struct {
        writer: Writer,
        started: bool = false,

        fn field(self: *@This(), comptime format: []const u8, args: anytype) !void {
            if (self.started) try self.writer.writeByte(',');
            try self.writer.print(format, args);
            self.started = true;
        }
    };
}

/// Parse a comma-separated key=value string into TransformParams.
/// An empty string returns default parameters.
pub fn parse(input: []const u8) ParseError!TransformParams {
    var params = TransformParams{};

    if (input.len == 0) return params;

    var iter = mem.splitScalar(u8, input, ',');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_pos = mem.indexOfScalar(u8, pair, '=') orelse return ParseError.InvalidParameter;
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];

        if (value.len == 0) return ParseError.EmptyValue;

        if (mem.eql(u8, key, "w") or mem.eql(u8, key, "width")) {
            params.width = parseU32(value) orelse return ParseError.InvalidWidth;
        } else if (mem.eql(u8, key, "h") or mem.eql(u8, key, "height")) {
            params.height = parseU32(value) orelse return ParseError.InvalidHeight;
        } else if (mem.eql(u8, key, "q") or mem.eql(u8, key, "quality")) {
            const q = parseU32(value) orelse return ParseError.InvalidQuality;
            if (q > 255) return ParseError.InvalidQuality;
            params.quality = @intCast(q);
        } else if (mem.eql(u8, key, "format") or mem.eql(u8, key, "fmt") or mem.eql(u8, key, "f")) {
            params.format = try OutputFormat.fromString(value);
        } else if (mem.eql(u8, key, "fit")) {
            params.fit = try FitMode.fromString(value);
        } else if (mem.eql(u8, key, "gravity") or mem.eql(u8, key, "g")) {
            params.gravity = try Gravity.fromString(value);
        } else if (mem.eql(u8, key, "sharpen")) {
            params.sharpen = parseF32(value) orelse return ParseError.InvalidSharpen;
        } else if (mem.eql(u8, key, "blur")) {
            params.blur = parseF32(value) orelse return ParseError.InvalidBlur;
        } else if (mem.eql(u8, key, "dpr")) {
            params.dpr = parseF32(value) orelse return ParseError.InvalidDpr;
        } else if (mem.eql(u8, key, "rotate")) {
            params.rotate = try Rotation.fromString(value);
        } else if (mem.eql(u8, key, "flip")) {
            params.flip = try FlipMode.fromString(value);
        } else if (mem.eql(u8, key, "brightness")) {
            params.brightness = parseF32(value) orelse return ParseError.InvalidBrightness;
        } else if (mem.eql(u8, key, "contrast")) {
            params.contrast = parseF32(value) orelse return ParseError.InvalidContrast;
        } else if (mem.eql(u8, key, "saturation")) {
            params.saturation = parseF32(value) orelse return ParseError.InvalidSaturation;
        } else if (mem.eql(u8, key, "gamma")) {
            params.gamma = parseF32(value) orelse return ParseError.InvalidGamma;
        } else if (mem.eql(u8, key, "bg") or mem.eql(u8, key, "background")) {
            params.background = parseHexColor(value) orelse return ParseError.InvalidBackground;
        } else if (mem.eql(u8, key, "metadata")) {
            params.metadata = try MetadataMode.fromString(value);
        } else if (mem.eql(u8, key, "trim")) {
            params.trim = parseF32(value) orelse return ParseError.InvalidTrim;
        } else if (mem.eql(u8, key, "anim")) {
            params.anim = try AnimMode.fromString(value);
        } else if (mem.eql(u8, key, "frame")) {
            params.frame = parseU32(value) orelse return ParseError.InvalidFrame;
        } else {
            return ParseError.InvalidParameter;
        }
    }

    return params;
}

fn parseU32(s: []const u8) ?u32 {
    return fmt.parseInt(u32, s, 10) catch null;
}

fn parseF32(s: []const u8) ?f32 {
    return fmt.parseFloat(f32, s) catch null;
}

fn parseHexColor(s: []const u8) ?[3]u8 {
    if (s.len != 6) return null;
    const r = fmt.parseInt(u8, s[0..2], 16) catch return null;
    const g = fmt.parseInt(u8, s[2..4], 16) catch return null;
    const b = fmt.parseInt(u8, s[4..6], 16) catch return null;
    return .{ r, g, b };
}

// ===========================================================================
// Tests
// ===========================================================================

test "OutputFormat contentType" {
    try testing.expectEqualStrings("image/jpeg", OutputFormat.jpeg.contentType());
    try testing.expectEqualStrings("image/png", OutputFormat.png.contentType());
    try testing.expectEqualStrings("image/webp", OutputFormat.webp.contentType());
    try testing.expectEqualStrings("image/avif", OutputFormat.avif.contentType());
}

test "OutputFormat extension" {
    try testing.expectEqualStrings("jpg", OutputFormat.jpeg.extension());
    try testing.expectEqualStrings("webp", OutputFormat.webp.extension());
}

test "parse empty string returns default params" {
    const params = try parse("");
    try testing.expectEqual(@as(?u32, null), params.width);
    try testing.expectEqual(@as(?u32, null), params.height);
    try testing.expectEqual(@as(u8, 80), params.quality);
    try testing.expectEqual(@as(?OutputFormat, null), params.format);
    try testing.expectEqual(FitMode.contain, params.fit);
    try testing.expectEqual(Gravity.center, params.gravity);
    try testing.expectEqual(@as(?f32, null), params.sharpen);
    try testing.expectEqual(@as(?f32, null), params.blur);
    try testing.expectEqual(@as(f32, 1.0), params.dpr);
}

test "parse width only" {
    const params = try parse("w=400");
    try testing.expectEqual(@as(?u32, 400), params.width);
    try testing.expectEqual(@as(?u32, null), params.height);
    try testing.expectEqual(@as(u8, 80), params.quality);
}

test "parse multiple params" {
    const params = try parse("w=400,h=300,format=webp,q=85");
    try testing.expectEqual(@as(?u32, 400), params.width);
    try testing.expectEqual(@as(?u32, 300), params.height);
    try testing.expectEqual(OutputFormat.webp, params.format.?);
    try testing.expectEqual(@as(u8, 85), params.quality);
}

test "parse all fit modes" {
    const modes = [_]struct { str: []const u8, expected: FitMode }{
        .{ .str = "contain", .expected = .contain },
        .{ .str = "cover", .expected = .cover },
        .{ .str = "fill", .expected = .fill },
        .{ .str = "inside", .expected = .inside },
        .{ .str = "outside", .expected = .outside },
        .{ .str = "pad", .expected = .pad },
    };
    for (modes) |m| {
        var buf: [64]u8 = undefined;
        const input = fmt.bufPrint(&buf, "fit={s}", .{m.str}) catch unreachable;
        const params = try parse(input);
        try testing.expectEqual(m.expected, params.fit);
    }
}

test "parse all gravity values" {
    const gravities = [_]struct { str: []const u8, expected: Gravity }{
        .{ .str = "center", .expected = .center },
        .{ .str = "north", .expected = .north },
        .{ .str = "south", .expected = .south },
        .{ .str = "east", .expected = .east },
        .{ .str = "west", .expected = .west },
        .{ .str = "northeast", .expected = .northeast },
        .{ .str = "northwest", .expected = .northwest },
        .{ .str = "southeast", .expected = .southeast },
        .{ .str = "southwest", .expected = .southwest },
        .{ .str = "smart", .expected = .smart },
        .{ .str = "attention", .expected = .attention },
    };
    for (gravities) |g| {
        var buf: [64]u8 = undefined;
        const input = fmt.bufPrint(&buf, "g={s}", .{g.str}) catch unreachable;
        const params = try parse(input);
        try testing.expectEqual(g.expected, params.gravity);
    }
}

test "parse format aliases" {
    {
        const params = try parse("format=png");
        try testing.expectEqual(OutputFormat.png, params.format.?);
    }
    {
        const params = try parse("fmt=jpeg");
        try testing.expectEqual(OutputFormat.jpeg, params.format.?);
    }
    {
        const params = try parse("f=avif");
        try testing.expectEqual(OutputFormat.avif, params.format.?);
    }
}

test "validate width 0 returns error" {
    var params = TransformParams{};
    params.width = 0;
    try testing.expectError(ParseError.InvalidWidth, params.validate());
}

test "validate width 9000 returns error" {
    var params = TransformParams{};
    params.width = 9000;
    try testing.expectError(ParseError.InvalidWidth, params.validate());
}

test "validate quality 0 returns error" {
    var params = TransformParams{};
    params.quality = 0;
    try testing.expectError(ParseError.InvalidQuality, params.validate());
}

test "validate quality 101 returns error" {
    var params = TransformParams{};
    params.quality = 101;
    try testing.expectError(ParseError.InvalidQuality, params.validate());
}

test "invalid key returns error" {
    try testing.expectError(ParseError.InvalidParameter, parse("banana=42"));
}

test "invalid value non-numeric width returns error" {
    try testing.expectError(ParseError.InvalidWidth, parse("w=abc"));
}

test "cache key is deterministic" {
    const params = try parse("w=400,h=300,format=webp,q=85");
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const key1 = params.toCacheKey(&buf1);
    const key2 = params.toCacheKey(&buf2);
    try testing.expectEqualStrings(key1, key2);
}

test "cache key differs when params differ" {
    const params1 = try parse("w=400,h=300");
    const params2 = try parse("w=400,h=301");
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const key1 = params1.toCacheKey(&buf1);
    const key2 = params2.toCacheKey(&buf2);
    try testing.expect(!mem.eql(u8, key1, key2));
}

test "dpr multiplies effective dimensions" {
    const params = try parse("w=400,h=300,dpr=2.0");
    try testing.expectEqual(@as(?u32, 800), params.effectiveWidth());
    try testing.expectEqual(@as(?u32, 600), params.effectiveHeight());
}

test "dpr effective dimensions with null width and height" {
    const params = try parse("dpr=3.0");
    try testing.expectEqual(@as(?u32, null), params.effectiveWidth());
    try testing.expectEqual(@as(?u32, null), params.effectiveHeight());
}

test "sharpen bounds validation" {
    {
        var params = TransformParams{};
        params.sharpen = 5.0;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.sharpen = 11.0;
        try testing.expectError(ParseError.InvalidSharpen, params.validate());
    }
    {
        var params = TransformParams{};
        params.sharpen = -1.0;
        try testing.expectError(ParseError.InvalidSharpen, params.validate());
    }
}

test "blur bounds validation" {
    {
        var params = TransformParams{};
        params.blur = 1.0;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.blur = 300.0;
        try testing.expectError(ParseError.InvalidBlur, params.validate());
    }
    {
        var params = TransformParams{};
        params.blur = 0.05;
        try testing.expectError(ParseError.InvalidBlur, params.validate());
    }
}

test "dpr bounds validation" {
    {
        var params = TransformParams{};
        params.dpr = 2.5;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.dpr = 0.5;
        try testing.expectError(ParseError.InvalidDpr, params.validate());
    }
    {
        var params = TransformParams{};
        params.dpr = 6.0;
        try testing.expectError(ParseError.InvalidDpr, params.validate());
    }
}

test "empty value returns error" {
    try testing.expectError(ParseError.EmptyValue, parse("w="));
}

test "parse sharpen and blur values" {
    const params = try parse("sharpen=1.5,blur=3.0");
    try testing.expectEqual(@as(f32, 1.5), params.sharpen.?);
    try testing.expectEqual(@as(f32, 3.0), params.blur.?);
}

test "cache key order is canonical regardless of parse order" {
    const params1 = try parse("h=300,w=400,q=90");
    const params2 = try parse("w=400,q=90,h=300");
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const key1 = params1.toCacheKey(&buf1);
    const key2 = params2.toCacheKey(&buf2);
    try testing.expectEqualStrings(key1, key2);
}

test "valid params pass validation" {
    const params = try parse("w=800,h=600,q=90,format=webp,fit=cover,g=north,dpr=2.0");
    try params.validate();
}

test "width boundary values" {
    {
        var params = TransformParams{};
        params.width = 1;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.width = 8192;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.width = 8193;
        try testing.expectError(ParseError.InvalidWidth, params.validate());
    }
}

test "height validation at boundaries" {
    {
        var params = TransformParams{};
        params.height = 0;
        try testing.expectError(ParseError.InvalidHeight, params.validate());
    }
    {
        var params = TransformParams{};
        params.height = 8193;
        try testing.expectError(ParseError.InvalidHeight, params.validate());
    }
}

test "invalid format returns error" {
    try testing.expectError(ParseError.InvalidFormat, parse("format=bmp"));
}

test "invalid fit mode returns error" {
    try testing.expectError(ParseError.InvalidFitMode, parse("fit=stretch"));
}

test "invalid gravity returns error" {
    try testing.expectError(ParseError.InvalidGravity, parse("g=diagonal"));
}

test "parse rotate values" {
    const rotations = [_]struct { str: []const u8, expected: Rotation }{
        .{ .str = "0", .expected = .@"0" },
        .{ .str = "90", .expected = .@"90" },
        .{ .str = "180", .expected = .@"180" },
        .{ .str = "270", .expected = .@"270" },
    };
    for (rotations) |r| {
        var buf: [64]u8 = undefined;
        const input = fmt.bufPrint(&buf, "rotate={s}", .{r.str}) catch unreachable;
        const params = try parse(input);
        try testing.expectEqual(r.expected, params.rotate.?);
    }
}

test "invalid rotate returns error" {
    try testing.expectError(ParseError.InvalidRotation, parse("rotate=45"));
}

test "parse flip values" {
    {
        const params = try parse("flip=h");
        try testing.expectEqual(FlipMode.h, params.flip.?);
    }
    {
        const params = try parse("flip=v");
        try testing.expectEqual(FlipMode.v, params.flip.?);
    }
    {
        const params = try parse("flip=hv");
        try testing.expectEqual(FlipMode.hv, params.flip.?);
    }
}

test "invalid flip returns error" {
    try testing.expectError(ParseError.InvalidFlip, parse("flip=x"));
}

test "parse brightness contrast gamma" {
    const params = try parse("brightness=1.5,contrast=0.8,gamma=2.2");
    try testing.expectEqual(@as(f32, 1.5), params.brightness.?);
    try testing.expectEqual(@as(f32, 0.8), params.contrast.?);
    try testing.expectEqual(@as(f32, 2.2), params.gamma.?);
}

test "brightness bounds validation" {
    {
        var params = TransformParams{};
        params.brightness = 1.0;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.brightness = 2.1;
        try testing.expectError(ParseError.InvalidBrightness, params.validate());
    }
}

test "contrast bounds validation" {
    {
        var params = TransformParams{};
        params.contrast = 0.0;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.contrast = 2.1;
        try testing.expectError(ParseError.InvalidContrast, params.validate());
    }
}

test "saturation bounds validation" {
    {
        var params = TransformParams{};
        params.saturation = 1.5;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.saturation = 2.1;
        try testing.expectError(ParseError.InvalidSaturation, params.validate());
    }
}

test "gamma bounds validation" {
    {
        var params = TransformParams{};
        params.gamma = 2.2;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.gamma = 0.05;
        try testing.expectError(ParseError.InvalidGamma, params.validate());
    }
    {
        var params = TransformParams{};
        params.gamma = 11.0;
        try testing.expectError(ParseError.InvalidGamma, params.validate());
    }
}

test "parse background hex color" {
    const params = try parse("bg=FF0000");
    try testing.expectEqual(@as(u8, 255), params.background.?[0]);
    try testing.expectEqual(@as(u8, 0), params.background.?[1]);
    try testing.expectEqual(@as(u8, 0), params.background.?[2]);
}

test "parse background alias" {
    const params = try parse("background=00FF00");
    try testing.expectEqual(@as(u8, 0), params.background.?[0]);
    try testing.expectEqual(@as(u8, 255), params.background.?[1]);
    try testing.expectEqual(@as(u8, 0), params.background.?[2]);
}

test "invalid background returns error" {
    try testing.expectError(ParseError.InvalidBackground, parse("bg=red"));
    try testing.expectError(ParseError.InvalidBackground, parse("bg=GGHHII"));
    try testing.expectError(ParseError.InvalidBackground, parse("bg=FFF"));
}

test "parse metadata modes" {
    {
        const params = try parse("metadata=strip");
        try testing.expectEqual(MetadataMode.strip, params.metadata);
    }
    {
        const params = try parse("metadata=keep");
        try testing.expectEqual(MetadataMode.keep, params.metadata);
    }
    {
        const params = try parse("metadata=copyright");
        try testing.expectEqual(MetadataMode.copyright, params.metadata);
    }
}

test "invalid metadata returns error" {
    try testing.expectError(ParseError.InvalidMetadata, parse("metadata=partial"));
}

test "parse trim value" {
    const params = try parse("trim=10");
    try testing.expectEqual(@as(f32, 10.0), params.trim.?);
}

test "trim bounds validation" {
    {
        var params = TransformParams{};
        params.trim = 50.0;
        try params.validate();
    }
    {
        var params = TransformParams{};
        params.trim = 0.5;
        try testing.expectError(ParseError.InvalidTrim, params.validate());
    }
    {
        var params = TransformParams{};
        params.trim = 101.0;
        try testing.expectError(ParseError.InvalidTrim, params.validate());
    }
}

test "cache key includes new params" {
    const params = try parse("w=400,rotate=90,flip=h,brightness=1.5,bg=FF0000");
    var buf: [512]u8 = undefined;
    const key = params.toCacheKey(&buf);
    try testing.expect(mem.indexOf(u8, key, "rotate=90") != null);
    try testing.expect(mem.indexOf(u8, key, "flip=h") != null);
    try testing.expect(mem.indexOf(u8, key, "brightness=1.50") != null);
    try testing.expect(mem.indexOf(u8, key, "bg=FF0000") != null);
}

test "cache key omits default metadata" {
    const params = try parse("w=400");
    var buf: [512]u8 = undefined;
    const key = params.toCacheKey(&buf);
    try testing.expect(mem.indexOf(u8, key, "metadata") == null);
}

test "cache key includes non-default metadata" {
    const params = try parse("w=400,metadata=keep");
    var buf: [512]u8 = undefined;
    const key = params.toCacheKey(&buf);
    try testing.expect(mem.indexOf(u8, key, "metadata=keep") != null);
}

// ---------------------------------------------------------------------------
// Animation param tests
// ---------------------------------------------------------------------------

test "parse anim modes" {
    {
        const p = try parse("anim=auto");
        try testing.expectEqual(AnimMode.auto, p.anim);
    }
    {
        const p = try parse("anim=static");
        try testing.expectEqual(AnimMode.static, p.anim);
    }
    {
        const p = try parse("anim=animate");
        try testing.expectEqual(AnimMode.animate, p.anim);
    }
}

test "parse anim Cloudflare aliases" {
    {
        const p = try parse("anim=true");
        try testing.expectEqual(AnimMode.auto, p.anim);
    }
    {
        const p = try parse("anim=false");
        try testing.expectEqual(AnimMode.static, p.anim);
    }
}

test "invalid anim returns error" {
    try testing.expectError(ParseError.InvalidAnim, parse("anim=fast"));
}

test "parse frame value" {
    const p = try parse("frame=2");
    try testing.expectEqual(@as(?u32, 2), p.frame);
}

test "parse frame=0" {
    const p = try parse("frame=0");
    try testing.expectEqual(@as(?u32, 0), p.frame);
}

test "invalid frame returns error" {
    try testing.expectError(ParseError.InvalidFrame, parse("frame=abc"));
}

test "frame validation rejects large values" {
    var p = TransformParams{};
    p.frame = 1000;
    try testing.expectError(ParseError.InvalidFrame, p.validate());
}

test "frame validation accepts valid values" {
    var p = TransformParams{};
    p.frame = 999;
    try p.validate();
}

test "cache key includes anim when not default" {
    const p = try parse("w=400,anim=static");
    var buf: [512]u8 = undefined;
    const key = p.toCacheKey(&buf);
    try testing.expect(mem.indexOf(u8, key, "anim=static") != null);
}

test "cache key omits anim when auto" {
    const p = try parse("w=400");
    var buf: [512]u8 = undefined;
    const key = p.toCacheKey(&buf);
    try testing.expect(mem.indexOf(u8, key, "anim") == null);
}

test "cache key includes frame when set" {
    const p = try parse("w=400,frame=1");
    var buf: [512]u8 = undefined;
    const key = p.toCacheKey(&buf);
    try testing.expect(mem.indexOf(u8, key, "frame=1") != null);
}

test "OutputFormat gif contentType" {
    try testing.expectEqualStrings("image/gif", OutputFormat.gif.contentType());
}

test "OutputFormat gif extension" {
    try testing.expectEqualStrings("gif", OutputFormat.gif.extension());
}

test "OutputFormat gif fromString" {
    try testing.expectEqual(OutputFormat.gif, try OutputFormat.fromString("gif"));
}

test "OutputFormat supportsAnimation" {
    try testing.expect(OutputFormat.gif.supportsAnimation());
    try testing.expect(OutputFormat.webp.supportsAnimation());
    try testing.expect(!OutputFormat.jpeg.supportsAnimation());
    try testing.expect(!OutputFormat.png.supportsAnimation());
    try testing.expect(!OutputFormat.avif.supportsAnimation());
}
