const std = @import("std");
const solver = @import("main.zig");

extern "env" fn report_progress(expanded: u32, queued: u32) void;

const allocator = std.heap.wasm_allocator;
var input: []u8 = &.{};
var solution: ?[]u8 = null;
var failure: []const u8 = "";

fn progress(expanded: u32, queued: u32) void {
    report_progress(expanded, queued);
}

export fn input_alloc(length: u32) usize {
    allocator.free(input);
    input = allocator.alloc(u8, length) catch {
        input = &.{};
        return 0;
    };
    return @intFromPtr(input.ptr);
}

// 0 = solved, 1 = proven unsolvable, 2 = resource limit, 3 = invalid map,
// 4 = allocation/other failure. The host owns each instance and may terminate it.
export fn solve_map(maze: u32, memory_mib: u32) u32 {
    if (solution) |path| allocator.free(path);
    solution = null;
    failure = "";
    // Whole MiB below 4 GiB keeps byte counts representable in wasm32 usize.
    if (memory_mib < 64 or memory_mib > 4095) {
        failure = "InvalidMemoryLimit";
        return 3;
    }
    report_progress(0, 0);
    const parsed = solver.parseMap(input, maze) catch |err| {
        failure = @errorName(err);
        return 3;
    };
    solution = solver.solveWithLimits(&parsed.grid, parsed.player, &parsed.boxes, allocator, .{ .progress = progress, .max_expanded = null, .max_stored = null, .memory_bytes = @as(usize, memory_mib) * 1024 * 1024 }) catch |err| {
        failure = @errorName(err);
        return switch (err) {
            error.ExpansionLimitReached, error.StoredStateLimitReached, error.MemoryLimitReached, error.OutOfMemory => 2,
            else => 4,
        };
    };
    return if (solution != null) 0 else 1;
}

export fn solution_ptr() usize {
    return if (solution) |path| (if (path.len == 0) 0 else @intFromPtr(path.ptr)) else 0;
}

export fn solution_len() usize {
    return if (solution) |path| path.len else 0;
}

export fn error_ptr() usize {
    return @intFromPtr(failure.ptr);
}

export fn error_len() usize {
    return failure.len;
}
