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

T.Test("ZIP VFS prefetch inflates on a worker and reads the same bytes", function()
	local files = vfs.Find(ZIP_PATH() .. "/codecs/", nil, nil, nil, nil, true)
	local biggest

	for _, info in ipairs(files) do
		local file = assert(vfs.Open(info.full_path))
		local size = file:GetSize()
		file:Close()

		if not biggest or size > biggest.size then biggest = {path = info.full_path, size = size} end
	end

	local thread_pool = import("goluwa/thread_pool.lua")
	local inline_threshold = thread_pool.inline_threshold
	thread_pool.inline_threshold = 0
	local expected = assert(vfs.Read(biggest.path))
	local done = false
	vfs.Prefetch(biggest.path, function()
		done = true
	end)
	T.WaitUntil(function()
		return done
	end, 10)
	thread_pool.inline_threshold = inline_threshold
	T(done)["=="](true)
	local read = assert(vfs.Read(biggest.path))
	T(#read)["=="](#expected)
	T(read == expected)["=="](true)
	T(vfs.Read(biggest.path) == expected)["=="](true)
end)
