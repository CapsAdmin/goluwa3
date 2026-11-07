-- after a run, paste the sha256 values from the job summary here
local release_url = "https://github.com/CapsAdmin/goluwa3/releases/download/"
return {
	glslang = {
		source = "https://github.com/KhronosGroup/glslang",
		ref = "16.6.0",
		release = release_url .. "glslang-16.6.0/",
		assets = {
			["windows-x64"] = {
				library = {file = "glslang-windows-x64.dll"},
				limits = {file = "glslang-default-resource-limits-windows-x64.dll"},
			},
			["linux-x64"] = {
				library = {file = "libglslang-linux-x64.so"},
				limits = {file = "libglslang-default-resource-limits-linux-x64.so"},
			},
			["macos-arm64"] = {
				library = {file = "libglslang-macos-arm64.dylib"},
				limits = {file = "libglslang-default-resource-limits-macos-arm64.dylib"},
			},
		},
	},
	luajit = {
		source = "https://github.com/LuaJIT/LuaJIT",
		ref = "c6ffc141a8762b41703f9287d63d93622a13dd8f",
		release = release_url .. "luajit-c6ffc14/",
		assets = {
			["windows-x64"] = {
				file = "luajit-windows-x64.zip",
				sha256 = "616a66147a56c494f7f1a7771a2e70db275daf86a6e1bb7e1e815c266e65493c",
			},
			["linux-x64"] = {
				file = "luajit-linux-x64",
				sha256 = "8b8cdb1f52bc86e1e8a4f47b8ed872104dfa81f5efe2f9ee803ae2ba29ec9801",
			},
			["macos-arm64"] = {
				file = "luajit-macos-arm64",
				sha256 = "9d00d154d0e119d74984d0bfa3d78513a3737dfc62f5488158560cece46a004c",
			},
		},
	},
	kosmickrisp = {
		source = "https://gitlab.freedesktop.org/mesa/mesa",
		ref = "mesa-26.2.4",
		loader_source = "https://github.com/KhronosGroup/Vulkan-Loader",
		loader_ref = "v1.4.365",
		spirv_tools_source = "https://github.com/KhronosGroup/SPIRV-Tools",
		spirv_tools_ref = "v2026.4",
		release = release_url .. "kosmickrisp-mesa-26.2.4/",
		assets = {
			["macos-arm64"] = {
				loader = {
					file = "libvulkan-macos-arm64.dylib",
					sha256 = "c7a16e4d1f53d46f7fcb2a7991461cd777d00e175ebd4f2f495abd4d458f5152",
				},
				driver = {
					file = "libvulkan_kosmickrisp-macos-arm64.dylib",
					sha256 = "10c5a322b952e139f98dc9bef676d0c3c7bcda7f2bc7e9ec011e87148af13583",
				},
			},
		},
	},
}
