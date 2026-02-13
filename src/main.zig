const std = @import("std");
const server = @import("server.zig");
const vips = @import("vips/bindings.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize libvips before starting the server.
    try vips.init();
    defer vips.shutdown();

    try server.run(allocator);
}

test {
    // Import all modules so `zig build test` discovers their tests.
    // Modules that require cross-directory named imports (http/*) are
    // tested as standalone test roots via build.zig and excluded here
    // to avoid Zig's one-file-per-module constraint.
    _ = @import("transform/params.zig");
    _ = @import("transform/negotiate.zig");
    _ = @import("transform/pipeline.zig");
    _ = @import("router.zig");
    _ = @import("config.zig");
    _ = @import("http/response.zig");
    _ = @import("http/errors.zig");
    _ = @import("cache/cache.zig");
    _ = @import("cache/memory.zig");
    _ = @import("cache/noop.zig");
    _ = @import("vips/bindings.zig");
    _ = @import("origin/fetcher.zig");
    _ = @import("origin/source.zig");
    _ = @import("origin/r2.zig");
    _ = @import("s3/signing.zig");
    _ = @import("s3/client.zig");
    _ = @import("cache/r2.zig");
    _ = @import("cache/tiered.zig");
    _ = @import("allocator.zig");
    _ = @import("server.zig");
}
