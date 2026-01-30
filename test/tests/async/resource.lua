local T = require("test.environment")
local resource = require("resource")
local vfs = require("vfs")

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
