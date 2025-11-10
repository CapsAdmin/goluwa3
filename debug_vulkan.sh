
export VULKAN_SDK="/Users/caps/VulkanSDK/1.4.328.1"
export VK_ICD_FILENAMES="$VULKAN_SDK/macOS/share/vulkan/icd.d/MoltenVK_icd.json"
export VK_LAYER_PATH="$VULKAN_SDK/macOS/share/vulkan/explicit_layer.d"
export DYLD_LIBRARY_PATH="$VULKAN_SDK/macOS/lib"
export VK_LOADER_DEBUG=all
luajit debug.lua $*