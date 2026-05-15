local line = import("lua/line.lua")
local resource = import("goluwa/resource.lua")
local path = resource.Download(
	"https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/lovers/mrrescue.love"
):Get()
line.RunGame(path)
