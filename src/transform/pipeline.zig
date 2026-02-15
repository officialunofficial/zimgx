// Transform pipeline
//
// Wires TransformParams to libvips operations in a fixed order:
//   1. Decode     — load image from buffer into a VipsImage
//   2. Trim       — detect and crop border pixels (before resize)
//   3. Rotate/Flip — geometric transforms (before resize for correct dims)
//   4. Resize     — apply width/height with fit-mode mapping (incl. pad)
//   5. Effects    — sharpen, blur, brightness, contrast, gamma, saturation
//   6. Background — flatten alpha onto background color before encode
//   7. Encode     — save to negotiated output format with quality/metadata
//
// The pipeline owns intermediate VipsImage handles and unrefs them as
// it progresses through each step. The final encoded buffer is returned
// in a TransformResult whose `deinit` frees the vips-allocated memory.

const std = @import("std");
const params_mod = @import("params.zig");
const negotiate_mod = @import("negotiate.zig");
const bindings = @import("../vips/bindings.zig");

const TransformParams = params_mod.TransformParams;
const OutputFormat = params_mod.OutputFormat;
const FitMode = params_mod.FitMode;
const Gravity = params_mod.Gravity;
const Rotation = params_mod.Rotation;
const FlipMode = params_mod.FlipMode;
const MetadataMode = params_mod.MetadataMode;
const AnimMode = params_mod.AnimMode;
const VipsImage = bindings.VipsImage;
const VipsError = bindings.VipsError;
const c = bindings.c;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Result of a transform pipeline execution.
pub const TransformResult = struct {
    data: []u8,
    format: OutputFormat,
    width: u32,
    height: u32,
    is_animated: bool = false,
    frame_count: ?u32 = null,

    /// Free the vips/glib-allocated output buffer.
    pub fn deinit(self: *TransformResult) void {
        bindings.gFree(@ptrCast(self.data.ptr));
    }
};

/// Safety limits for animated image processing.
pub const AnimConfig = struct {
    max_frames: u32 = 100,
    max_animated_pixels: u64 = 50_000_000,
};

/// Errors specific to the pipeline (in addition to VipsError which can
/// propagate from bindings).
pub const PipelineError = error{
    NoResizeDimensions,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Execute the full transform pipeline: decode -> resize -> effects -> encode.
///
/// `input_data` is the raw bytes of the source image (any format libvips
/// can detect).  `params` controls the resize/effect/encode behaviour.
/// `accept_header` is the client's HTTP Accept header used when format
/// negotiation is needed (format == .auto or null).
/// `anim_config` optionally provides safety limits for animated images.
pub fn transform(
    input_data: []const u8,
    tp: TransformParams,
    accept_header: ?[]const u8,
    anim_config: ?AnimConfig,
) (VipsError || PipelineError)!TransformResult {
    const anim_cfg = anim_config orelse AnimConfig{};

    // ── PROBE ──────────────────────────────────────────────────────────
    // Load first frame only (cheap) to detect animation metadata.
    var current = try bindings.imageNewFromBuffer(input_data);
    errdefer current.unref();

    const n_pages = bindings.getNPages(current);
    const is_animated = if (n_pages) |n| n > 1 else false;

    // ── BUDGET CHECK ──────────────────────────────────────────────────
    // Enforce animated pixel budget. If total pixels across all frames
    // exceeds the limit, fall back to static first frame (like Cloudflare).
    const over_budget: bool = if (is_animated) blk: {
        const frame_w: u64 = @intCast(bindings.getWidth(current));
        const page_h: u64 = @intCast(bindings.getPageHeight(current) orelse bindings.getHeight(current));
        const frame_count: u64 = @intCast(n_pages orelse 1);
        const total_pixels = frame_w * page_h * frame_count;
        break :blk total_pixels > anim_cfg.max_animated_pixels;
    } else false;

    // Effective frame count after clamping to max_frames.
    // When is_animated is true, n_pages is guaranteed non-null (>1).
    const effective_pages: ?u32 = if (is_animated and !over_budget)
        @min(n_pages.?, anim_cfg.max_frames)
    else
        n_pages;

    // ── DECIDE ─────────────────────────────────────────────────────────
    // Determine whether to produce animated output and which format to use.
    const animated_format: ?OutputFormat = if (is_animated and
        !over_budget and
        tp.anim != .static and
        tp.frame == null)
        negotiate_mod.negotiateAnimatedFormat(accept_header, tp.format)
    else
        null;

    const animated_output = animated_format != null;

    // ── RELOAD ─────────────────────────────────────────────────────────
    // If producing animated output, reload with all frames stacked.
    // Clamp to max_frames if the source exceeds the limit.
    // When animated_output is true, both effective_pages and n_pages are
    // guaranteed non-null (derived from is_animated which requires n_pages > 1).
    if (animated_output) {
        current.unref();
        if (effective_pages.? < n_pages.?) {
            current = try bindings.imageNewFromBufferAnimatedN(input_data, @intCast(effective_pages.?));
        } else {
            current = try bindings.imageNewFromBufferAnimated(input_data);
        }
    }

    // ── EXTRACT FRAME ──────────────────────────────────────────────────
    // If a specific frame is requested and the source is animated,
    // extract that single frame and proceed as static.
    if (tp.frame != null and is_animated) {
        // Need all frames loaded to extract one
        if (!animated_output) {
            current.unref();
            current = try bindings.imageNewFromBufferAnimated(input_data);
        }
        const page_height = bindings.getPageHeight(current) orelse bindings.getHeight(current);
        const frame_idx = tp.frame.?;
        const actual_pages = n_pages orelse 1;
        // Clamp frame index to valid range
        const safe_frame = if (frame_idx >= actual_pages) actual_pages - 1 else frame_idx;
        const img_width = bindings.getWidth(current);
        current = replaceImage(current, try bindings.crop(
            current,
            0,
            @intCast(safe_frame * page_height),
            @intCast(img_width),
            @intCast(page_height),
        ));
        // From here on, treat as static single-frame image
    }

    // ── TRIM ───────────────────────────────────────────────────────────
    // Skip trim for animated output (operates on full stack, not per-frame)
    if (tp.trim) |threshold| {
        if (!animated_output) {
            const trim_info = try bindings.findTrim(current, @floatCast(threshold));
            if (trim_info.width > 0 and trim_info.height > 0) {
                current = replaceImage(current, try bindings.crop(current, trim_info.left, trim_info.top, trim_info.width, trim_info.height));
            }
        }
    }

    // ── ROTATE / FLIP ──────────────────────────────────────────────────
    if (tp.rotate) |rotation| {
        const angle: c.VipsAngle = switch (rotation) {
            .@"0" => c.VIPS_ANGLE_D0,
            .@"90" => c.VIPS_ANGLE_D90,
            .@"180" => c.VIPS_ANGLE_D180,
            .@"270" => c.VIPS_ANGLE_D270,
        };
        if (angle != c.VIPS_ANGLE_D0) {
            current = replaceImage(current, try bindings.rot(current, angle));
        }
    }

    if (tp.flip) |flip_mode| {
        if (flip_mode == .h or flip_mode == .hv) {
            current = replaceImage(current, try bindings.flip(current, c.VIPS_DIRECTION_HORIZONTAL));
        }
        if (flip_mode == .v or flip_mode == .hv) {
            current = replaceImage(current, try bindings.flip(current, c.VIPS_DIRECTION_VERTICAL));
        }
    }

    // ── RESIZE ─────────────────────────────────────────────────────────
    const eff_w = tp.effectiveWidth();
    const eff_h = tp.effectiveHeight();

    if (eff_w != null or eff_h != null) {
        const source_w = bindings.getWidth(current);
        const source_h = bindings.getHeight(current);

        // For fit=pad, use contain-style thumbnail then embed into target
        const effective_fit: FitMode = if (tp.fit == .pad) .contain else tp.fit;

        const thumb_width: u32 = eff_w orelse blk: {
            const h = eff_h.?;
            const ratio = @as(f64, @floatFromInt(source_w)) / @as(f64, @floatFromInt(source_h));
            const derived = @as(f64, @floatFromInt(h)) * ratio;
            const clamped = @min(derived, 8192.0);
            break :blk @max(1, @as(u32, @intFromFloat(clamped)));
        };

        // For animated images with fit=cover, vips_thumbnail_image's crop
        // operates on the full stacked frame buffer and corrupts frame
        // boundaries (libvips#2668). Use a two-step approach instead:
        //   1. Resize without crop (each frame >= target dims)
        //   2. Crop per-frame and reassemble
        if (animated_output and effective_fit == .cover and eff_w != null and eff_h != null) {
            const pages = effective_pages orelse n_pages orelse 1;
            const page_h = bindings.getPageHeight(current) orelse (source_h / pages);
            const tw = eff_w.?;
            const th = eff_h.?;

            // Scale so each frame covers the target rectangle
            const hscale = @as(f64, @floatFromInt(tw)) / @as(f64, @floatFromInt(source_w));
            const vscale = @as(f64, @floatFromInt(th)) / @as(f64, @floatFromInt(page_h));
            const scale = @max(hscale, vscale);
            const resize_w: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(source_w)) * scale))));
            const resize_page_h: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(page_h)) * scale))));
            const resize_stack_h = resize_page_h * pages;

            // Step 1: Resize without crop — pass stack height, no crop option
            const resize_opts = bindings.ThumbnailOptions{ .height = resize_stack_h };
            current = replaceImage(current, try bindings.thumbnailImage(current, resize_w, resize_opts));

            const resized_page_h = bindings.getHeight(current) / pages;

            // Step 2: Crop per-frame if needed
            if (resized_page_h > th or bindings.getWidth(current) > tw) {
                const cur_w = bindings.getWidth(current);
                const crop_left: c_int = @intCast((cur_w - tw) / 2);
                const crop_top: c_int = @intCast((resized_page_h - th) / 2);

                if (crop_top == 0) {
                    // Horizontal-only crop: single extract_area on full stack
                    current = replaceImage(current, try bindings.crop(
                        current,
                        crop_left,
                        0,
                        @intCast(tw),
                        @intCast(bindings.getHeight(current)),
                    ));
                } else {
                    // Vertical crop needed: extract each frame, crop, reassemble
                    var frames: [256]bindings.VipsImage = undefined;
                    const frame_count = @min(pages, 256);
                    var fi: u32 = 0;
                    while (fi < frame_count) : (fi += 1) {
                        const y_off: c_int = @intCast(fi * resized_page_h);
                        frames[fi] = try bindings.crop(
                            current,
                            crop_left,
                            y_off + crop_top,
                            @intCast(tw),
                            @intCast(th),
                        );
                    }
                    const old = current;
                    current = try bindings.arrayjoinVertical(frames[0..frame_count]);
                    old.unref();
                    for (frames[0..frame_count]) |f| f.unref();
                }
            }

            bindings.setInt(current, "page-height", @intCast(th));
        } else {
            const opts = buildThumbnailOptions(effective_fit, tp.gravity, eff_h);
            current = replaceImage(current, try bindings.thumbnailImage(current, thumb_width, opts));

            // After resize, update page-height metadata for animated images so
            // the GIF/WebP encoder splits frames at the correct boundary.
            if (animated_output) {
                const new_height = bindings.getHeight(current);
                const pages = effective_pages orelse n_pages orelse 1;
                const new_page_height = new_height / pages;
                if (new_page_height > 0) {
                    bindings.setInt(current, "page-height", @intCast(new_page_height));
                }
            }
        }

        // fit=pad: embed the resized image centered on a canvas of target dims
        // Skip pad for animated output (would pad the full stack height)
        if (tp.fit == .pad and !animated_output) {
            const target_w = eff_w orelse bindings.getWidth(current);
            const target_h = eff_h orelse bindings.getHeight(current);
            const cur_w = bindings.getWidth(current);
            const cur_h = bindings.getHeight(current);

            if (cur_w < target_w or cur_h < target_h) {
                const off_x: c_int = @intCast((target_w - cur_w) / 2);
                const off_y: c_int = @intCast((target_h - cur_h) / 2);
                const bg = bgColorFromParams(tp.background);
                current = replaceImage(current, try bindings.embed(current, off_x, off_y, @intCast(target_w), @intCast(target_h), bg));
            }
        }
    }

    // ── EFFECTS ────────────────────────────────────────────────────────
    if (tp.sharpen) |sigma| {
        current = replaceImage(current, try bindings.sharpen(current, @floatCast(sigma)));
    }

    if (tp.blur) |sigma| {
        current = replaceImage(current, try bindings.gaussblur(current, @floatCast(sigma)));
    }

    if (tp.brightness != null or tp.contrast != null) {
        const contrast_val: f64 = if (tp.contrast) |cv| @floatCast(cv) else 1.0;
        const brightness_offset: f64 = if (tp.brightness) |b| (@as(f64, @floatCast(b)) - 1.0) * 128.0 else 0.0;
        current = replaceImage(current, try bindings.linear1(current, contrast_val, brightness_offset));
    }

    if (tp.gamma) |g| {
        current = replaceImage(current, try bindings.gamma(current, @floatCast(g)));
    }

    if (tp.saturation) |sat| {
        const sat_f64: f64 = @floatCast(sat);
        current = replaceImage(current, try bindings.colourspace(current, c.VIPS_INTERPRETATION_LCH));

        const l_band = try bindings.extractBand(current, 0, 1);
        const c_band = try bindings.extractBand(current, 1, 1);
        const h_band = try bindings.extractBand(current, 2, 1);

        const c_scaled = try bindings.linear1(c_band, sat_f64, 0.0);
        c_band.unref();

        const lc = try bindings.bandjoin2(l_band, c_scaled);
        l_band.unref();
        c_scaled.unref();

        const lch_result = try bindings.bandjoin2(lc, h_band);
        lc.unref();
        h_band.unref();

        current.unref();
        current = try bindings.colourspace(lch_result, c.VIPS_INTERPRETATION_sRGB);
        lch_result.unref();
    }

    // ── BACKGROUND ─────────────────────────────────────────────────────
    if (tp.background != null and tp.fit != .pad and bindings.hasAlpha(current)) {
        current = replaceImage(current, try bindings.flatten(current, bgColorFromParams(tp.background)));
    }

    // ── ENCODE ─────────────────────────────────────────────────────────
    const output_format = animated_format orelse negotiate_mod.negotiateFormat(
        accept_header,
        bindings.hasAlpha(current),
        tp.format,
    );

    const out_width = bindings.getWidth(current);
    const out_height = bindings.getHeight(current);

    const save_buf = try encodeImage(current, output_format, tp.quality, tp.metadata);

    current.unref();

    return TransformResult{
        .data = save_buf.data,
        .format = output_format,
        .width = out_width,
        .height = out_height,
        .is_animated = animated_output,
        .frame_count = if (animated_output) effective_pages else null,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Unref the old image and return the new one. Used to advance the
/// pipeline through each processing step.
fn replaceImage(old: VipsImage, new: VipsImage) VipsImage {
    old.unref();
    return new;
}

/// Convert an optional RGB byte triplet to f64 background array.
/// Defaults to white (255, 255, 255) when no color is specified.
fn bgColorFromParams(background: ?[3]u8) [3]f64 {
    const rgb = background orelse return .{ 255.0, 255.0, 255.0 };
    return .{ @floatFromInt(rgb[0]), @floatFromInt(rgb[1]), @floatFromInt(rgb[2]) };
}

/// Map FitMode + Gravity to vips ThumbnailOptions.
fn buildThumbnailOptions(
    fit: FitMode,
    gravity: Gravity,
    height: ?u32,
) bindings.ThumbnailOptions {
    var opts = bindings.ThumbnailOptions{
        .height = height,
    };

    switch (fit) {
        .contain, .pad, .inside => opts.size = bindings.c.VIPS_SIZE_DOWN,
        .cover => opts.crop = mapGravityToCrop(gravity),
        .fill => opts.size = bindings.c.VIPS_SIZE_FORCE,
        .outside => opts.size = bindings.c.VIPS_SIZE_UP,
    }

    return opts;
}

/// Map a Gravity enum value to the corresponding VIPS_INTERESTING_* constant.
fn mapGravityToCrop(gravity: Gravity) bindings.c.VipsInteresting {
    return switch (gravity) {
        .center => bindings.c.VIPS_INTERESTING_CENTRE,
        .smart => bindings.c.VIPS_INTERESTING_ENTROPY,
        .attention => bindings.c.VIPS_INTERESTING_ATTENTION,
        // Directional gravities (north, south, etc.) are not directly
        // supported by vips_thumbnail_image's crop parameter. Fall back
        // to centre cropping.
        .north,
        .south,
        .east,
        .west,
        .northeast,
        .northwest,
        .southeast,
        .southwest,
        => bindings.c.VIPS_INTERESTING_CENTRE,
    };
}

/// Encode a VipsImage into a buffer using the specified output format.
fn encodeImage(
    image: VipsImage,
    format: OutputFormat,
    quality: u8,
    metadata: MetadataMode,
) VipsError!bindings.SaveBuffer {
    const q: u32 = @intCast(quality);
    // .strip → strip all metadata; .keep/.copyright → preserve metadata
    // (libvips doesn't have a "copyright-only" mode, so .copyright
    //  is treated the same as .keep for now — a future enhancement
    //  could selectively remove non-copyright EXIF tags)
    const do_strip = metadata == .strip;
    return switch (format) {
        .jpeg, .auto => bindings.jpegsaveBufferOpts(image, q, do_strip),
        .png => bindings.pngsaveBufferOpts(image, 6, do_strip),
        .webp => bindings.webpsaveBufferOpts(image, q, do_strip),
        .avif => bindings.avifsaveBufferOpts(image, q, do_strip),
        .gif => encodeGif(image),
    };
}

/// Encode a VipsImage as GIF.  Before encoding, validates that
/// page-height metadata evenly divides the total image height.
/// Stale metadata (left over from resize or effects) would cause
/// a SIGSEGV in the GIF encoder, so we reset to single-frame.
fn encodeGif(image: VipsImage) VipsError!bindings.SaveBuffer {
    if (bindings.getPageHeight(image)) |ph| {
        const h = bindings.getHeight(image);
        if (ph > h or h % ph != 0) {
            bindings.setInt(image, "page-height", @intCast(h));
            bindings.setInt(image, "n-pages", 1);
        }
    }
    return bindings.gifsaveBuffer(image);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Read the 4x4 RGBA PNG test fixture at runtime. The cwd is the
/// project root when running via `zig build test`.
fn readTestFixture() ![]const u8 {
    const file = try std.fs.cwd().openFile("test/fixtures/test_4x4.png", .{});
    const stat = try file.stat();
    const buf = try testing.allocator.alloc(u8, stat.size);
    const n = try file.readAll(buf);
    file.close();
    return buf[0..n];
}

var test_vips_inited: bool = false;

fn testInit() void {
    if (!test_vips_inited) {
        bindings.init() catch @panic("vips init failed");
        test_vips_inited = true;
    }
}

test "transform with default params preserves image" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var result = try transform(data, TransformParams{}, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    // Default params have no resize, so dimensions should be preserved.
    try testing.expectEqual(@as(u32, 4), result.width);
    try testing.expectEqual(@as(u32, 4), result.height);
}

test "transform resize to specific width" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.width = 2;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 2), result.width);
}

test "transform to jpeg format" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .jpeg;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.jpeg, result.format);
}

test "transform to webp format" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .webp;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.webp, result.format);
}

test "transform to png format" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .png;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.png, result.format);
}

test "transform with auto format negotiation" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .auto;

    // Client only accepts webp
    var result = try transform(data, p, "image/webp", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.webp, result.format);
}

test "transform with sharpen" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.sharpen = 1.5;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 4), result.width);
    try testing.expectEqual(@as(u32, 4), result.height);
}

test "transform with blur" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.blur = 2.0;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 4), result.width);
    try testing.expectEqual(@as(u32, 4), result.height);
}

test "transform with fit cover" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.width = 2;
    p.height = 2;
    p.fit = .cover;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 2), result.width);
    try testing.expectEqual(@as(u32, 2), result.height);
}

test "transform with fit fill" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.width = 2;
    p.height = 3;
    p.fit = .fill;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 2), result.width);
    try testing.expectEqual(@as(u32, 3), result.height);
}

test "transform with rotate 90" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.rotate = .@"90";

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    // 4x4 square rotated is still 4x4
    try testing.expectEqual(@as(u32, 4), result.width);
    try testing.expectEqual(@as(u32, 4), result.height);
}

test "transform with flip horizontal" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.flip = .h;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 4), result.width);
    try testing.expectEqual(@as(u32, 4), result.height);
}

test "transform with brightness" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.brightness = 1.5;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(@as(u32, 4), result.width);
}

test "transform with contrast" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.contrast = 0.8;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
}

test "transform with gamma" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.gamma = 2.2;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
}

test "transform with fit pad" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.width = 8;
    p.height = 8;
    p.fit = .pad;
    p.background = .{ 255, 0, 0 };

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    // Pad should produce exact target dimensions
    try testing.expectEqual(@as(u32, 8), result.width);
    try testing.expectEqual(@as(u32, 8), result.height);
}

test "transform with metadata keep" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.metadata = .keep;
    p.format = .png;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
}

// ---------------------------------------------------------------------------
// Animated pipeline tests
// ---------------------------------------------------------------------------

fn readAnimatedTestFixture() ![]const u8 {
    const file = std.fs.cwd().openFile("test/fixtures/loading.gif", .{}) catch {
        return error.SkipZigTest;
    };
    const stat = try file.stat();
    const buf = try testing.allocator.alloc(u8, stat.size);
    const n = try file.readAll(buf);
    file.close();
    return buf[0..n];
}

test "animated GIF passthrough produces output" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .gif;

    var result = try transform(data, p, "image/gif", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.gif, result.format);
    try testing.expect(result.is_animated);
}

test "animated GIF + anim=static produces single frame" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.anim = .static;
    p.format = .png;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expect(!result.is_animated);
    // Single frame: height should be 128 (one frame), not 1536 (stacked)
    try testing.expectEqual(@as(u32, 128), result.height);
}

test "animated GIF + frame=1 extracts second frame" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.frame = 1;
    p.format = .png;

    var result = try transform(data, p, null, null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expect(!result.is_animated);
    try testing.expectEqual(@as(u32, 128), result.width);
    try testing.expectEqual(@as(u32, 128), result.height);
}

test "animated GIF + f=webp produces animated webp" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .webp;

    var result = try transform(data, p, "image/webp", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.webp, result.format);
    try testing.expect(result.is_animated);
}

test "animated GIF + resize produces animated output" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.width = 64;
    p.format = .gif;

    var result = try transform(data, p, "image/gif", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.gif, result.format);
    try testing.expect(result.is_animated);
    try testing.expectEqual(@as(u32, 64), result.width);
}

test "animated gif resize preserves correct page-height for encoding" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    // Resize to non-trivial dimension — this is the path that caused
    // SIGSEGV before the page-height fix.
    var p = TransformParams{};
    p.width = 32;
    p.height = 32;
    p.format = .gif;

    var result = try transform(data, p, "image/gif", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.gif, result.format);
    try testing.expect(result.is_animated);
    try testing.expectEqual(@as(u32, 32), result.width);
}

test "animated gif with effects encodes without segfault" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    // Effects on animated images can corrupt frame boundaries.
    // The pre-encode validation in encodeImage should catch this.
    var p = TransformParams{};
    p.width = 64;
    p.sharpen = 1.5;
    p.format = .gif;

    var result = try transform(data, p, "image/gif", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.gif, result.format);
}

test "animated gif resize and blur encodes correctly" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.width = 48;
    p.blur = 1.0;
    p.format = .gif;

    var result = try transform(data, p, "image/gif", null);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expectEqual(OutputFormat.gif, result.format);
    try testing.expect(result.is_animated);
}

test "static image is not marked as animated" {
    testInit();
    const data = try readTestFixture();
    defer testing.allocator.free(data);

    var result = try transform(data, TransformParams{}, null, null);
    defer result.deinit();

    try testing.expect(!result.is_animated);
    try testing.expectEqual(@as(?u32, null), result.frame_count);
}

test "animated GIF over pixel budget falls back to static" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .gif;

    // Set a tiny pixel budget so the 128x128x12 image exceeds it
    const cfg = AnimConfig{ .max_animated_pixels = 1000, .max_frames = 100 };
    var result = try transform(data, p, "image/gif", cfg);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    // Should fall back to static because total pixels exceed budget
    try testing.expect(!result.is_animated);
    try testing.expectEqual(@as(u32, 128), result.height);
}

test "animated GIF with max_frames clamping" {
    testInit();
    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    var p = TransformParams{};
    p.format = .gif;

    // Allow only 3 frames out of 12
    const cfg = AnimConfig{ .max_frames = 3, .max_animated_pixels = 50_000_000 };
    var result = try transform(data, p, "image/gif", cfg);
    defer result.deinit();

    try testing.expect(result.data.len > 0);
    try testing.expect(result.is_animated);
    // Should still be animated but with clamped frame count
    try testing.expectEqual(@as(u32, 128), result.width);
}
