local T = require("test.t")
local vfs = require("filesystem.vfs")
local R = vfs.GetAbsolutePath
local ZIP_PATH = "/home/caps/projects/goluwa3/game/storage/temp_bsp.zip/"

T.test("ZIP VFS registration", function()
	-- Test that the ZIP file system is registered
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

T.test("ZIP VFS basic functionality", function()
	-- Test listing actual files in the ZIP (deeper path to get actual files)
	local files, err = vfs.Find(ZIP_PATH .. "materials/maps/gm_flatgrass/", nil, nil, nil, nil, true)
	T(files)["~="](nil)
	T(#files)[">="](1)

	-- Test that we can check if files inside the zip exist
	if files and files[1] then
		local first_file = files[1].full_path
		T(vfs.IsFile(first_file))["=="](true)
	end
end)

T.test("ZIP VFS file reading", function()
	-- Find a file to open
	local files = vfs.Find(ZIP_PATH .. "materials/maps/", nil, nil, nil, nil, true)
	T(files)["~="](nil)
	T(#files)[">="](1)

	if files and files[1] then
		local test_file_path = files[1].full_path
		-- Open the file
		local file = vfs.Open(test_file_path)
		T(file)["~="](nil)

		if file then
			-- Check that we can get the size
			local size = file:GetSize()
			T(size)[">="](0)
			-- Check that we can read data
			local content = file:ReadBytes(math.min(100, size))
			T(content)["~="](nil)

			if content then
				T(#content)[">="](1)
				T(#content)["<="](100)
			end

			-- Check position tracking
			T(file:GetPosition())[">="](0)
			-- Close the file
			file:Close()
		end
	end
end)

T.test("ZIP VFS directory listing", function()
	-- Test that we can list directories at different levels
	local files = vfs.Find(ZIP_PATH .. "materials/maps/", nil, nil, nil, nil, true)
	T(files)["~="](nil)

	if files then
		-- Should find at least the "gm_flatgrass" directory
		local found_dir = false

		for _, file in ipairs(files) do
			if file.name == "gm_flatgrass" then
				found_dir = true

				break
			end
		end

		T(found_dir)["=="](true)
	end
end)
