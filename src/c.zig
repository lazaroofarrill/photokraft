pub const c = @cImport({
    @cInclude("strings.h");
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cInclude("GLFW/glfw3.h");
});
