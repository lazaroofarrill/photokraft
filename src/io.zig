const std = @import("std");

pub fn readFile(file_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try std.fs.openFileAbsolute(file_name, .{});
    defer file.close();

    const info = try file.stat();

    try file.seekTo(0);

    const buffer = try file.readToEndAlloc(allocator, info.size);

    return buffer;
}

test "check vert.spv size" {
    const allocator = std.testing.allocator;

    const vert_spv_path = try std.fs.cwd().realpathAlloc(allocator, "src/shaders/vert.spv");
    defer allocator.free(vert_spv_path);

    const result = try readFile(vert_spv_path, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(result.len, 1504);
}

test "check frag.spv size" {
    const allocator = std.testing.allocator;

    const frag_spv_path = try std.fs.cwd().realpathAlloc(allocator, "src/shaders/frag.spv");
    defer allocator.free(frag_spv_path);

    const result = try readFile(frag_spv_path, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(result.len, 572);
}
