local T = require("test.environment")
local resource = require("resource")
local tasks = require("tasks")
local timer = require("timer")
local vfs = require("vfs")
local sockets = require("sockets.sockets")
local crypto = require("crypto")
local fs = require("fs")

local function remove_recursive(path)
	if fs.is_directory(path) then
		local files = fs.get_files(path)

		if files then
			for _, file in ipairs(files) do
				remove_recursive(path .. "/" .. file)
			end
		end

		local ok, err = fs.remove_directory(path)
		assert(ok, err)
	elseif fs.is_file(path) then
		local ok, err = fs.remove_file(path)
		assert(ok, err)
	end
end

local function cache_dir_for_url(url)
	return vfs.GetStorageDirectory("shared") .. "downloads/url/" .. crypto.CRC32(url)
end

local function cleanup_cache_for_url(url)
	local dir = cache_dir_for_url(url)
	remove_recursive(dir)
	return dir
end

local function download_resource_and_wait(url, timeout, ...)
	local done = false
	local downloaded_path = nil
	local error_reason = nil
	local changed = nil

	resource.Download(url, ...):Then(function(path, did_change)
		downloaded_path = path
		changed = did_change
		done = true
	end):Catch(function(reason)
		error_reason = reason
		done = true
	end)

	T.WaitUntil(function()
		return done
	end, timeout or 10)

	return downloaded_path, error_reason, changed
end

local function with_mock_socket_download(mock, callback)
	local old_download = sockets.Download
	sockets.Download = mock
	local ok, err = xpcall(callback, debug.traceback)
	sockets.Download = old_download

	if not ok then error(err, 0) end
end

local function with_virtual_resource(path, handler, callback)
	local old = resource.virtual_files[path]
	resource.virtual_files[path] = handler
	local ok, err = xpcall(callback, debug.traceback)
	resource.virtual_files[path] = old

	if not ok then error(err, 0) end
end

T.Test("resource.Download from providers works", function()
	-- Clear providers for a clean test
	resource.providers = {}
	-- We use raw.githubusercontent.com to avoid redirect issues in the current socket implementation
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)
	vfs.MountAddons("os:downloads/")
	local done = false
	local downloaded_path = nil
	local error_reason = nil

	resource.Download("fonts/Nunito-ExtraLight.ttf"):Then(function(path)
		downloaded_path = path
		done = true
	end):Catch(function(reason)
		error_reason = reason
		done = true
	end)

	T.WaitUntil(function()
		return done
	end, 60)

	T(error_reason)["=="](nil)
	T(type(downloaded_path))["=="]("string")
	T(vfs.Exists(downloaded_path))["=="](true)
end)

T.Test("resource.Download from direct URL works", function()
	local url = "https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/fonts/Nunito-ExtraLight.ttf"
	local downloaded_path, error_reason = download_resource_and_wait(url, 60)
	T(error_reason)["=="](nil)
	T(type(downloaded_path))["=="]("string")
	T(vfs.Exists(downloaded_path))["=="](true)
end)

T.Test("resource.Download keeps original URL extension across redirects", function()
	local url = "https://example.invalid/resource-redirect.ogg"
	local cache_dir = cleanup_cache_for_url(url)

	with_mock_socket_download(function(_, on_finish, _, on_chunks, on_header)
		local client = {valid = true}

		function client:IsValid()
			return self.valid
		end

		function client:Close()
			self.valid = false
		end

		timer.Delay(0.01, function()
			if not client.valid then return end

			on_header({["content-type"] = "text/html; charset=utf-8"})
			on_header({["content-type"] = "audio/ogg"})
			on_chunks("oggdata")
			on_finish("oggdata")
			client.valid = false
		end)

		return client
	end, function()
		local downloaded_path, error_reason, changed = download_resource_and_wait(url, 2)
		T(error_reason)["=="](nil)
		T(changed)["=="](true)
		T(type(downloaded_path))["=="]("string")
		T(downloaded_path:find("/file%.ogg$") ~= nil)["=="](true)
		T(fs.is_file(cache_dir .. "/file.ogg"))["=="](true)
		T(fs.exists(cache_dir .. "/file.html"))["=="](false)
		T(fs.exists(cache_dir .. "/file.html.temp"))["=="](false)
	end)

	cleanup_cache_for_url(url)
end)

T.Test("resource.Download clears broken html cache layout before redownload", function()
	local url = "https://example.invalid/broken-cache.ogg"
	local cache_dir = cleanup_cache_for_url(url)
	assert(fs.create_directory_recursive(cache_dir .. "/file.html"))
	assert(fs.write_file(cache_dir .. "/file.html/file.ogg", "old-bad-cache"))
	assert(fs.write_file(cache_dir .. "/file.html.temp", "unfinished"))

	with_mock_socket_download(function(_, on_finish, _, on_chunks, on_header)
		local client = {valid = true}

		function client:IsValid()
			return self.valid
		end

		function client:Close()
			self.valid = false
		end

		timer.Delay(0.01, function()
			if not client.valid then return end

			on_header({["content-type"] = "text/html; charset=utf-8"})
			on_header({["content-type"] = "audio/ogg"})
			on_chunks("fixedogg")
			on_finish("fixedogg")
			client.valid = false
		end)

		return client
	end, function()
		local downloaded_path, error_reason = download_resource_and_wait(url, 2)
		T(error_reason)["=="](nil)
		T(type(downloaded_path))["=="]("string")
		T(downloaded_path:find("/file%.ogg$") ~= nil)["=="](true)
		T(fs.is_file(cache_dir .. "/file.ogg"))["=="](true)
		T(fs.exists(cache_dir .. "/file.html"))["=="](false)
		T(fs.exists(cache_dir .. "/file.html.temp"))["=="](false)
	end)

	cleanup_cache_for_url(url)
end)

T.Test("resource.Download:Get works inside tasks.CreateTask", function()
	local url = "https://example.invalid/chatsounds/list.msgpack"
	local expected_path = "./README.md"
	local finished = false
	local result = nil

	with_virtual_resource(url, function(resolve)
		timer.Delay(0.01, function()
			resolve(expected_path, true)
		end)
	end, function()
		tasks.CreateTask(
			function()
				result = resource.Download(url, nil, nil, true, "msgpack"):Get()
				finished = true
			end,
			nil,
			true
		)

		T.WaitUntil(function()
			return finished
		end, 2)
	end)

	T(result)["=="](expected_path)
	T(fs.is_file(result))["=="](true)
end)

T.Test("pcall must wrap resource.Download:Get in a function", function()
	local url = "https://example.invalid/chatsounds/list.msgpack"
	local expected_path = "./README.md"
	local finished = false
	local ok = nil
	local result = nil

	with_virtual_resource(url, function(resolve)
		timer.Delay(0.01, function()
			resolve(expected_path, true)
		end)
	end, function()
		tasks.CreateTask(
			function()
				ok, result = pcall(resource.Download(url, nil, nil, true, "msgpack"):Get())
				finished = true
			end,
			nil,
			true
		)

		T.WaitUntil(function()
			return finished
		end, 2)
	end)

	T(ok)["=="](false)
	T(type(result))["=="]("string")
	T(result:find("attempt to call", 1, true) ~= nil)["=="](true)
end)

T.Test("pcall(function() ... :Get() end) catches resource.Download rejection", function()
	local url = "https://example.invalid/chatsounds/missing.msgpack"
	local finished = false
	local ok = nil
	local err = nil

	with_virtual_resource(url, function(_, reject)
		timer.Delay(0.01, function()
			reject("expected list.msgpack failure")
		end)
	end, function()
		tasks.CreateTask(
			function()
				ok, err = pcall(function()
					return resource.Download(url, nil, nil, true, "msgpack"):Get()
				end)
				finished = true
			end,
			nil,
			true
		)

		T.WaitUntil(function()
			return finished
		end, 2)
	end)

	T(ok)["=="](false)
	T(type(err))["=="]("string")
	T(#err > 0)["=="](true)
end)