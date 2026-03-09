local T = require("test.environment")
local resource = require("resource")
local tasks = require("tasks")
local timer = require("timer")
local vfs = require("vfs")

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
	local done = false
	local downloaded_path = nil
	local error_reason = nil

	resource.Download(url):Then(function(path)
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

T.Test("resource.Download:Get works inside tasks.CreateTask", function()
	local url = "https://example.invalid/chatsounds/list.msgpack"
	local expected_path = "/home/caps/projects/goluwa3/README.md"
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
	T(vfs.Exists(result))["=="](true)
end)

T.Test("pcall must wrap resource.Download:Get in a function", function()
	local url = "https://example.invalid/chatsounds/list.msgpack"
	local expected_path = "/home/caps/projects/goluwa3/README.md"
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