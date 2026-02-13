# Animated Image Support (GIF / Animated WebP)

## Architecture

libvips represents animated images as a single tall image with all frames
stacked vertically. Metadata properties (n-pages, page-height, delay, loop)
describe the frame structure. Resizing, effects, and encoding all operate on
the stacked image — no per-frame iteration in Zig.

---

## Step 1 — OutputFormat.gif + gifsaveBuffer binding

### vips/bindings.zig
- Add `gifsaveBuffer(image: VipsImage) -> VipsError!SaveBuffer`
  - Calls `vips_gifsave_buffer(image.ptr, &buf, &len, null)`
  - GIF has no meaningful quality knob (palette-based), so no quality param

### transform/params.zig
- Add `.gif` variant to `OutputFormat` enum
- `contentType()` → `"image/gif"`
- `extension()` → `"gif"`
- `fromString("gif")` → `.gif`
- `toString()` → `"gif"`

### transform/pipeline.zig
- Add `.gif => bindings.gifsaveBuffer(image)` to `encodeImage`

### transform/negotiate.zig
- Add `supports_gif: bool` to `AcceptResult`
- Parse `image/gif` in `parseAcceptHeader`
- No change to negotiation priority yet (gif not auto-selected as output)

---

## Step 2 — Animated loading + metadata readers

### vips/bindings.zig
- Add `imageNewFromBufferAnimated(data: []const u8) -> VipsError!VipsImage`
  - Calls `vips_image_new_from_buffer(ptr, len, null, "n", @as(c_int, -1), null)`
  - Loads all pages/frames as a vertically-stacked image

- Add metadata readers (return null when property absent):
  - `getNPages(image) -> ?u32`
    — `vips_image_get_int(img.ptr, "n-pages", &val)`
  - `getPageHeight(image) -> ?u32`
    — `vips_image_get_int(img.ptr, "page-height", &val)`
  - `getLoop(image) -> ?i32`
    — `vips_image_get_int(img.ptr, "loop", &val)`

- Delay array not needed yet (libvips preserves it through transforms
  automatically via the stacked image metadata).

---

## Step 3 — AnimMode + frame param in TransformParams

### transform/params.zig
- Add `AnimMode` enum: `auto`, `static`, `animate`
  - `auto`    — preserve animation when input is animated AND output supports it
  - `static`  — always strip animation, serve first frame
  - `animate` — require animated output; if output format can't, return error

- Add to `TransformParams`:
  - `anim: AnimMode = .auto`
  - `frame: ?u32 = null`   (extract single 0-indexed frame)

- Parse keys: `anim=auto|static|animate`, `frame=N`
- Validation: `frame` value validated against actual n-pages in pipeline, not here
- Update `toCacheKey` to include `anim` (when != .auto) and `frame` (when != null)

---

## Step 4 — Animation-aware pipeline

### transform/pipeline.zig

Replace the single `transform()` flow with animation detection:

```
1. PROBE    — imageNewFromBuffer (loads first frame only, cheap)
             read getNPages → is_animated = (n_pages > 1)

2. DECIDE   — based on (is_animated, anim mode, output format):
             - not animated → proceed as today (static path, no change)
             - animated + anim=static → proceed as today (first frame already loaded)
             - animated + frame=N → reload not needed, extract frame N via vips_crop
             - animated + anim=auto/animate → need all frames

3. RELOAD   — if all frames needed: unref probe image,
             call imageNewFromBufferAnimated (loads stacked image)

4. EXTRACT  — if frame=N: vips_crop(img, 0, N*page_height, width, page_height)
             then treat as static from here

5. RESIZE   — vips_thumbnail_image on stacked image
             libvips automatically respects page-height and resizes each frame

6. EFFECTS  — sharpen/blur on stacked image (applies to all frames)

7. ENCODE   — for animated output: gifsaveBuffer or webpsaveBuffer
             libvips reads the stacked metadata and produces animated output
             for static output: standard encode path
```

### New binding needed
- `crop(image, left, top, width, height) -> VipsError!VipsImage`
  — wraps `vips_crop()`, used for single-frame extraction

### TransformResult changes
- Add `is_animated: bool = false`
- Add `frame_count: ?u32 = null`

---

## Step 5 — Animated WebP output

### vips/bindings.zig
- Modify `webpsaveBuffer` or add `webpsaveBufferAnimated`:
  - When saving a stacked animated image, libvips automatically produces
    animated WebP as long as the page-height metadata is present
  - The existing `webpsaveBuffer` may already work — test first
  - If not, pass `"min_size", @as(c_int, 1)` for better compression

This may be a no-op if libvips auto-detects the stacked format. Verify
with a test before adding a separate function.

---

## Step 6 — Format negotiation for animated sources

### transform/negotiate.zig
- Add `negotiateAnimatedFormat()` or extend `negotiateFormat` with an
  `is_animated: bool` parameter

- When `is_animated = true` and `anim != .static`:
  Priority: animated WebP > GIF > static fallback
  - If Accept includes `image/webp` → `.webp` (animated)
  - Else if Accept includes `image/gif` → `.gif`
  - Else → fall back to static first-frame in best static format

- When `is_animated = false` or `anim = .static`:
  Use existing negotiation (no change)

### Pipeline integration
- After PROBE/DECIDE, pass `is_animated` to format negotiation
- This determines whether encode uses animated or static path

---

## Step 7 — Config + safety limits

### config.zig
- Add to `TransformConfig`:
  - `max_frames: u32 = 100`
  - `max_animated_pixels: u64 = 100_000_000`  (w × h × n_frames)

- Env vars: `ZIMG_TRANSFORM_MAX_FRAMES`, `ZIMG_TRANSFORM_MAX_ANIMATED_PIXELS`

### Pipeline enforcement (in step 4 DECIDE phase)
- If n_pages > max_frames: truncate by loading with `"n", max_frames` instead of -1
- If (width × page_height × n_pages) > max_animated_pixels: fall back to static
- Return appropriate error or degrade gracefully to static

---

## Step 8 — Tests + fixture

### Test fixture
- Add `test/fixtures/test_animated.gif` — small animated GIF (e.g. 4x4, 3 frames)
- Generate with ImageMagick:
  `convert -size 4x4 xc:red xc:green xc:blue -loop 0 -delay 10 test_animated.gif`

### Unit tests — vips/bindings.zig
- Load animated GIF → getNPages returns 3
- Load animated GIF → getPageHeight returns 4
- Load static PNG → getNPages returns null or 1
- gifsaveBuffer round-trips an image
- imageNewFromBufferAnimated loads stacked image (height = 4 × 3 = 12)

### Unit tests — transform/params.zig
- Parse `anim=static` → AnimMode.static
- Parse `frame=2` → frame = 2
- Cache key includes anim/frame when set
- Invalid anim value returns ParseError

### Unit tests — transform/pipeline.zig
- Animated GIF passthrough (no resize) → output is animated GIF
- Animated GIF + resize → output is smaller animated GIF
- Animated GIF + anim=static → output is static single frame
- Animated GIF + frame=1 → output is static second frame
- Animated GIF + f=webp → output is animated WebP
- Static PNG + anim=animate → degrades gracefully (static output)

### Unit tests — transform/negotiate.zig
- Animated source + Accept: image/webp → webp (animated)
- Animated source + Accept: image/gif → gif
- Animated source + Accept: image/jpeg → jpeg (static fallback)
- Animated source + anim=static → uses standard static negotiation

---

## API surface when complete

```
GET /photos/funny.gif                          → animated GIF (passthrough)
GET /photos/funny.gif?w=400                    → resized animated GIF
GET /photos/funny.gif?w=400&f=webp             → resized animated WebP
GET /photos/funny.gif?anim=static              → first frame as static image
GET /photos/funny.gif?anim=static&f=jpeg       → first frame as JPEG
GET /photos/funny.gif?frame=3                  → frame 3 as static image
GET /photos/funny.gif?w=400 + Accept: webp     → auto-converts to animated WebP
```

Animated WebP input works identically to GIF input.

---

## Out of scope

- APNG (libvips doesn't encode it)
- Frame-rate manipulation (speed up/slow down)
- Frame range extraction (just single frame or all)
- Animated AVIF (libvips support immature)
- Compositing/overlay on animated sources
