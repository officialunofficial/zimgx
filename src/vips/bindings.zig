// Vips C bindings
//
// Idiomatic Zig wrappers around the libvips C API for image loading,
// transformation, and encoding. Manages VipsImage lifecycle via
// ref-counted opaque handles.

const std = @import("std");
const testing = std.testing;

pub const c = @cImport({
    @cInclude("vips/vips.h");
});

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

pub const VipsError = error{
    InitFailed,
    LoadFailed,
    SaveFailed,
    ResizeFailed,
    OperationFailed,
};

// ---------------------------------------------------------------------------
// VipsImage wrapper
// ---------------------------------------------------------------------------

/// Opaque handle wrapping a `*c.VipsImage` with RAII-style lifecycle
/// management. When the handle is released via `unref()` the underlying
/// GObject reference count is decremented.
pub const VipsImage = struct {
    ptr: *c.VipsImage,

    /// Increment the GObject reference count.
    pub fn ref(self: VipsImage) VipsImage {
        _ = c.g_object_ref(@ptrCast(self.ptr));
        return self;
    }

    /// Decrement the GObject reference count, potentially freeing the image.
    pub fn unref(self: VipsImage) void {
        c.g_object_unref(@ptrCast(self.ptr));
    }
};

// ---------------------------------------------------------------------------
// Init / shutdown
// ---------------------------------------------------------------------------

/// Initialise the vips runtime. Must be called before any other vips
/// function. Returns `VipsError.InitFailed` on failure.
pub fn init() VipsError!void {
    if (c.vips_init("zimgx") != 0) {
        return VipsError.InitFailed;
    }
}

/// Shut down the vips runtime and free global resources.
pub fn shutdown() void {
    c.vips_shutdown();
}

// ---------------------------------------------------------------------------
// Image loading
// ---------------------------------------------------------------------------

/// Create a new VipsImage by decoding an in-memory buffer (any format
/// that libvips can detect: PNG, JPEG, WebP, AVIF, ...).
pub fn imageNewFromBuffer(data: []const u8) VipsError!VipsImage {
    const img: ?*c.VipsImage = c.vips_image_new_from_buffer(
        data.ptr,
        data.len,
        @as(?[*:0]const u8, null),
        @as(?*const u8, null),
    );
    if (img) |valid| {
        return VipsImage{ .ptr = valid };
    }
    return VipsError.LoadFailed;
}

/// Create a new VipsImage by decoding an in-memory buffer, loading ALL
/// frames of an animated image (GIF, animated WebP). The frames are
/// stacked vertically into a single tall image. Use `getNPages` and
/// `getPageHeight` to query the frame structure.
pub fn imageNewFromBufferAnimated(data: []const u8) VipsError!VipsImage {
    const img: ?*c.VipsImage = c.vips_image_new_from_buffer(
        data.ptr,
        data.len,
        @as(?[*:0]const u8, null),
        "n",
        @as(c_int, -1),
        @as(?*const u8, null),
    );
    if (img) |valid| {
        return VipsImage{ .ptr = valid };
    }
    return VipsError.LoadFailed;
}

/// Like `imageNewFromBufferAnimated` but limits the number of frames loaded.
pub fn imageNewFromBufferAnimatedN(data: []const u8, n_frames: c_int) VipsError!VipsImage {
    const img: ?*c.VipsImage = c.vips_image_new_from_buffer(
        data.ptr,
        data.len,
        @as(?[*:0]const u8, null),
        "n",
        n_frames,
        @as(?*const u8, null),
    );
    if (img) |valid| {
        return VipsImage{ .ptr = valid };
    }
    return VipsError.LoadFailed;
}

// ---------------------------------------------------------------------------
// Image info helpers
// ---------------------------------------------------------------------------

/// Return the image width in pixels.
pub fn getWidth(image: VipsImage) u32 {
    return @intCast(c.vips_image_get_width(image.ptr));
}

/// Return the image height in pixels.
pub fn getHeight(image: VipsImage) u32 {
    return @intCast(c.vips_image_get_height(image.ptr));
}

/// Return the number of bands (channels) in the image.
pub fn getBands(image: VipsImage) u32 {
    return @intCast(c.vips_image_get_bands(image.ptr));
}

/// Return true if the image has an alpha channel.
pub fn hasAlpha(image: VipsImage) bool {
    return c.vips_image_hasalpha(image.ptr) != 0;
}

/// Return the number of pages (frames) in an animated image, or null
/// if the `n-pages` metadata property is absent.
pub fn getNPages(image: VipsImage) ?u32 {
    var val: c_int = 0;
    const ret = c.vips_image_get_int(image.ptr, "n-pages", &val);
    if (ret != 0) return null;
    if (val < 1) return null;
    return @intCast(val);
}

/// Return the per-frame height of an animated image, or null if the
/// `page-height` metadata property is absent.
pub fn getPageHeight(image: VipsImage) ?u32 {
    var val: c_int = 0;
    const ret = c.vips_image_get_int(image.ptr, "page-height", &val);
    if (ret != 0) return null;
    if (val < 1) return null;
    return @intCast(val);
}

/// Set an integer metadata property on a VipsImage.
pub fn setInt(image: VipsImage, name: [*:0]const u8, value: c_int) void {
    c.vips_image_set_int(image.ptr, name, value);
}

// ---------------------------------------------------------------------------
// Thumbnail / resize
// ---------------------------------------------------------------------------

/// Options for `thumbnailImage`.
pub const ThumbnailOptions = struct {
    /// Target height. If null, libvips will auto-compute to preserve
    /// the aspect ratio.
    height: ?u32 = null,

    /// Crop mode — controls how the image is cropped when the target
    /// aspect ratio differs from the source.
    crop: ?c.VipsInteresting = null,

    /// Size constraint — controls whether the image is only shrunk,
    /// only enlarged, or forced to the exact target dimensions.
    size: ?c.VipsSize = null,
};

/// Resize an image to fit within `width` (and optionally `height`)
/// using vips_thumbnail_image. Returns a new VipsImage; the caller
/// owns the returned handle and must call `unref()` when done.
pub fn thumbnailImage(image: VipsImage, width: u32, options: ThumbnailOptions) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const c_width: c_int = @intCast(width);

    const ret: c_int = blk: {
        // Build the varargs call depending on which options are set.
        if (options.height != null and options.crop != null and options.size != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "height",
                @as(c_int, @intCast(options.height.?)),
                "crop",
                @as(c.VipsInteresting, options.crop.?),
                "size",
                @as(c.VipsSize, options.size.?),
                @as(?*const u8, null),
            );
        } else if (options.height != null and options.crop != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "height",
                @as(c_int, @intCast(options.height.?)),
                "crop",
                @as(c.VipsInteresting, options.crop.?),
                @as(?*const u8, null),
            );
        } else if (options.height != null and options.size != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "height",
                @as(c_int, @intCast(options.height.?)),
                "size",
                @as(c.VipsSize, options.size.?),
                @as(?*const u8, null),
            );
        } else if (options.height != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "height",
                @as(c_int, @intCast(options.height.?)),
                @as(?*const u8, null),
            );
        } else if (options.crop != null and options.size != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "crop",
                @as(c.VipsInteresting, options.crop.?),
                "size",
                @as(c.VipsSize, options.size.?),
                @as(?*const u8, null),
            );
        } else if (options.crop != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "crop",
                @as(c.VipsInteresting, options.crop.?),
                @as(?*const u8, null),
            );
        } else if (options.size != null) {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                "size",
                @as(c.VipsSize, options.size.?),
                @as(?*const u8, null),
            );
        } else {
            break :blk c.vips_thumbnail_image(
                image.ptr,
                &output,
                c_width,
                @as(?*const u8, null),
            );
        }
    };

    if (ret != 0) return VipsError.ResizeFailed;
    if (output) |valid| {
        return VipsImage{ .ptr = valid };
    }
    return VipsError.ResizeFailed;
}

// ---------------------------------------------------------------------------
// Save to buffer (format encoders)
// ---------------------------------------------------------------------------

/// Result of a save-to-buffer operation. The caller must free the
/// buffer via `gFree` when done.
pub const SaveBuffer = struct {
    data: []u8,

    pub fn free(self: SaveBuffer) void {
        gFree(self.data.ptr);
    }
};

/// Convert a vips operation's output pointer + return code into a VipsImage,
/// or return OperationFailed.
fn toVipsImage(ret: c_int, output: ?*c.VipsImage) VipsError!VipsImage {
    if (ret != 0) return VipsError.OperationFailed;
    const valid = output orelse return VipsError.OperationFailed;
    return VipsImage{ .ptr = valid };
}

/// Convert a raw vips save result (return code + nullable buffer) into
/// a SaveBuffer, or return SaveFailed.
fn toSaveBuffer(ret: c_int, buf: ?*anyopaque, len: usize) VipsError!SaveBuffer {
    if (ret != 0) return VipsError.SaveFailed;
    const valid = buf orelse return VipsError.SaveFailed;
    const ptr: [*]u8 = @ptrCast(valid);
    return SaveBuffer{ .data = ptr[0..len] };
}

/// Helper: convert bool to C int (1 or 0).
fn boolToInt(v: bool) c_int {
    return if (v) 1 else 0;
}

/// Encode image as JPEG into a heap-allocated buffer (strips metadata).
pub fn jpegsaveBuffer(image: VipsImage, quality: u32) VipsError!SaveBuffer {
    return jpegsaveBufferOpts(image, quality, true);
}

/// Encode image as JPEG with metadata control.
pub fn jpegsaveBufferOpts(image: VipsImage, quality: u32, do_strip: bool) VipsError!SaveBuffer {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    const ret = c.vips_jpegsave_buffer(image.ptr, @ptrCast(&buf), &len, "Q", @as(c_int, @intCast(quality)), "strip", boolToInt(do_strip), @as(?*const u8, null));
    return toSaveBuffer(ret, buf, len);
}

/// Encode image as PNG into a heap-allocated buffer (strips metadata).
pub fn pngsaveBuffer(image: VipsImage, compression: u32) VipsError!SaveBuffer {
    return pngsaveBufferOpts(image, compression, true);
}

/// Encode image as PNG with metadata control.
pub fn pngsaveBufferOpts(image: VipsImage, compression: u32, do_strip: bool) VipsError!SaveBuffer {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    const ret = c.vips_pngsave_buffer(image.ptr, @ptrCast(&buf), &len, "compression", @as(c_int, @intCast(compression)), "strip", boolToInt(do_strip), @as(?*const u8, null));
    return toSaveBuffer(ret, buf, len);
}

/// Encode image as WebP into a heap-allocated buffer (strips metadata).
pub fn webpsaveBuffer(image: VipsImage, quality: u32) VipsError!SaveBuffer {
    return webpsaveBufferOpts(image, quality, true);
}

/// Encode image as WebP with metadata control.
pub fn webpsaveBufferOpts(image: VipsImage, quality: u32, do_strip: bool) VipsError!SaveBuffer {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    const ret = c.vips_webpsave_buffer(image.ptr, @ptrCast(&buf), &len, "Q", @as(c_int, @intCast(quality)), "strip", boolToInt(do_strip), @as(?*const u8, null));
    return toSaveBuffer(ret, buf, len);
}

/// Encode image as AVIF (HEIF) into a heap-allocated buffer (strips metadata).
pub fn avifsaveBuffer(image: VipsImage, quality: u32) VipsError!SaveBuffer {
    return avifsaveBufferOpts(image, quality, true);
}

/// Encode image as AVIF with metadata control.
pub fn avifsaveBufferOpts(image: VipsImage, quality: u32, do_strip: bool) VipsError!SaveBuffer {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    const ret = c.vips_heifsave_buffer(image.ptr, @ptrCast(&buf), &len, "Q", @as(c_int, @intCast(quality)), "strip", boolToInt(do_strip), @as(?*const u8, null));
    return toSaveBuffer(ret, buf, len);
}

/// Encode image as GIF into a heap-allocated buffer.
/// GIF is palette-based so there is no quality parameter.
pub fn gifsaveBuffer(image: VipsImage) VipsError!SaveBuffer {
    var buf: ?*anyopaque = null;
    var len: usize = 0;
    const ret = c.vips_gifsave_buffer(image.ptr, @ptrCast(&buf), &len, @as(?*const u8, null));
    return toSaveBuffer(ret, buf, len);
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// Apply an unsharp mask (sharpen) with the given sigma. Returns a new
/// VipsImage owned by the caller.
pub fn sharpen(image: VipsImage, sigma: f64) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_sharpen(image.ptr, &output, "sigma", sigma, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Apply a gaussian blur with the given sigma. Returns a new VipsImage
/// owned by the caller.
pub fn gaussblur(image: VipsImage, sigma: f64) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_gaussblur(image.ptr, &output, sigma, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

// ---------------------------------------------------------------------------
// Rotation / flip
// ---------------------------------------------------------------------------

/// Rotate image by a multiple of 90 degrees. Returns a new VipsImage.
pub fn rot(image: VipsImage, angle: c.VipsAngle) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_rot(image.ptr, &output, angle, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Flip (mirror) an image horizontally or vertically.
pub fn flip(image: VipsImage, direction: c.VipsDirection) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_flip(image.ptr, &output, direction, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

// ---------------------------------------------------------------------------
// Color adjustments
// ---------------------------------------------------------------------------

/// Apply `out = in * a + b` to every pixel. Used for brightness/contrast.
pub fn linear1(image: VipsImage, a: f64, b_val: f64) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_linear1(image.ptr, &output, a, b_val, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Apply gamma correction with the given exponent.
pub fn gamma(image: VipsImage, exponent: f64) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_gamma(image.ptr, &output, "exponent", exponent, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Convert image to the given colorspace interpretation.
pub fn colourspace(image: VipsImage, space: c.VipsInterpretation) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_colourspace(image.ptr, &output, space, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Extract `n` bands starting at `band` from the image.
pub fn extractBand(image: VipsImage, band: c_int, n: c_int) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_extract_band(image.ptr, &output, band, "n", n, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Join two images band-wise (append bands of b after bands of a).
pub fn bandjoin2(a: VipsImage, b: VipsImage) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_bandjoin2(a.ptr, b.ptr, &output, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

// ---------------------------------------------------------------------------
// Background / padding
// ---------------------------------------------------------------------------

/// Flatten an image with alpha onto a background color.
/// `bg` is an RGB array: [3]f64 in range 0-255.
pub fn flatten(image: VipsImage, bg: [3]f64) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const bg_array = c.vips_array_double_new(&bg, 3);
    defer c.vips_area_unref(@ptrCast(bg_array));
    const ret = c.vips_flatten(image.ptr, &output, "background", bg_array, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

/// Embed (pad/letterbox) an image within a larger canvas.
/// Places the image at (x, y) within a (width x height) canvas,
/// filling the border with the given RGB background color.
/// Automatically extends to RGBA when the source image has alpha.
pub fn embed(image: VipsImage, x: c_int, y: c_int, width: c_int, height: c_int, bg: [3]f64) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;

    // RGBA images need a 4-element background array (with alpha = 255).
    const bg4 = [4]f64{ bg[0], bg[1], bg[2], 255.0 };
    const n_bands: c_int = if (getBands(image) >= 4) 4 else 3;
    const bg_array = c.vips_array_double_new(&bg4, n_bands);
    defer c.vips_area_unref(@ptrCast(bg_array));

    const ret = c.vips_embed(image.ptr, &output, x, y, width, height, "extend", @as(c_int, c.VIPS_EXTEND_BACKGROUND), "background", bg_array, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

// ---------------------------------------------------------------------------
// Trim
// ---------------------------------------------------------------------------

/// Find the bounding box of non-border pixels. Returns (left, top, width, height).
pub fn findTrim(image: VipsImage, threshold: f64) VipsError!struct { left: c_int, top: c_int, width: c_int, height: c_int } {
    var left: c_int = 0;
    var top: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;

    const ret = c.vips_find_trim(
        image.ptr,
        &left,
        &top,
        &width,
        &height,
        "threshold",
        threshold,
        @as(?*const u8, null),
    );

    if (ret != 0) return VipsError.OperationFailed;
    return .{ .left = left, .top = top, .width = width, .height = height };
}

/// Extract a rectangular sub-region from an image.
pub fn crop(image: VipsImage, left: c_int, top: c_int, width: c_int, height: c_int) VipsError!VipsImage {
    var output: ?*c.VipsImage = null;
    const ret = c.vips_extract_area(image.ptr, &output, left, top, width, height, @as(?*const u8, null));
    return toVipsImage(ret, output);
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

/// Return the current vips error buffer contents as a Zig slice.
/// The returned slice points into vips-managed memory and is only
/// valid until the next vips call or `vips_error_clear()`.
pub fn getVipsError() []const u8 {
    const ptr = c.vips_error_buffer();
    if (ptr == null) return "";
    return std.mem.span(ptr);
}

/// Clear the vips error buffer.
pub fn clearVipsError() void {
    c.vips_error_clear();
}

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

/// Free a buffer that was allocated by vips/glib (e.g. from a
/// save-to-buffer operation).
pub fn gFree(ptr: ?*anyopaque) void {
    c.g_free(ptr);
}

// ===========================================================================
// Tests
// ===========================================================================

/// Read the test fixture PNG at runtime. The path is resolved relative to
/// the workspace root using the build-system's source root marker.
fn readTestFixture() ![]const u8 {
    // When tests run, the cwd is the project root.
    const file = std.fs.cwd().openFile("test/fixtures/test_4x4.png", .{}) catch {
        // If CWD isn't project root, try absolute path as fallback.
        const f = try std.fs.openFileAbsolute(
            "/Users/christopherw/Workspaces/officialunofficial/zimg/test/fixtures/test_4x4.png",
            .{},
        );
        const stat = try f.stat();
        const buf = try testing.allocator.alloc(u8, stat.size);
        const n = try f.readAll(buf);
        f.close();
        return buf[0..n];
    };
    const stat = try file.stat();
    const buf = try testing.allocator.alloc(u8, stat.size);
    const n = try file.readAll(buf);
    file.close();
    return buf[0..n];
}

/// Helper: initialise vips for a test exactly once. Calling vips_init
/// multiple times is safe (it returns immediately after the first
/// successful call), but calling vips_shutdown() invalidates global
/// GLib state that cannot be re-created, so we never call shutdown in
/// tests.
var test_vips_inited: bool = false;

fn testInit() void {
    if (!test_vips_inited) {
        init() catch @panic("vips init failed in test setup");
        test_vips_inited = true;
    }
}

test "vips init and shutdown" {
    // vips_init is idempotent; vips_shutdown must only be called once at
    // program exit and cannot be called here because it would invalidate
    // GLib global state for all subsequent tests.
    try init();
    // Verify a second init is harmless.
    try init();
}

test "load image from buffer" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    try testing.expectEqual(@as(u32, 4), getWidth(img));
    try testing.expectEqual(@as(u32, 4), getHeight(img));
}

test "get image dimensions" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    try testing.expectEqual(@as(u32, 4), getWidth(img));
    try testing.expectEqual(@as(u32, 4), getHeight(img));
    try testing.expect(getBands(img) >= 3);
}

test "has alpha detection" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    // The test fixture is RGBA, so it should have an alpha channel.
    try testing.expect(hasAlpha(img));
    try testing.expectEqual(@as(u32, 4), getBands(img));
}

test "thumbnail resize" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const thumb = try thumbnailImage(img, 2, .{ .height = 2, .size = c.VIPS_SIZE_FORCE });
    defer thumb.unref();

    try testing.expectEqual(@as(u32, 2), getWidth(thumb));
    try testing.expectEqual(@as(u32, 2), getHeight(thumb));
}

test "save to jpeg buffer" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const result = try jpegsaveBuffer(img, 80);
    defer result.free();

    try testing.expect(result.data.len > 0);
}

test "save to png buffer" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const result = try pngsaveBuffer(img, 6);
    defer result.free();

    try testing.expect(result.data.len > 0);
}

test "save to webp buffer" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const result = try webpsaveBuffer(img, 80);
    defer result.free();

    try testing.expect(result.data.len > 0);
}

test "error on invalid buffer" {
    testInit();

    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03 };
    const result = imageNewFromBuffer(&garbage);
    try testing.expectError(VipsError.LoadFailed, result);

    // The error buffer should contain a message after a failed load.
    const err = getVipsError();
    try testing.expect(err.len > 0);
    clearVipsError();
}

test "sharpen produces valid image" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const sharpened = try sharpen(img, 1.0);
    defer sharpened.unref();

    try testing.expectEqual(getWidth(img), getWidth(sharpened));
    try testing.expectEqual(getHeight(img), getHeight(sharpened));
}

test "gaussblur produces valid image" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const blurred = try gaussblur(img, 1.0);
    defer blurred.unref();

    try testing.expectEqual(getWidth(img), getWidth(blurred));
    try testing.expectEqual(getHeight(img), getHeight(blurred));
}

test "ref and unref lifecycle" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);

    // Ref increments the count; we can unref twice without crash.
    const img2 = img.ref();
    img.unref();
    // img2 still valid because of the extra ref.
    try testing.expectEqual(@as(u32, 4), getWidth(img2));
    img2.unref();
}

test "thumbnail with crop option" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const thumb = try thumbnailImage(img, 2, .{
        .height = 2,
        .crop = c.VIPS_INTERESTING_CENTRE,
        .size = c.VIPS_SIZE_FORCE,
    });
    defer thumb.unref();

    try testing.expectEqual(@as(u32, 2), getWidth(thumb));
    try testing.expectEqual(@as(u32, 2), getHeight(thumb));
}

test "save to avif buffer" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    // AVIF/HEIF support depends on the libvips build. Skip if the
    // encoder is unavailable (e.g. Ubuntu's default libvips package).
    const result = avifsaveBuffer(img, 50) catch |err| switch (err) {
        VipsError.SaveFailed => {
            clearVipsError();
            return;
        },
        else => return err,
    };
    defer result.free();

    try testing.expect(result.data.len > 0);
}

// ---------------------------------------------------------------------------
// Animated image tests
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

test "imageNewFromBufferAnimated loads stacked frames" {
    testInit();

    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    const img = try imageNewFromBufferAnimated(data);
    defer img.unref();

    // 12 frames of 128x128 stacked vertically → 128 wide, 1536 tall
    try testing.expectEqual(@as(u32, 128), getWidth(img));
    try testing.expectEqual(@as(u32, 1536), getHeight(img));
}

test "getNPages returns frame count for animated image" {
    testInit();

    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    const img = try imageNewFromBufferAnimated(data);
    defer img.unref();

    try testing.expectEqual(@as(?u32, 12), getNPages(img));
}

test "getNPages returns null or 1 for static image" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const pages = getNPages(img);
    // Static PNG: either null or 1
    if (pages) |p| {
        try testing.expectEqual(@as(u32, 1), p);
    }
}

test "getPageHeight returns per-frame height for animated image" {
    testInit();

    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    const img = try imageNewFromBufferAnimated(data);
    defer img.unref();

    try testing.expectEqual(@as(?u32, 128), getPageHeight(img));
}

test "gifsaveBuffer round-trips animated image" {
    testInit();

    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    const img = try imageNewFromBufferAnimated(data);
    defer img.unref();

    const result = try gifsaveBuffer(img);
    defer result.free();

    try testing.expect(result.data.len > 0);

    // Verify the saved data can be loaded back as animated
    const reloaded = try imageNewFromBufferAnimated(result.data);
    defer reloaded.unref();

    try testing.expectEqual(@as(?u32, 12), getNPages(reloaded));
}

test "setInt and read back integer metadata" {
    testInit();

    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    const img = try imageNewFromBufferAnimated(data);
    defer img.unref();

    // Overwrite n-pages with a new value and read it back
    setInt(img, "n-pages", 7);
    try testing.expectEqual(@as(?u32, 7), getNPages(img));

    // Overwrite page-height and read it back
    setInt(img, "page-height", 42);
    try testing.expectEqual(@as(?u32, 42), getPageHeight(img));
}

test "gifsaveBuffer with corrected page-height after resize" {
    testInit();

    const data = readAnimatedTestFixture() catch return;
    defer testing.allocator.free(data);

    const img = try imageNewFromBufferAnimated(data);

    // Resize the stacked image — this makes page-height stale
    const resized = try thumbnailImage(img, 64, .{});
    img.unref();

    // Manually fix page-height (simulates what pipeline does)
    const new_height = getHeight(resized);
    const pages = getNPages(resized) orelse 1;
    const new_page_height: c_int = @intCast(new_height / pages);
    setInt(resized, "page-height", new_page_height);

    // Encoding should succeed without SIGSEGV
    const result = try gifsaveBuffer(resized);
    defer result.free();
    resized.unref();

    try testing.expect(result.data.len > 0);

    // Verify round-trip: reload and check frame count preserved
    const reloaded = try imageNewFromBufferAnimated(result.data);
    defer reloaded.unref();
    try testing.expectEqual(@as(?u32, 12), getNPages(reloaded));
}

test "gifsaveBuffer saves static image as gif" {
    testInit();

    const data = try readTestFixture();
    defer testing.allocator.free(data);

    const img = try imageNewFromBuffer(data);
    defer img.unref();

    const result = try gifsaveBuffer(img);
    defer result.free();

    try testing.expect(result.data.len > 0);
}
