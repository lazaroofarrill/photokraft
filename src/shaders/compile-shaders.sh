#!/bin/sh

cd $(dirname $0)

glslc_bin="$VULKAN_SDK/bin/glslc"


$glslc_bin ./shader.vert -o ./vert.spv
$glslc_bin ./shader.frag -o ./frag.spv
