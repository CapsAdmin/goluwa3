#!/bin/bash

export VULKAN_SDK="/Users/caps/VulkanSDK/1.4.328.1"
export VK_LAYER_PATH="$VULKAN_SDK/macOS/share/vulkan/explicit_layer.d"

export VK_LOADER_DEBUG=all

luajit debug.lua $*