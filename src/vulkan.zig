const std = @import("std");
const c = @import("c.zig").c;
const math = std.math;
const io = @import("io.zig");

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
    render_pass: c.VkRenderPass = null,
    pipeline_layout: c.VkPipelineLayout = null,
    graphics_pipeline: c.VkPipeline = null,
    swap_chain_frame_buffers: []c.VkFramebuffer = undefined,
    command_pool: c.VkCommandPool = null,
    command_buffer: c.VkCommandBuffer = null,
    image_available_semaphore: c.VkSemaphore = null,
    render_finished_semaphore: c.VkSemaphore = null,
    in_flight_fence: c.VkFence = null,

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
        try app.createRenderPass();
        try app.createGraphicsPipeline(allocator);
        try app.createFrameBuffers(allocator);
        try app.createCommandPool(allocator);
        try app.createCommandBuffer();
        try app.createSyncObjects();

        return app;
    }

    pub fn destroy(self: *App, allocator: std.mem.Allocator) void {
        self.cleanupSwapChain(allocator);

        c.vkDestroyPipeline(
            self.logical_device,
            self.graphics_pipeline,
            null,
        );
        c.vkDestroyPipelineLayout(
            self.logical_device,
            self.pipeline_layout,
            null,
        );
        c.vkDestroyRenderPass(self.logical_device, self.render_pass, null);

        c.vkDestroySemaphore(self.logical_device, self.image_available_semaphore, null);
        c.vkDestroySemaphore(self.logical_device, self.render_finished_semaphore, null);
        c.vkDestroyFence(self.logical_device, self.in_flight_fence, null);

        c.vkDestroyCommandPool(self.logical_device, self.command_pool, null);

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

    fn createRenderPass(self: *App) !void {
        const color_attachment = c.VkAttachmentDescription{
            .format = self.swap_chain_image_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_attachment_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
        };

        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        const render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        const err = c.vkCreateRenderPass(
            self.logical_device,
            &render_pass_info,
            null,
            &self.render_pass,
        );
        if (err != c.VK_SUCCESS) return error.RenderPassCreationError;
    }

    fn createGraphicsPipeline(self: *App, allocator: std.mem.Allocator) !void {
        const vert_shader_path = try std.fs.cwd().realpathAlloc(
            allocator,
            "src/shaders/vert.spv",
        );
        defer allocator.free(vert_shader_path);

        const frag_shader_path = try std.fs.cwd().realpathAlloc(
            allocator,
            "src/shaders/frag.spv",
        );
        defer allocator.free(frag_shader_path);

        const vert_shader_code = try io.readFile(vert_shader_path, allocator);
        const frag_shader_code = try io.readFile(frag_shader_path, allocator);

        const vert_shader_module = try self.createShaderModule(vert_shader_code);
        defer c.vkDestroyShaderModule(self.logical_device, vert_shader_module, null);

        const frag_shader_module = try self.createShaderModule(frag_shader_code);
        defer c.vkDestroyShaderModule(self.logical_device, frag_shader_module, null);

        const vert_shader_stage_info = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_shader_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const frag_shader_stage_info = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_shader_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            vert_shader_stage_info,
            frag_shader_stage_info,
        };

        const dynamic_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state_create_info = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };

        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };

        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swap_chain_extent,
        };

        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
        };

        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = c.VK_CULL_MODE_BACK_BIT,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
        };

        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = c.VK_FALSE,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };

        const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT |
                c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT |
                c.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        };

        const color_blending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = [4]f32{
                0.0,
                0.0,
                0.0,
                0.0,
            },
        };

        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var err = c.vkCreatePipelineLayout(
            self.logical_device,
            &pipeline_layout_info,
            null,
            &self.pipeline_layout,
        );
        if (err != c.VK_SUCCESS) return error.CreatePipelineLayoutError;

        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state_create_info,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        err = c.vkCreateGraphicsPipelines(
            self.logical_device,
            null,
            1,
            &pipeline_info,
            null,
            &self.graphics_pipeline,
        );
        if (err != c.VK_SUCCESS) return error.PipelineCreationError;
    }

    fn createShaderModule(self: *App, code: []u8) !c.VkShaderModule {
        var create_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len,
            .pCode = @ptrCast(@alignCast(code.ptr)),
        };

        var shader_module: c.VkShaderModule = null;

        const err = c.vkCreateShaderModule(
            self.logical_device,
            &create_info,
            null,
            &shader_module,
        );
        if (err != c.VK_SUCCESS) return error.ShaderModuleCreationError;

        return shader_module;
    }

    fn createFrameBuffers(self: *App, allocator: std.mem.Allocator) !void {
        self.swap_chain_frame_buffers = try allocator.alloc(
            c.VkFramebuffer,
            self.swap_chain_image_views.len,
        );

        for (self.swap_chain_image_views, 0..) |image_view, idx| {
            const attachments = [_]c.VkImageView{
                image_view,
            };

            const frame_buffer_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &attachments,
                .width = self.swap_chain_extent.width,
                .height = self.swap_chain_extent.height,
                .layers = 1,
            };

            const err = c.vkCreateFramebuffer(
                self.logical_device,
                &frame_buffer_info,
                null,
                &self.swap_chain_frame_buffers[idx],
            );
            if (err != c.VK_SUCCESS) return error.FrameBufferCreationError;
        }
    }

    fn createCommandPool(self: *App, allocator: std.mem.Allocator) !void {
        const queue_family_indices = try self.findQueueFamilies(
            self.physical_device,
            allocator,
        );

        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = queue_family_indices.graphics_family.?,
        };

        const err = c.vkCreateCommandPool(
            self.logical_device,
            &pool_info,
            null,
            &self.command_pool,
        );
        if (err != c.VK_SUCCESS) return error.CommandPoolCreationError;
    }

    fn createCommandBuffer(self: *App) !void {
        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        const err = c.vkAllocateCommandBuffers(
            self.logical_device,
            &alloc_info,
            &self.command_buffer,
        );
        if (err != c.VK_SUCCESS) return error.AllocateCommandBufferError;
    }

    fn recordCommandBuffer(
        self: *App,
        command_buffer: c.VkCommandBuffer,
        image_index: u32,
    ) !void {
        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        var err = c.vkBeginCommandBuffer(command_buffer, &begin_info);
        if (err != c.VK_SUCCESS) return error.BeginCommandBufferError;

        const clear_color = c.VkClearValue{
            .color = .{ .float32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 } },
        };

        const render_pass_info = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.render_pass,
            .framebuffer = self.swap_chain_frame_buffers[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swap_chain_extent,
            },
            .clearValueCount = 1,
            .pClearValues = &clear_color,
        };

        c.vkCmdBeginRenderPass(
            command_buffer,
            &render_pass_info,
            c.VK_SUBPASS_CONTENTS_INLINE,
        );

        c.vkCmdBindPipeline(
            command_buffer,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.graphics_pipeline,
        );

        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };

        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swap_chain_extent,
        };

        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);

        c.vkCmdEndRenderPass(command_buffer);

        err = c.vkEndCommandBuffer(command_buffer);
        if (err != c.VK_SUCCESS) return error.VkCmdError;
    }

    fn createSyncObjects(self: *App) !void {
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        var err = c.vkCreateSemaphore(
            self.logical_device,
            &semaphore_info,
            null,
            &self.image_available_semaphore,
        );
        if (err != c.VK_SUCCESS) return error.SemaphoreCreateError;

        err = c.vkCreateSemaphore(
            self.logical_device,
            &semaphore_info,
            null,
            &self.image_available_semaphore,
        );
        if (err != c.VK_SUCCESS) return error.SemaphoreCreateError;

        err = c.vkCreateFence(
            self.logical_device,
            &fence_info,
            null,
            &self.in_flight_fence,
        );
        if (err != c.VK_SUCCESS) return error.FenceCreateError;
    }

    pub fn drawFrame(
        self: *App,
        window: *c.GLFWwindow,
        allocator: std.mem.Allocator,
    ) !void {
        var err = c.vkWaitForFences(
            self.logical_device,
            1,
            &self.in_flight_fence,
            c.VK_TRUE,
            c.UINT64_MAX,
        );
        if (err != c.VK_SUCCESS) return error.WaitForFenceError;

        err = c.vkResetFences(self.logical_device, 1, &self.in_flight_fence);
        if (err != c.VK_SUCCESS) return error.ResetFenceError;

        var image_index: u32 = 0;
        err = c.vkAcquireNextImageKHR(
            self.logical_device,
            self.swap_chain,
            c.UINT64_MAX,
            self.image_available_semaphore,
            null,
            &image_index,
        );
        if (err == c.VK_ERROR_OUT_OF_DATE_KHR or
            err == c.VK_SUBOPTIMAL_KHR)
        {
            try self.recreateSwapChain(window, allocator);
        } else if (err != c.VK_SUCCESS) return error.AcquireImageError;

        err = c.vkResetCommandBuffer(self.command_buffer, 0);
        if (err != c.VK_SUCCESS) return error.ResetCommandBufferError;

        try self.recordCommandBuffer(self.command_buffer, image_index);

        const wait_semaphores = [_]c.VkSemaphore{self.image_available_semaphore};

        const wait_stages = [_]c.VkPipelineStageFlags{
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        };

        const signal_semaphores = [_]c.VkSemaphore{self.render_finished_semaphore};

        var submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };

        err = c.vkQueueSubmit(
            self.graphics_queue,
            1,
            &submit_info,
            self.in_flight_fence,
        );
        if (err != c.VK_SUCCESS) return error.VkQueueSubmitError;

        const swap_chains = [_]c.VkSwapchainKHR{self.swap_chain};

        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swap_chains,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        err = c.vkQueuePresentKHR(self.present_queue, &present_info);
        if (err != c.VK_SUCCESS) return error.VkQuePresentError;
    }

    pub fn recreateSwapChain(
        self: *App,
        window: *c.GLFWwindow,
        allocator: std.mem.Allocator,
    ) !void {
        const err = c.vkDeviceWaitIdle(self.logical_device);
        if (err != c.VK_SUCCESS) return error.WaitIdleError;

        self.cleanupSwapChain(allocator);

        try self.createSwapChain(window, allocator);
        try self.createImageViews(allocator);
        try self.createFrameBuffers(allocator);
    }

    fn cleanupSwapChain(self: *App, allocator: std.mem.Allocator) void {
        for (self.swap_chain_frame_buffers) |frame_buffer| {
            c.vkDestroyFramebuffer(self.logical_device, frame_buffer, null);
        }
        allocator.free(self.swap_chain_frame_buffers);

        for (self.swap_chain_image_views) |img_view| {
            c.vkDestroyImageView(self.logical_device, img_view, null);
        }

        allocator.free(self.swap_chain_image_views);
        allocator.free(self.swap_chain_images);

        c.vkDestroySwapchainKHR(self.logical_device, self.swap_chain, null);
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
