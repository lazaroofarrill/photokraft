const std = @import("std");

const Box = struct { x: u32, y: u32, w: u32, h: u32 };

const View = struct {
    children: []const View,
};

test "expect children to allow anything" {
    const root = View{
        .children = &[_]View{},
    };
    std.debug.print("children {any}\n", .{root.children});

    try std.testing.expectEqual(1, 1);
}
