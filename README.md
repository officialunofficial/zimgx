# zimgx

A fast, single-binary image proxy and transform server. Fetches images from an HTTP or Cloudflare R2 origin, applies real-time resizing/format conversion/effects via [libvips](https://www.libvips.org/), and serves the result with caching, ETag support, and automatic content negotiation.

Built with [Zig](https://ziglang.org/) and libvips. Runs as a single static binary with no runtime dependencies beyond libvips.

## Quick Start

### Docker (recommended)

```sh
docker run -p 8080:8080 \
  -e ZIMGX_ORIGIN_BASE_URL=https://your-image-origin.com \
  ghcr.io/officialunofficial/zimgx:latest
```

### Build from source

Requires Zig 0.15+ and libvips 8.18+.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zimgx
```

## URL Format

```
GET /<image-path>/<transforms>
```

The last path segment is treated as a transform string when it contains `=`. Transform parameters are comma-separated `key=value` pairs.

### Examples

```
# Resize to 400px wide, auto-negotiate format
/photos/hero.jpg/w=400

# Resize to 800x600, convert to WebP at quality 85
/photos/hero.jpg/w=800,h=600,f=webp,q=85

# Cover crop with smart gravity, 2x DPR
/photos/hero.jpg/w=400,h=400,fit=cover,g=smart,dpr=2

# Apply blur effect
/photos/hero.jpg/blur=3.0

# Animated GIF resized, preserved as animated WebP
/photos/spinner.gif/w=64

# Extract frame 0 as static PNG
/photos/spinner.gif/frame=0,f=png

# Strip animation, serve first frame only
/photos/spinner.gif/anim=false

# Original image, no transforms
/photos/hero.jpg
```

## Transform Parameters

| Param | Description | Values | Default |
|-------|-------------|--------|---------|
| `w` | Width (px) | 1-8192 | - |
| `h` | Height (px) | 1-8192 | - |
| `q` | Quality | 1-100 | 80 |
| `f` | Output format | `jpeg`, `png`, `webp`, `avif`, `gif`, `auto` | auto (negotiated) |
| `fit` | Resize mode | `contain`, `cover`, `fill`, `inside`, `outside` | `contain` |
| `g` | Crop gravity | `center`, `north`, `south`, `east`, `west`, `ne`, `nw`, `se`, `sw`, `smart`, `attention` | `center` |
| `sharpen` | Sharpen sigma | 0.0-10.0 | - |
| `blur` | Gaussian blur sigma | 0.1-250.0 | - |
| `dpr` | Device pixel ratio | 1.0-5.0 | 1.0 |
| `anim` | Animation mode | `true`, `false`, `auto`, `static`, `animate` | `auto` (`true`) |
| `frame` | Extract single frame | 0-999 | - |

See [docs/transforms.md](docs/transforms.md) for full details.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ZIMGX_SERVER_PORT` | Listen port | `8080` |
| `ZIMGX_SERVER_HOST` | Bind address | `0.0.0.0` |
| `ZIMGX_ORIGIN_TYPE` | Origin backend | `http` |
| `ZIMGX_ORIGIN_BASE_URL` | HTTP origin base URL | `http://localhost:9000` |
| `ZIMGX_CACHE_ENABLED` | Enable in-memory cache | `true` |
| `ZIMGX_CACHE_MAX_SIZE_BYTES` | Max cache size | `536870912` (512MB) |
| `ZIMGX_R2_ENDPOINT` | R2/S3 endpoint URL | - |
| `ZIMGX_R2_ACCESS_KEY_ID` | R2/S3 access key | - |
| `ZIMGX_R2_SECRET_ACCESS_KEY` | R2/S3 secret key | - |

See [docs/configuration.md](docs/configuration.md) for the full reference.

## Endpoints

| Path | Description |
|------|-------------|
| `GET /health` | Health check &mdash; `{"status":"ok"}` |
| `GET /ready` | Readiness probe &mdash; `{"ready":true}` |
| `GET /metrics` | Server stats (requests, cache hits/misses, uptime) |
| `GET /<path>` | Image request (with optional transforms) |

## Architecture

```
                    Request
                      │
                ┌─────▼─────┐
                │   Router   │
                └─────┬─────┘
                      │
              ┌───────▼───────┐
              │  Cache Lookup │
              │  (L1 Memory)  │
              └───────┬───────┘
                  hit/│\miss
                 ┌────┘ └────┐
                 │           │
                 ▼      ┌────▼────┐
              Respond   │ L2 R2   │ (optional)
                        │ Cache   │
                        └────┬────┘
                         hit/│\miss
                        ┌────┘ └────┐
                        │           │
                        ▼      ┌────▼─────┐
                     Respond   │  Origin   │
                               │ (HTTP/R2) │
                               └────┬──────┘
                                    │
                             ┌──────▼──────┐
                             │  Transform  │
                             │  Pipeline   │
                             │ (libvips)   │
                             └──────┬──────┘
                                    │
                              ┌─────▼─────┐
                              │   Cache    │
                              │   Store    │
                              └─────┬─────┘
                                    │
                                 Respond
```

See [docs/architecture.md](docs/architecture.md) for full details.

## Performance

Transform pipeline throughput on Apple M-series, 2000x1500 PNG source, `ReleaseFast`:

| Scenario | Ops/s | Latency | Output |
|----------|------:|--------:|-------:|
| Resize 800x600 JPEG | 175 | 5.7 ms | 17 KB |
| Resize 800x600 WebP | 59 | 16.9 ms | 4 KB |
| Resize 800x600 AVIF | 10 | 101 ms | 57 KB |
| Resize 800x600 PNG | 86 | 11.6 ms | 216 KB |
| Resize 400x300 WebP | 116 | 8.7 ms | 1 KB |
| Thumbnail 200x150 WebP | 160 | 6.2 ms | <1 KB |
| Cover crop 800x600 | 165 | 6.1 ms | 17 KB |
| Resize + sharpen | 113 | 8.9 ms | 17 KB |
| Resize + blur | 146 | 6.9 ms | 18 KB |

Cache hits are served in sub-millisecond time (no transform, memory lookup only).

Run benchmarks locally with `zig build bench`.

## Documentation

- [Configuration Reference](docs/configuration.md) &mdash; all `ZIMGX_*` environment variables
- [Transform Parameters](docs/transforms.md) &mdash; resize, format, effects
- [Deployment Guide](docs/deployment.md) &mdash; Docker, Compose, health checks
- [Architecture](docs/architecture.md) &mdash; system design, module map, caching

## License

MIT
