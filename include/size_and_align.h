#ifndef SRC_SIZE_AND_ALIGN_C__
#define SRC_SIZE_AND_ALIGN_C__
#include "stdalign.h"
#include "stdlib.h"
#include "vulkan/vulkan_core.h"

const size_t VK_PHYSICAL_DEVICE_SIZEOF = sizeof(VkPhysicalDevice);
const size_t VK_PHYSICAL_DEVICE_ALIGNOF = _Alignof(VkPhysicalDevice);

const size_t VK_QUEUE_FAMILY_PROPERTIES_SIZEOF =
    sizeof(VkQueueFamilyProperties);

const size_t VK_QUEUE_FAMILY_PROPERTIES_ALIGNOF = 4;
// Using alignof breaks my build sometimes
//  _Alignof(VkQueueFamilyProperties);

#endif
