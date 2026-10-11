-- prebuilt binaries are built from the pinned upstream refs by .github/workflows/build-binaries.yml
-- after a run, paste the sha256 values from the job summary here
local release_url = "https://github.com/CapsAdmin/goluwa3/releases/download/"
return {
	shaderc = {
		source = "https://github.com/google/shaderc",
		ref = "v2026.1",
		release = release_url .. "shaderc-v2026.1/",
		assets = {
			["windows-x64"] = {file = "shaderc_shared-windows-x64.dll"},
			["linux-x64"] = {file = "shaderc_shared-linux-x64.so"},
			["macos-arm64"] = {file = "shaderc_shared-macos-arm64.dylib"},
		},
	},
}
