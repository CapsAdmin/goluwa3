local T = import("test/environment.lua")
local vfs = import("goluwa/filesystem/vfs.lua")
local resource = import("goluwa/resource.lua")
local ZIP_PATH = function()
	return resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/test.zip"):Get()
end

T.Test("ZIP VFS registration", function()
	local filesystems = vfs.GetFileSystems()
	local found_zip = false

	for _, fs in ipairs(filesystems) do
		if fs.Name == "zip archive" then
			found_zip = true

			break
		end
	end

	T(found_zip)["=="](true)
end)

T.Test("ZIP VFS file reading", function()
	-- Find a file to open
	local files = vfs.Find(ZIP_PATH() .. "/codecs/", nil, nil, nil, nil, true)
	T(#files)["=="](8)
	local test_file_path = files[1].full_path
	local file = assert(vfs.Open(test_file_path))
	local size = file:GetSize()
	T(size)[">="](0)
	local content = file:ReadBytes(math.min(100, size))
	T(content)["contains"]("local ffi")

	if content then
		T(#content)[">="](1)
		T(#content)["<="](100)
	end

	T(file:GetPosition())[">="](0)
	file:Close()
end)