local T = import("test/environment.lua")
local line = import("goluwa/love/line.lua")
local resource = import("goluwa/resource.lua")

T.Pending("test game", function()
	local path = resource.Download(
		"https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/lovers/mrrescue.love"
	):Get()
	line.RunGame(path)
end)
