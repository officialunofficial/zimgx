// Content negotiation for image format selection.
//
// Parses HTTP Accept headers and selects the best output format based
// on client capabilities, source image properties, and any explicit
// format requested via query parameters.

const std = @import("std");
const mem = std.mem;

const params = @import("params.zig");
const OutputFormat = params.OutputFormat;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Result of parsing an HTTP Accept header.  Each boolean indicates
/// whether the client advertised support for that image format.
/// `wildcard` is true when `*/*` or `image/*` was present, meaning the
/// client will accept any image type.
pub const AcceptResult = struct {
    supports_avif: bool = false,
    supports_webp: bool = false,
    supports_jpeg: bool = false,
    supports_png: bool = false,
    supports_gif: bool = false,
    wildcard: bool = false,

    /// Convenience: does the client accept the given format?
    pub fn supports(self: AcceptResult, fmt: OutputFormat) bool {
        return switch (fmt) {
            .avif => self.supports_avif or self.wildcard,
            .webp => self.supports_webp or self.wildcard,
            .jpeg => self.supports_jpeg or self.wildcard,
            .png => self.supports_png or self.wildcard,
            .gif => self.supports_gif or self.wildcard,
            .auto => true,
        };
    }
};

// ---------------------------------------------------------------------------
// Public functions
// ---------------------------------------------------------------------------

/// Parse a standard HTTP Accept header value into an `AcceptResult`.
///
/// The header is a comma-separated list of media-ranges, each
/// optionally followed by parameters (`;q=…`).  Examples:
///
///   image/webp,image/avif,image/*,*/*;q=0.8
///   image/webp;q=0.9, image/avif;q=1.0
///
/// Quality values are parsed but only used to detect formats that are
/// explicitly disabled (`q=0`).  The priority ordering is fixed:
/// avif > webp > jpeg > png (handled by `negotiateFormat`).
pub fn parseAcceptHeader(accept: []const u8) AcceptResult {
    var result = AcceptResult{};

    if (accept.len == 0) {
        return result;
    }

    // Split on commas
    var iter = mem.splitSequence(u8, accept, ",");
    while (iter.next()) |raw_entry| {
        const entry = mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;

        // Separate media-type from parameters (;q=…)
        var parts = mem.splitSequence(u8, entry, ";");
        const media_type = mem.trim(u8, parts.next() orelse continue, " \t");

        // Check for q=0 which explicitly disables a format
        var q_value: f32 = 1.0;
        while (parts.next()) |param_raw| {
            const param = mem.trim(u8, param_raw, " \t");
            if (mem.startsWith(u8, param, "q=") or mem.startsWith(u8, param, "Q=")) {
                q_value = std.fmt.parseFloat(f32, param[2..]) catch 1.0;
            }
        }

        // q=0 means explicitly not accepted
        if (q_value == 0.0) continue;

        // Match the media-type
        if (mem.eql(u8, media_type, "*/*")) {
            result.wildcard = true;
        } else if (mem.eql(u8, media_type, "image/*")) {
            result.wildcard = true;
        } else if (mem.eql(u8, media_type, "image/avif")) {
            result.supports_avif = true;
        } else if (mem.eql(u8, media_type, "image/webp")) {
            result.supports_webp = true;
        } else if (mem.eql(u8, media_type, "image/jpeg") or mem.eql(u8, media_type, "image/jpg")) {
            result.supports_jpeg = true;
        } else if (mem.eql(u8, media_type, "image/png")) {
            result.supports_png = true;
        } else if (mem.eql(u8, media_type, "image/gif")) {
            result.supports_gif = true;
        }
        // Unknown media types are silently ignored.
    }

    return result;
}

/// Select the best output image format given client Accept header
/// capabilities, source image properties, and an optional explicit
/// format request.
///
/// Resolution order:
///   1. If `requested_format` is set and is NOT `.auto`, return it as-is.
///   2. Otherwise, negotiate from the Accept header using fixed
///      priority: avif > webp > jpeg > png.
///   3. When the source has an alpha channel, jpeg is deprioritised
///      because it cannot represent transparency.  In that case,
///      webp or png are preferred if the client supports them.
///   4. If nothing matches (empty/null Accept), default to jpeg
///      (the most universally supported format).
pub fn negotiateFormat(
    accept_header: ?[]const u8,
    source_has_alpha: bool,
    requested_format: ?OutputFormat,
) OutputFormat {
    // 1. Explicit format takes precedence (unless `.auto`).
    if (requested_format) |fmt| {
        if (fmt != .auto) return fmt;
    }

    // 2. Parse Accept header.
    const accept = if (accept_header) |h| parseAcceptHeader(h) else AcceptResult{};

    // 3. Negotiate.
    //    Fixed priority: avif > webp > (jpeg|png depending on alpha) > png|jpeg.
    if (source_has_alpha) {
        // Alpha channel present — avoid jpeg when alternatives exist.
        if (accept.supports(.avif)) return .avif;
        if (accept.supports(.webp)) return .webp;
        if (accept.supports(.png)) return .png;
        // Last resort: jpeg (lossy alpha discard).
        return .jpeg;
    } else {
        // No alpha — standard priority.
        if (accept.supports(.avif)) return .avif;
        if (accept.supports(.webp)) return .webp;
        if (accept.supports(.jpeg)) return .jpeg;
        if (accept.supports(.png)) return .png;
        // Fallback when Accept is empty / unsupported.
        return .jpeg;
    }
}

/// Select the best output format for an animated source image.
///
/// Priority for animated output: webp > gif (animated WebP is smaller).
/// - If an explicit format is set and supports animation, use it.
/// - If an explicit format is set but does NOT support animation (jpeg,
///   png, avif), return null — the pipeline should degrade to static.
/// - If auto-negotiating: prefer webp if accepted, then gif, else null
///   (degrade to static).
pub fn negotiateAnimatedFormat(
    accept_header: ?[]const u8,
    requested_format: ?OutputFormat,
) ?OutputFormat {
    // Explicit format requested
    if (requested_format) |fmt| {
        if (fmt == .auto) {
            // Fall through to negotiation
        } else if (fmt.supportsAnimation()) {
            return fmt;
        } else {
            // Explicit non-animated format → degrade to static
            return null;
        }
    }

    // Auto-negotiate: prefer animated webp > gif
    const accept = if (accept_header) |h| parseAcceptHeader(h) else AcceptResult{};
    if (accept.supports(.webp)) return .webp;
    if (accept.supports(.gif)) return .gif;

    // No animated format accepted → degrade to static
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

test "parseAcceptHeader — single format: image/webp" {
    const r = parseAcceptHeader("image/webp");
    try std.testing.expect(r.supports_webp);
    try std.testing.expect(!r.supports_avif);
    try std.testing.expect(!r.supports_jpeg);
    try std.testing.expect(!r.supports_png);
    try std.testing.expect(!r.wildcard);
}

test "parseAcceptHeader — multiple formats with image/* wildcard" {
    const r = parseAcceptHeader("image/avif,image/webp,image/*");
    try std.testing.expect(r.supports_avif);
    try std.testing.expect(r.supports_webp);
    try std.testing.expect(r.wildcard);
    // wildcard means jpeg/png are implicitly supported
    try std.testing.expect(r.supports(.jpeg));
    try std.testing.expect(r.supports(.png));
}

test "parseAcceptHeader — */* wildcard" {
    const r = parseAcceptHeader("*/*");
    try std.testing.expect(r.wildcard);
    // All formats available through wildcard
    try std.testing.expect(r.supports(.avif));
    try std.testing.expect(r.supports(.webp));
    try std.testing.expect(r.supports(.jpeg));
    try std.testing.expect(r.supports(.png));
}

test "parseAcceptHeader — image/* wildcard" {
    const r = parseAcceptHeader("image/*");
    try std.testing.expect(r.wildcard);
    try std.testing.expect(r.supports(.avif));
    try std.testing.expect(r.supports(.webp));
    try std.testing.expect(r.supports(.jpeg));
    try std.testing.expect(r.supports(.png));
}

test "parseAcceptHeader — empty string" {
    const r = parseAcceptHeader("");
    try std.testing.expect(!r.supports_avif);
    try std.testing.expect(!r.supports_webp);
    try std.testing.expect(!r.supports_jpeg);
    try std.testing.expect(!r.supports_png);
    try std.testing.expect(!r.wildcard);
}

test "parseAcceptHeader — q-values parsed, q=0 disables format" {
    // avif has q=1.0, webp has q=0 (disabled)
    const r = parseAcceptHeader("image/webp;q=0,image/avif;q=1.0");
    try std.testing.expect(r.supports_avif);
    try std.testing.expect(!r.supports_webp); // disabled by q=0
}

test "parseAcceptHeader — q-values non-zero are accepted" {
    const r = parseAcceptHeader("image/webp;q=0.9,image/avif;q=1.0");
    try std.testing.expect(r.supports_avif);
    try std.testing.expect(r.supports_webp);
}

test "parseAcceptHeader — spaces around entries are trimmed" {
    const r = parseAcceptHeader("  image/avif , image/webp ; q=0.8 , image/png ");
    try std.testing.expect(r.supports_avif);
    try std.testing.expect(r.supports_webp);
    try std.testing.expect(r.supports_png);
    try std.testing.expect(!r.supports_jpeg);
}

test "parseAcceptHeader — jpeg and jpg aliases" {
    const r1 = parseAcceptHeader("image/jpeg");
    try std.testing.expect(r1.supports_jpeg);

    const r2 = parseAcceptHeader("image/jpg");
    try std.testing.expect(r2.supports_jpeg);
}

test "parseAcceptHeader — unknown media types are ignored" {
    const r = parseAcceptHeader("image/tiff,application/json,text/html");
    try std.testing.expect(!r.supports_avif);
    try std.testing.expect(!r.supports_webp);
    try std.testing.expect(!r.supports_jpeg);
    try std.testing.expect(!r.supports_png);
    try std.testing.expect(!r.wildcard);
}

test "parseAcceptHeader — malformed entries are gracefully ignored" {
    // Various broken inputs — none should panic
    const r1 = parseAcceptHeader(";;;");
    try std.testing.expect(!r1.wildcard);

    const r2 = parseAcceptHeader(",,,");
    try std.testing.expect(!r2.wildcard);

    const r3 = parseAcceptHeader("image/webp;q=notanumber");
    // q parse fails → defaults to 1.0 → webp accepted
    try std.testing.expect(r3.supports_webp);

    const r4 = parseAcceptHeader("image/webp;q=");
    // q= with empty value → parse fails → defaults to 1.0
    try std.testing.expect(r4.supports_webp);
}

test "parseAcceptHeader — realistic browser Accept header" {
    const chrome = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8";
    const r = parseAcceptHeader(chrome);
    try std.testing.expect(r.supports_avif);
    try std.testing.expect(r.supports_webp);
    try std.testing.expect(r.wildcard);
}

// ---------------------------------------------------------------------------
// negotiateFormat tests
// ---------------------------------------------------------------------------

test "negotiateFormat — explicit format overrides everything" {
    try std.testing.expectEqual(OutputFormat.png, negotiateFormat("image/webp", false, .png));
    try std.testing.expectEqual(OutputFormat.jpeg, negotiateFormat("image/avif", true, .jpeg));
    try std.testing.expectEqual(OutputFormat.avif, negotiateFormat(null, false, .avif));
}

test "negotiateFormat — auto triggers negotiation" {
    try std.testing.expectEqual(OutputFormat.webp, negotiateFormat("image/webp", false, .auto));
}

test "negotiateFormat — null requested_format triggers negotiation" {
    try std.testing.expectEqual(OutputFormat.webp, negotiateFormat("image/webp", false, null));
}

test "negotiateFormat — null accept header defaults to jpeg" {
    try std.testing.expectEqual(OutputFormat.jpeg, negotiateFormat(null, false, null));
}

test "negotiateFormat — empty accept header defaults to jpeg" {
    try std.testing.expectEqual(OutputFormat.jpeg, negotiateFormat("", false, null));
}

test "negotiateFormat — avif preferred over webp" {
    try std.testing.expectEqual(
        OutputFormat.avif,
        negotiateFormat("image/avif,image/webp", false, null),
    );
}

test "negotiateFormat — webp preferred over jpeg" {
    try std.testing.expectEqual(
        OutputFormat.webp,
        negotiateFormat("image/webp,image/jpeg", false, null),
    );
}

test "negotiateFormat — jpeg preferred over png (no alpha)" {
    try std.testing.expectEqual(
        OutputFormat.jpeg,
        negotiateFormat("image/jpeg,image/png", false, null),
    );
}

test "negotiateFormat — alpha source + webp+jpeg → webp preferred" {
    try std.testing.expectEqual(
        OutputFormat.webp,
        negotiateFormat("image/webp,image/jpeg", true, null),
    );
}

test "negotiateFormat — alpha source + jpeg-only → still jpeg (no choice)" {
    try std.testing.expectEqual(
        OutputFormat.jpeg,
        negotiateFormat("image/jpeg", true, null),
    );
}

test "negotiateFormat — alpha source + png+jpeg → png preferred over jpeg" {
    try std.testing.expectEqual(
        OutputFormat.png,
        negotiateFormat("image/png,image/jpeg", true, null),
    );
}

test "negotiateFormat — alpha source + avif+webp+jpeg → avif wins" {
    try std.testing.expectEqual(
        OutputFormat.avif,
        negotiateFormat("image/avif,image/webp,image/jpeg", true, null),
    );
}

test "negotiateFormat — wildcard accept → avif (highest priority)" {
    try std.testing.expectEqual(
        OutputFormat.avif,
        negotiateFormat("*/*", false, null),
    );
}

test "negotiateFormat — wildcard accept + alpha → avif" {
    try std.testing.expectEqual(
        OutputFormat.avif,
        negotiateFormat("image/*", true, null),
    );
}

test "negotiateFormat — only png accepted, no alpha" {
    try std.testing.expectEqual(
        OutputFormat.png,
        negotiateFormat("image/png", false, null),
    );
}

test "negotiateFormat — malformed accept → fallback to jpeg" {
    try std.testing.expectEqual(
        OutputFormat.jpeg,
        negotiateFormat("garbage/nonsense", false, null),
    );
}

test "negotiateFormat — all formats disabled by q=0 → fallback to jpeg" {
    try std.testing.expectEqual(
        OutputFormat.jpeg,
        negotiateFormat("image/avif;q=0,image/webp;q=0,image/png;q=0", false, null),
    );
}

// ---------------------------------------------------------------------------
// negotiateAnimatedFormat tests
// ---------------------------------------------------------------------------

test "negotiateAnimatedFormat — Accept: webp → webp" {
    try std.testing.expectEqual(
        @as(?OutputFormat, .webp),
        negotiateAnimatedFormat("image/webp", null),
    );
}

test "negotiateAnimatedFormat — Accept: gif → gif" {
    try std.testing.expectEqual(
        @as(?OutputFormat, .gif),
        negotiateAnimatedFormat("image/gif", null),
    );
}

test "negotiateAnimatedFormat — Accept: webp,gif → webp preferred" {
    try std.testing.expectEqual(
        @as(?OutputFormat, .webp),
        negotiateAnimatedFormat("image/webp,image/gif", null),
    );
}

test "negotiateAnimatedFormat — Accept: jpeg only → null (static fallback)" {
    try std.testing.expectEqual(
        @as(?OutputFormat, null),
        negotiateAnimatedFormat("image/jpeg", null),
    );
}

test "negotiateAnimatedFormat — explicit gif format" {
    try std.testing.expectEqual(
        @as(?OutputFormat, .gif),
        negotiateAnimatedFormat("image/jpeg", .gif),
    );
}

test "negotiateAnimatedFormat — explicit webp format" {
    try std.testing.expectEqual(
        @as(?OutputFormat, .webp),
        negotiateAnimatedFormat("image/jpeg", .webp),
    );
}

test "negotiateAnimatedFormat — explicit jpeg → null (not animated)" {
    try std.testing.expectEqual(
        @as(?OutputFormat, null),
        negotiateAnimatedFormat("image/webp", .jpeg),
    );
}

test "negotiateAnimatedFormat — wildcard accept → webp" {
    try std.testing.expectEqual(
        @as(?OutputFormat, .webp),
        negotiateAnimatedFormat("*/*", null),
    );
}

test "parseAcceptHeader — gif support" {
    const r = parseAcceptHeader("image/gif");
    try std.testing.expect(r.supports_gif);
    try std.testing.expect(!r.supports_webp);
}

test "AcceptResult supports gif through wildcard" {
    const r = parseAcceptHeader("*/*");
    try std.testing.expect(r.supports(.gif));
}
