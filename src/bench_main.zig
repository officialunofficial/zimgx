// Pipeline microbenchmark
//
// Measures transform throughput for realistic image operations.
// Run with: zig build bench
//
// Reports ops/sec and avg latency for each scenario.

const std = @import("std");
const pipeline = @import("transform/pipeline.zig");
const params_mod = @import("transform/params.zig");
const bindings = @import("vips/bindings.zig");
const TransformParams = params_mod.TransformParams;
const OutputFormat = params_mod.OutputFormat;

const Scenario = struct {
    name: []const u8,
    params: TransformParams,
    accept: ?[]const u8,
};

const scenarios = [_]Scenario{
    .{
        .name = "passthrough (no resize)",
        .params = .{},
        .accept = null,
    },
    .{
        .name = "resize 800x600 JPEG",
        .params = .{ .width = 800, .height = 600, .format = .jpeg, .quality = 80 },
        .accept = null,
    },
    .{
        .name = "resize 800x600 WebP",
        .params = .{ .width = 800, .height = 600, .format = .webp, .quality = 80 },
        .accept = null,
    },
    .{
        .name = "resize 800x600 AVIF",
        .params = .{ .width = 800, .height = 600, .format = .avif, .quality = 80 },
        .accept = null,
    },
    .{
        .name = "resize 800x600 PNG",
        .params = .{ .width = 800, .height = 600, .format = .png },
        .accept = null,
    },
    .{
        .name = "resize 400x300 WebP q=60",
        .params = .{ .width = 400, .height = 300, .format = .webp, .quality = 60 },
        .accept = null,
    },
    .{
        .name = "resize 200x150 WebP (thumbnail)",
        .params = .{ .width = 200, .height = 150, .format = .webp, .quality = 80 },
        .accept = null,
    },
    .{
        .name = "resize 800x600 cover crop",
        .params = .{ .width = 800, .height = 600, .fit = .cover, .format = .jpeg, .quality = 80 },
        .accept = null,
    },
    .{
        .name = "resize 800x600 + sharpen",
        .params = .{ .width = 800, .height = 600, .format = .jpeg, .quality = 80, .sharpen = 1.5 },
        .accept = null,
    },
    .{
        .name = "resize 800x600 + blur",
        .params = .{ .width = 800, .height = 600, .format = .jpeg, .quality = 80, .blur = 3.0 },
        .accept = null,
    },
    .{
        .name = "auto format (Accept: webp)",
        .params = .{ .width = 800, .height = 600, .format = .auto },
        .accept = "image/webp",
    },
    .{
        .name = "auto format (Accept: avif,webp)",
        .params = .{ .width = 800, .height = 600, .format = .auto },
        .accept = "image/avif,image/webp",
    },
    .{
        .name = "2x DPR (400 logical = 800 actual)",
        .params = .{ .width = 400, .height = 300, .dpr = 2.0, .format = .webp, .quality = 80 },
        .accept = null,
    },
};

fn writeAll(bytes: []const u8) void {
    const file = std.fs.File.stdout();
    file.writeAll(bytes) catch {};
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(s);
}

pub fn main() !void {
    // Init vips
    bindings.init() catch {
        print("Error: failed to initialize libvips\n", .{});
        return;
    };

    // Load test image
    const image_data = blk: {
        const file = std.fs.cwd().openFile("test/fixtures/bench_2000x1500.png", .{}) catch {
            print("Error: could not read test/fixtures/bench_2000x1500.png\n", .{});
            print("Run from the project root directory.\n", .{});
            return;
        };
        defer file.close();
        const stat = try file.stat();
        const buf = try std.heap.page_allocator.alloc(u8, stat.size);
        const n = try file.readAll(buf);
        break :blk buf[0..n];
    };
    defer std.heap.page_allocator.free(image_data);

    print("\n", .{});
    print("zimgx pipeline benchmark\n", .{});
    print("========================\n", .{});
    print("Source: 2000x1500 RGB PNG ({d} KB)\n\n", .{image_data.len / 1024});
    print("{s:<42} {s:>8} {s:>10} {s:>10} {s:>10}\n", .{ "Scenario", "Ops/s", "Avg (ms)", "Min (ms)", "Output" });
    print("{s:<42} {s:>8} {s:>10} {s:>10} {s:>10}\n", .{
        "──────────────────────────────────────────",
        "────────",
        "──────────",
        "──────────",
        "──────────",
    });

    // Warmup
    {
        const warmup_params = TransformParams{ .width = 800, .height = 600, .format = .jpeg, .quality = 80 };
        var result = pipeline.transform(image_data, warmup_params, null, null) catch {
            print("Error: warmup transform failed\n", .{});
            return;
        };
        result.deinit();
    }

    for (scenarios) |scenario| {
        const iterations: u32 = 20;
        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var last_size: usize = 0;
        var failed = false;

        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            var result = pipeline.transform(image_data, scenario.params, scenario.accept, null) catch {
                print("{s:<42} FAILED\n", .{scenario.name});
                failed = true;
                break;
            };
            const end = std.time.nanoTimestamp();
            const elapsed: u64 = @intCast(end - start);
            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            last_size = result.data.len;
            result.deinit();
        }

        if (!failed) {
            const avg_ms = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
            const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
            const ops_per_sec = if (avg_ms > 0) 1000.0 / avg_ms else 0;
            const size_kb = last_size / 1024;

            print("{s:<42} {d:>8.1} {d:>10.2} {d:>10.2} {d:>7} KB\n", .{
                scenario.name,
                ops_per_sec,
                avg_ms,
                min_ms,
                size_kb,
            });
        }
    }

    print("\n", .{});
}
