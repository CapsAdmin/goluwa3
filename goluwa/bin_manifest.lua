-- prebuilt binaries are built from the pinned upstream refs by .github/workflows/build-binaries.yml
-- after a run, paste the sha256 values from the job summary here
local release_url = "https://github.com/CapsAdmin/goluwa3/releases/download/"
return {
	shaderc = {
		source = "https://github.com/google/shaderc",
		ref = "v2026.1",
		release = release_url .. "shaderc-v2026.1/",
		assets = {
			["windows-x64"] = {
				file = "shaderc_shared-windows-x64.dll",
				sha256 = "e393e133753fc30e2d955607d64e6a5ea7d6ff27bd66f1eaf5fd1d9cfb2c7fae",
			},
			["linux-x64"] = {
				file = "shaderc_shared-linux-x64.so",
				sha256 = "8794d19736d25a29208f94d11255ba81bd70e48b57b4a793591e76ce8aa2f8b9",
			},
			["macos-arm64"] = {
				file = "shaderc_shared-macos-arm64.dylib",
				sha256 = "0299236023c719b7ffea1d3a76a9934859f3cc3a5c8b8d725f918fad2d4ec431",
			},
		},
	},	luajit = {
		source = "https://github.com/LuaJIT/LuaJIT",
		ref = "c6ffc141a8762b41703f9287d63d93622a13dd8f",
		release = release_url .. "luajit-c6ffc14/",
		assets = {
			["windows-x64"] = {file = "luajit-windows-x64.zip"},
			["linux-x64"] = {file = "luajit-linux-x64"},
			["macos-arm64"] = {file = "luajit-macos-arm64"},
		},
	},	kosmickrisp = {
		source = "https://gitlab.freedesktop.org/mesa/mesa",
		ref = "mesa-26.2.4",
		loader_source = "https://github.com/KhronosGroup/Vulkan-Loader",
		loader_ref = "v1.4.365",
		spirv_tools_source = "https://github.com/KhronosGroup/SPIRV-Tools",
		spirv_tools_ref = "v2026.4",
		release = release_url .. "kosmickrisp-mesa-26.2.4/",
		assets = {
			["macos-arm64"] = {
				loader = {file = "libvulkan-macos-arm64.dylib"},
				driver = {file = "libvulkan_kosmickrisp-macos-arm64.dylib"},
			},
		},
	},
}
