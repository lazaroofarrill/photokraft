const std = @import("std");
const c = @import("c.zig").c;
const math = std.math;

const QueueFamilyIndices = struct {
    graphics_family: ?u32,
    present_family: ?u32,

    fn isComplete(self: *const QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

pub const App = struct {
    const validation_layers = [_][]const u8{
        "VK_LAYER_KHRONOS_validation",
    };

    const required_extensions = [_][]const u8{
        c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    };

    instance: c.VkInstance = null,
    physical_device: c.VkPhysicalDevice = null,
    logical_device: c.VkDevice = null,
    surface: c.VkSurfaceKHR = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    swap_chain: c.VkSwapchainKHR = null,
    swap_chain_images: []c.VkImage = undefined,
    swap_chain_image_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    swap_chain_extent: c.VkExtent2D = undefined,
    swap_chain_image_views: []c.VkImageView = undefined,

    pub fn create(allocator: std.mem.Allocator, window: *c.GLFWwindow) !App {
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
        defer allocator.free(extensions);

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

        var app = App{};

        const result = c.vkCreateInstance(&create_info, null, &app.instance);

        if (result != c.VK_SUCCESS) {
            std.debug.print("result code: {}\n", .{result});
            return error.InstanceCreationError;
        }

        try app.createSurface(window);
        _ = try checkValidationSupport(allocator);
        try app.pickPhysicalDevice(allocator);
        try app.createLogicalDevice(allocator);
        try app.createSwapChain(window, allocator);
        try app.createImageViews(allocator);
        try app.createGraphicsPipeline(allocator);

        return app;
    }

    pub fn destroy(self: *App, allocator: std.mem.Allocator) void {
        for (self.swap_chain_image_views) |img_view| {
            c.vkDestroyImageView(self.logical_device, img_view, null);
        }

        allocator.free(self.swap_chain_image_views);
        allocator.free(self.swap_chain_images);
        c.vkDestroySwapchainKHR(self.logical_device, self.swap_chain, null);
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

        if (physical_device == null) return error.NoSuitableDeviceFound;

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
            .enabledExtensionCount = required_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&required_extensions),
            .enabledLayerCount = validation_layers.len,
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

        c.vkGetDeviceQueue(
            self.logical_device,
            indices.present_family.?,
            0,
            &self.present_queue,
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

        const extensions_supported = try checkDeviceExtensionSupport(device, allocator);

        var swap_chain_adequate = false;
        if (extensions_supported) {
            const swap_chain_support = try self.querySwapChainSupport(device, allocator);

            std.debug.print(
                "formats: {any}\npresent_modes: {any}\n",
                .{
                    swap_chain_support.formats.items.len,
                    swap_chain_support.present_modes.items.len,
                },
            );

            swap_chain_adequate = swap_chain_support.formats.items.len > 0 and
                swap_chain_support.present_modes.items.len > 0;
        }

        return indices.isComplete() and extensions_supported and swap_chain_adequate;
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

    fn checkDeviceExtensionSupport(
        device: c.VkPhysicalDevice,
        allocator: std.mem.Allocator,
    ) !bool {
        var extension_count: u32 = 0;
        var err = c.vkEnumerateDeviceExtensionProperties(
            device,
            null,
            &extension_count,
            null,
        );
        if (err != c.VK_SUCCESS) return error.ExtensionEnumerateError;

        const available_extensions = try allocator.alloc(c.VkExtensionProperties, extension_count);

        err = c.vkEnumerateDeviceExtensionProperties(
            device,
            null,
            &extension_count,
            available_extensions.ptr,
        );
        if (err != c.VK_SUCCESS) return error.ExtensionEnumerateError;

        var required_extensions_set = std.StringHashMap(void).init(allocator);
        defer required_extensions_set.deinit();

        for (required_extensions) |ext| {
            try required_extensions_set.put(ext, {});
        }

        for (available_extensions) |ext| {
            const ext_len = c.strlen(&ext.extensionName);
            const ext_name = ext.extensionName[0..ext_len];
            _ = required_extensions_set.remove(ext_name);
        }

        return required_extensions_set.count() == 0;
    }

    const SwapChainSupportDetails = struct {
        capabilities: c.VkSurfaceCapabilitiesKHR,
        formats: std.ArrayList(c.VkSurfaceFormatKHR),
        present_modes: std.ArrayList(c.VkPresentModeKHR),
    };

    fn querySwapChainSupport(
        self: *App,
        device: c.VkPhysicalDevice,
        allocator: std.mem.Allocator,
    ) !SwapChainSupportDetails {
        var details = SwapChainSupportDetails{
            .capabilities = c.VkSurfaceCapabilitiesKHR{},
            .formats = std.ArrayList(c.VkSurfaceFormatKHR).init(allocator),
            .present_modes = std.ArrayList(c.VkPresentModeKHR).init(allocator),
        };

        var err = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            device,
            self.surface,
            &details.capabilities,
        );
        if (err != c.VK_SUCCESS) return error.PhysicalDeviceSurfaceCapabilitiesError;

        var format_count: u32 = 0;
        err = c.vkGetPhysicalDeviceSurfaceFormatsKHR(
            device,
            self.surface,
            &format_count,
            null,
        );
        if (err != c.VK_SUCCESS) return error.PhysicalDeviceSurfaceFormatsKHR;

        if (format_count != 0) {
            try details.formats.resize(format_count);
            err = c.vkGetPhysicalDeviceSurfaceFormatsKHR(
                device,
                self.surface,
                &format_count,
                details.formats.items.ptr,
            );
            if (err != c.VK_SUCCESS) return error.PhysicalDeviceSurfaceFormatsKHR;
        }

        var present_mode_count: u32 = 0;
        err = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            device,
            self.surface,
            &present_mode_count,
            null,
        );
        if (err != c.VK_SUCCESS) return error.VkError;

        if (present_mode_count != 0) {
            try details.present_modes.resize(present_mode_count);
            err = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
                device,
                self.surface,
                &present_mode_count,
                details.present_modes.items.ptr,
            );
            if (err != c.VK_SUCCESS) return error.VkError;
        }

        return details;
    }

    fn chooseSwapSurfaceFormat(
        available_formats: []c.VkSurfaceFormatKHR,
    ) !c.VkSurfaceFormatKHR {
        if (available_formats.len == 0) return error.NoSurfacFormats;

        for (available_formats) |available_format| {
            if (available_format.format == c.VK_FORMAT_B8G8R8_SRGB and
                available_format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return available_format;
            }
        }

        return available_formats[0];
    }

    fn chooseSwapPresentMode(
        available_present_modes: []c.VkPresentModeKHR,
    ) c.VkPresentModeKHR {
        for (available_present_modes) |present_mode| {
            if (present_mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                return present_mode;
            }
        }

        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn chooseSwapExtent(
        capabilites: *c.VkSurfaceCapabilitiesKHR,
        window: *c.GLFWwindow,
    ) c.VkExtent2D {
        if (capabilites.currentExtent.width != (math.pow(u64, 2, 32) - 1)) {
            return capabilites.currentExtent;
        } else {
            var width: c_int = 0;
            var height: c_int = 0;
            c.glfwGetFramebufferSize(window, &width, &height);

            var actual_extent = c.VkExtent2D{
                .width = @intCast(width),
                .height = @intCast(height),
            };

            actual_extent.width = math.clamp(
                actual_extent.width,
                capabilites.minImageExtent.width,
                capabilites.maxImageExtent.width,
            );

            actual_extent.height = math.clamp(
                actual_extent.height,
                capabilites.minImageExtent.height,
                capabilites.maxImageExtent.height,
            );

            return actual_extent;
        }
    }

    fn createSwapChain(
        self: *App,
        window: *c.GLFWwindow,
        allocator: std.mem.Allocator,
    ) !void {
        var swap_chain_support = try self.querySwapChainSupport(
            self.physical_device,
            allocator,
        );

        const surface_format = try chooseSwapSurfaceFormat(
            try swap_chain_support.formats.toOwnedSlice(),
        );

        const present_mode = chooseSwapPresentMode(
            try swap_chain_support.present_modes.toOwnedSlice(),
        );

        const extent = chooseSwapExtent(&swap_chain_support.capabilities, window);

        var image_count = swap_chain_support.capabilities.minImageCount + 1;

        if (swap_chain_support.capabilities.maxImageCount > 0 and
            image_count > swap_chain_support.capabilities.maxImageCount)
        {
            image_count = swap_chain_support.capabilities.maxImageCount;
        }

        var create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageColorSpace = surface_format.colorSpace,
            .imageFormat = surface_format.format,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .presentMode = present_mode,
            .preTransform = swap_chain_support.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        const indices = try self.findQueueFamilies(self.physical_device, allocator);
        const queue_family_indices = [_]u32{
            indices.graphics_family.?,
            indices.present_family.?,
        };

        if (indices.graphics_family != indices.present_family) {
            create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            create_info.queueFamilyIndexCount = 2;
            create_info.pQueueFamilyIndices = &queue_family_indices;
        } else {
            create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
            create_info.queueFamilyIndexCount = 0; // Optional
            create_info.pQueueFamilyIndices = null; // Optional
        }

        var err = c.vkCreateSwapchainKHR(
            self.logical_device,
            &create_info,
            null,
            &self.swap_chain,
        );
        if (err != c.VK_SUCCESS) return error.SwapChainCreationError;

        err = c.vkGetSwapchainImagesKHR(
            self.logical_device,
            self.swap_chain,
            &image_count,
            null,
        );
        if (err != c.VK_SUCCESS) return error.VkError;

        self.swap_chain_images = try allocator.alloc(c.VkImage, image_count);

        err = c.vkGetSwapchainImagesKHR(
            self.logical_device,
            self.swap_chain,
            &image_count,
            self.swap_chain_images.ptr,
        );
        if (err != c.VK_SUCCESS) return error.VkError;

        std.debug.print("number of swap chain images: {}\n", .{self.swap_chain_images.len});

        self.swap_chain_image_format = surface_format.format;
        self.swap_chain_extent = extent;
    }

    fn createImageViews(self: *App, allocator: std.mem.Allocator) !void {
        self.swap_chain_image_views = try allocator.alloc(
            c.VkImageView,
            self.swap_chain_images.len,
        );

        for (self.swap_chain_images, 0..) |img, idx| {
            const create_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = img,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swap_chain_image_format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            const err = c.vkCreateImageView(
                self.logical_device,
                &create_info,
                null,
                &self.swap_chain_image_views[idx],
            );
            if (err != c.VK_SUCCESS) return error.ImageViewCreationError;
        }
    }

    fn createGraphicsPipeline(self: *App, allocator: std.mem.Allocator) !void {
        //TODO
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
