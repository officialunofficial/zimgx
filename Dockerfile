# --- Build stage ---
FROM alpine:edge AS build

RUN apk add --no-cache zig vips-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY test/ test/

RUN zig build -Doptimize=ReleaseSafe -Dcpu=baseline

# --- Runtime stage ---
FROM alpine:edge

RUN apk add --no-cache vips

COPY --from=build /app/zig-out/bin/zimgx /usr/local/bin/zimgx

EXPOSE 8080

ENTRYPOINT ["zimgx"]
