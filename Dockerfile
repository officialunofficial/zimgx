# --- Build stage ---
FROM alpine:edge AS build

ARG TARGETARCH

RUN apk add --no-cache zig vips-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY test/ test/

RUN if [ "$TARGETARCH" = "arm64" ]; then \
      ZIG_TARGET="aarch64-linux-musl"; \
    else \
      ZIG_TARGET="x86_64-linux-musl"; \
    fi && \
    zig build -Doptimize=ReleaseSafe -Dtarget=$ZIG_TARGET -Dcpu=baseline

# --- Runtime stage ---
FROM alpine:edge

RUN apk add --no-cache vips

COPY --from=build /app/zig-out/bin/zimgx /usr/local/bin/zimgx

EXPOSE 8080

ENTRYPOINT ["zimgx"]
