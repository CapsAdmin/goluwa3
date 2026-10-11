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
	},}
