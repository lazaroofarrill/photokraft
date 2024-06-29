#ifndef SRC_SIZE_AND_ALIGN_C__
#define SRC_SIZE_AND_ALIGN_C__
#include "stdalign.h"
#include "stdlib.h"
#include "vulkan/vulkan_core.h"

const size_t VK_PHYSICAL_DEVICE_SIZEOF = sizeof(VkPhysicalDevice);
const size_t VK_PHYSICAL_DEVICE_ALIGNOF = alignof(VkPhysicalDevice);

#endif
