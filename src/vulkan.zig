const std = @import("std");
const c = @import("c.zig").c;

pub const App = struct {
    const validation_layers = [_][]const u8{
        "VK_LAYER_KHRONOS_validation",
    };

    instance: c.VkInstance = null,
    physical_device: c.VkPhysicalDevice = null,
    logical_device: c.VkDevice = null,
    surface: c.VkSurfaceKHR = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,

    pub fn deinit(self: *App) void {
        c.vkDestroyDevice(self.logical_device, null);
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        c.vkDestroyInstance(self.instance, null);
    }

    fn pickPhysicalDevice(self: *App, allocator: std.mem.Allocator) !void {
        var physical_device: c.VkPhysicalDevice = null;

        var device_count: u32 = 0;
        var err = c.vkEnumeratePhysicalDevices(self.instance, &device_count, null);
        if (err != c.VK_SUCCESS) {
            return error.EnumeratePhysicalDevicesError;
        }

        if (device_count == 0) {
            return error.NoPhysicalDevicesFound;
        }

        const physical_devices_slice = try allocator.alignedAlloc(
            u8,
            c.VK_PHYSICAL_DEVICE_ALIGNOF,
            c.VK_PHYSICAL_DEVICE_SIZEOF * device_count,
        );

        const available_devices = @as(
            [*]c.VkPhysicalDevice,
            @ptrCast(physical_devices_slice.ptr),
        )[0..device_count];

        err = c.vkEnumeratePhysicalDevices(
            self.instance,
            &device_count,
            available_devices.ptr,
        );
        if (err != c.VK_SUCCESS) return error.AssertError;

        for (available_devices) |device| {
            if (try self.isDeviceSuitable(device, allocator)) {
                physical_device = device;
                break;
            }
        }

        if (physical_device == null) return error.AssertError;

        self.physical_device = physical_device;
    }

    fn createLogicalDevice(self: *App, allocator: std.mem.Allocator) !void {
        const indices = try self.findQueueFamilies(self.physical_device, allocator);

        if (!indices.isComplete()) {
            return error.NullQueueFamily;
        }

        var queue_priority: f32 = 1.0;

        var device_features = c.VkPhysicalDeviceFeatures{};

        var unique_families = std.AutoHashMap(u32, void).init(allocator);
        defer unique_families.deinit();

        try unique_families.put(indices.graphics_family.?, {});
        try unique_families.put(indices.present_family.?, {});

        var queue_create_infos = std.ArrayList(c.VkDeviceQueueCreateInfo).init(allocator);

        var iterator = unique_families.iterator();
        while (iterator.next()) |family| {
            const queue_create_info = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = family.key_ptr.*,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            try queue_create_infos.append(queue_create_info);
        }

        var create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = queue_create_infos.items.ptr,
            .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
            .pEnabledFeatures = &device_features,
            .enabledExtensionCount = 0,
            .enabledLayerCount = @intCast(validation_layers.len),
            .ppEnabledLayerNames = @ptrCast(&validation_layers),
        };

        const err = c.vkCreateDevice(
            self.physical_device,
            &create_info,
            null,
            &self.logical_device,
        );
        if (err != c.VK_SUCCESS) return error.CreateLogicalDeviceError;

        c.vkGetDeviceQueue(
            self.logical_device,
            indices.graphics_family.?,
            0,
            &self.graphics_queue,
        );
    }

    fn createSurface(self: *App, window: *c.GLFWwindow) !void {
        const err = c.glfwCreateWindowSurface(self.instance, window, null, &self.surface);
        if (err != c.VK_SUCCESS) return error.CreateWindowSurfaceError;
    }

    fn isDeviceSuitable(
        self: *App,
        device: c.VkPhysicalDevice,
        allocator: std.mem.Allocator,
    ) !bool {
        const indices = try self.findQueueFamilies(device, allocator);
        return indices.isComplete();
    }

    fn findQueueFamilies(
        self: *App,
        device: c.VkPhysicalDevice,
        allocator: std.mem.Allocator,
    ) !QueueFamilyIndices {
        var indices = QueueFamilyIndices{
            .graphics_family = null,
            .present_family = null,
        };

        var queue_family_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(
            device,
            &queue_family_count,
            null,
        );

        const queue_family_backing_slice = try allocator.alignedAlloc(
            u8,
            c.VK_QUEUE_FAMILY_PROPERTIES_ALIGNOF,
            c.VK_QUEUE_FAMILY_PROPERTIES_SIZEOF * queue_family_count,
        );

        const queue_families = @as([*]c.VkQueueFamilyProperties, @ptrCast(queue_family_backing_slice.ptr))[0..queue_family_count];

        c.vkGetPhysicalDeviceQueueFamilyProperties(
            device,
            &queue_family_count,
            queue_families.ptr,
        );

        for (queue_families, 0..) |family, idx| {
            if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 1) {
                indices.graphics_family = @intCast(idx);
            }

            var present_supported: u32 = c.VK_FALSE;
            const err = c.vkGetPhysicalDeviceSurfaceSupportKHR(
                device,
                @intCast(idx),
                self.surface,
                &present_supported,
            );
            if (err != c.VK_SUCCESS) return error.GetDeviceSupportKHR;

            if (present_supported == c.VK_TRUE) {
                indices.present_family = @intCast(idx);
            }
        }

        return indices;
    }
};

pub fn createApp(allocator: std.mem.Allocator, window: *c.GLFWwindow) !App {
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

    try app.createSurface(window);
    _ = try checkValidationSupport(allocator);
    try app.pickPhysicalDevice(allocator);
    try app.createLogicalDevice(allocator);

    return app;
}

const QueueFamilyIndices = struct {
    graphics_family: ?u32,
    present_family: ?u32,

    fn isComplete(self: *const QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

fn checkValidationSupport(allocator: std.mem.Allocator) !bool {
    var layer_count: u32 = 0;
    if (c.vkEnumerateInstanceLayerProperties(&layer_count, null) != c.VK_SUCCESS) {
        return error.EnumerateInstanceLayerProperties;
    }

    const available_layers = try allocator.alloc(c.VkLayerProperties, layer_count);
    defer allocator.free(available_layers);

    if (c.vkEnumerateInstanceLayerProperties(
        &layer_count,
        available_layers.ptr,
    ) != c.VK_SUCCESS) {
        return error.EnumerateInstanceLayerProperties;
    }

    for (App.validation_layers) |layer_name| {
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
