local T = require("test.environment")
local fs = require("fs")
local system = require("system")
local test_dir = "storage/userdata/test_filesystem_temp/"

-- Helper to ensure test directory is clean
local function cleanup()
	if fs.exists(test_dir) then
		-- Recursive removal helper for tests
		local function remove_recursive(path)
			if fs.is_directory(path) then
				local files = fs.get_files(path)

				if files then
					for _, file in ipairs(files) do
						remove_recursive(path .. "/" .. file)
					end
				end

				fs.remove_directory(path)
			else
				fs.remove_file(path)
			end
		end

		remove_recursive(test_dir)
	end
end

T.Test("filesystem basic file operations", function()
	cleanup()
	fs.create_directory_recursive(test_dir)
	local file_path = test_dir .. "test.txt"
	local content = "hello world"
	-- Write
	local ok, err = fs.write_file(file_path, content)
	T(ok)["=="](true, err)
	-- Exists
	T(fs.exists(file_path))["=="](true)
	T(fs.is_file(file_path))["=="](true)
	T(fs.is_directory(file_path))["=="](false)
	-- Read
	local read_content = fs.read_file(file_path)
	T(read_content)["=="](content)
	-- Remove
	local ok, err = fs.remove_file(file_path)
	T(ok)["=="](true, err)
	T(fs.exists(file_path))["=="](false)
	cleanup()
end)

T.Test("filesystem directory operations", function()
	cleanup()
	local deep_dir = test_dir .. "a/b/c/"
	local ok, err = fs.create_directory_recursive(deep_dir)
	T(ok)["=="](true, err)
	T(fs.is_directory(deep_dir))["=="](true)
	-- Check parent directories
	T(fs.is_directory(test_dir .. "a/"))["=="](true)
	T(fs.is_directory(test_dir .. "a/b/"))["=="](true)
	-- get_files
	fs.write_file(deep_dir .. "file1.txt", "1")
	fs.write_file(deep_dir .. "file2.txt", "2")
	local files = fs.get_files(deep_dir)
	T(#files)["=="](2)
	local found1, found2 = false, false

	for _, f in ipairs(files) do
		if f == "file1.txt" then found1 = true end

		if f == "file2.txt" then found2 = true end
	end

	T(found1)["=="](true)
	T(found2)["=="](true)
	-- iterate
	local iterated = {}

	for path in fs.iterate(deep_dir, "%.txt$") do
		table.insert(iterated, path)
	end

	T(#iterated)["=="](2)
	-- get_files_recursive
	local all_files = fs.get_files_recursive(test_dir)
	-- Should have test_dir/a, test_dir/a/b, test_dir/a/b/c, and the two files
	-- Actually get_files_recursive implementation in fs.lua uses walk with files_only=true
	-- Let's check the count.
	T(#all_files)["=="](2)
	cleanup()
end)

T.Test("filesystem attributes", function()
	cleanup()
	fs.create_directory_recursive(test_dir)
	local file_path = test_dir .. "attr_test.txt"
	fs.write_file(file_path, "test")
	local attr, err = fs.get_attributes(file_path)
	T(attr)["~="](nil, err)
	T(attr.type)["=="]("file")
	T(attr.size)["=="](4)
	T(type(attr.last_modified))["=="]("number")
	local dir_attr = fs.get_attributes(test_dir)
	T(dir_attr.type)["=="]("directory")
	cleanup()
end)

T.Test("filesystem working directory", function()
	local old_wd = fs.get_current_directory()
	cleanup()
	fs.create_directory_recursive(test_dir)
	-- Test set/get
	local abs_test_dir = fs.get_current_directory() .. "/" .. test_dir
	-- Normalize abs_test_dir (remove double slashes)
	abs_test_dir = abs_test_dir:gsub("//+", "/")

	if abs_test_dir:sub(-1) == "/" then abs_test_dir = abs_test_dir:sub(1, -2) end

	fs.set_current_directory(test_dir)
	local new_wd = fs.get_current_directory()
	-- Depending on OS/path normalization, they might differ slightly in slashes
	-- but they should point to the same place.
	T(new_wd:lower():gsub("\\", "/"):ends_with(test_dir:lower():gsub("/$", "")))["=="](true)
	fs.set_current_directory(old_wd)
	T(fs.get_current_directory())["=="](old_wd)
	-- Test Push/Pop
	fs.PushWorkingDirectory(test_dir)
	T(
		fs.get_current_directory():lower():gsub("\\", "/"):ends_with(test_dir:lower():gsub("/$", ""))
	)["=="](true)
	fs.PopWorkingDirectory()
	T(fs.get_current_directory())["=="](old_wd)
	cleanup()
end)

T.Test("filesystem file objects (high-level)", function()
	cleanup()
	fs.create_directory_recursive(test_dir)
	local file_path = test_dir .. "obj_test.bin"
	local f, err = fs.file_open(file_path, "wb")
	T(f)["~="](nil, err)
	f:write("hello")
	f:write(" world")
	f:close()
	local f2, err = fs.file_open(file_path, "rb")
	T(f2)["~="](nil, err)
	T(f2:read(5))["=="]("hello")
	T(f2:tell())["=="](5)
	T(f2:read(6))["=="](" world")
	-- Trigger EOF by trying to read past the end
	f2:read(1)
	T(f2:eof())["=="](true)
	f2:seek(0)
	T(f2:tell())["=="](0)
	T(f2:read(11))["=="]("hello world")
	f2:close()
	cleanup()
end)

T.Test("filesystem fd objects (low-level)", function()
	if jit.os == "Windows" then

	-- Windows low level fd test might be tricky with pipes as implemented
	-- but let's try basic file fd
	end

	cleanup()
	fs.create_directory_recursive(test_dir)
	local file_path = test_dir .. "fd_test.bin"
	-- Test fd_open_object
	local flags = bit.bor(fs.O_CREAT, fs.O_RDWR)
	local f, err = fs.fd_open_object(file_path, flags)

	if not f then error(err or "failed to open fd") end

	T(f)["~="](nil)
	f:write("fd hello")
	f:seek(0)
	T(f:read(8))["=="]("fd hello")
	f:close()
	-- Test pipes (if supported)
	local r, w = fs.get_read_write_fd_pipes()

	if r then
		w:write("pipe data")
		local data, len = r:read(20)
		-- On some systems, read might be non-blocking or partial
		T(data)["=="]("pipe data")
		r:close()
		w:close()
	end

	cleanup()
end)

T.Test("filesystem path utilities", function()
	T(fs.get_parent_directory("a/b/c"))["=="]("a/b")
	T(fs.get_parent_directory("a/b/c/"))["=="]("a/b")
	T(fs.get_parent_directory("file.txt"))["=="](".")
	T(fs.get_parent_directory("/"))["=="](nil)
end)
