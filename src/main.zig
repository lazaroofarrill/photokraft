const std = @import("std");
const c = @import("c.zig").c;
const vulkan = @import("vulkan.zig");

const GlfwError = error.GlfwError;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var err = c.glfwInit();
    if (err < 0) {
        return GlfwError;
    }
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(800, 600, "VK Window", null, null);
    defer c.glfwDestroyWindow(window);

    var extension_count: u32 = 0;
    err = c.vkEnumerateInstanceExtensionProperties(
        null,
        &extension_count,
        null,
    );
    if (err < 0) {
        return GlfwError;
    }

    var app = try vulkan.createApp(allocator);
    defer app.cleanup();

    if (!try vulkan.checkValidationSupport(allocator)) {
        std.debug.print("Not supported\n", .{});
    }

    try app.pickPhysicalDevice(allocator);

    while (c.glfwWindowShouldClose(window) == 0) {
        c.glfwPollEvents();
    }
}
