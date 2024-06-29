const std = @import("std");
const c = @import("c.zig").c;

pub const App = struct {
    instance: c.VkInstance = null,
    pub fn cleanup(self: *App) void {
        c.vkDestroyInstance(self.instance, null);
    }
};

pub fn createApp(allocator: std.mem.Allocator) !App {
    const application_info: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Vulkan app",
        .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "No Engine",
        .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_0,
        .pNext = null,
    };

    var glfw_extensions_count: u32 = 0;
    const glfw_extensions = c.glfwGetRequiredInstanceExtensions(
        &glfw_extensions_count,
    );

    const extensions = try allocator.alloc([*:0]const u8, glfw_extensions_count + 1);
    errdefer allocator.free(extensions);

    for (0..glfw_extensions_count) |i| {
        extensions[i] = glfw_extensions[i];
    }
    extensions[glfw_extensions_count] = c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    glfw_extensions_count += 1;

    for (extensions) |ext| {
        std.debug.print("enabled extension: [{s}]\n", .{ext});
    }

    const create_info: c.VkInstanceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application_info,
        .enabledExtensionCount = glfw_extensions_count,
        .ppEnabledExtensionNames = extensions.ptr,
        .flags = c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR | 0,
        .pNext = null,
    };

    var app = App{ .instance = null };

    const result = c.vkCreateInstance(&create_info, null, &app.instance);

    if (result != c.VK_SUCCESS) {
        std.debug.print("result code: {}\n", .{result});
        return error.InstanceCreationError;
    }

    return app;
}

pub fn checkValidationSupport(allocator: std.mem.Allocator) !bool {
    var layer_count: u32 = 0;
    if (c.vkEnumerateInstanceLayerProperties(&layer_count, null) != c.VK_SUCCESS) {
        return error.EnumerateInstanceLayerProperties;
    }

    const validation_layers = [_][]const u8{
        "VK_LAYER_KHRONOS_validation",
    };

    const available_layers = try allocator.alloc(c.VkLayerProperties, layer_count);
    defer allocator.free(available_layers);

    if (c.vkEnumerateInstanceLayerProperties(&layer_count, available_layers.ptr) != c.VK_SUCCESS) {
        return error.EnumerateInstanceLayerProperties;
    }

    for (validation_layers) |layer_name| {
        var layer_found = false;

        for (available_layers) |layer| {
            if (c.strncmp(@ptrCast(&layer.layerName), layer_name.ptr, layer_name.len) == 0) {
                std.debug.print("layer: \"{s}\" found.\n", .{layer_name});
                layer_found = true;
                break;
            }
        }

        if (!layer_found) {
            return false;
        }
    }

    return true;
}
