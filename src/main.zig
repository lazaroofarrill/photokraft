const std = @import("std");
const c = @import("c.zig").c;
const vulkan = @import("vulkan.zig");

const GlfwError = error.GlfwError;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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

    var app = try vulkan.App.create(allocator, window orelse unreachable);
    defer app.destroy(allocator);
    defer _ = c.vkDeviceWaitIdle(app.logical_device);

    c.glfwSetWindowUserPointer(window, &app);
    _ = c.glfwSetFramebufferSizeCallback(window, frameBufferResizeCallback);

    while (c.glfwWindowShouldClose(window) == 0) {
        c.glfwPollEvents();

        try app.drawFrame(window orelse unreachable, allocator);
    }
}

fn frameBufferResizeCallback(
    window: ?*c.GLFWwindow,
    width: c_int,
    height: c_int,
) callconv(.C) void {
    _ = width;
    _ = height;

    var app: *vulkan.App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(
        window,
    )));
    app.frameBufferResized = true;
}
