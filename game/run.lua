local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
import("goluwa/pvars.lua").Initialize()
import("goluwa/repl.lua").Initialize()
import("goluwa/filewatcher.lua").Start()
import("goluwa/love/line.lua")

if _G.GRAPHICS then
	local render = import("goluwa/render/render.lua")

	if not render.available then
		logf("[game] Graphics not available - running in headless mode\n")
		_G.GRAPHICS = false
	else
		render.Initialize({samples = "1"})
		import("goluwa/render2d/render2d.lua").Initialize()
		import("goluwa/render3d/render3d.lua").Initialize()
		import("goluwa/render2d/gfx.lua").Initialize()
		import("goluwa/render3d/model_loader.lua")
	end
end

vfs.AutorunAddons()

if _G.AUDIO then vfs.AutorunAddons("audio/") end

if _G.GRAPHICS then
	print("autorunning graphics addons")
	vfs.AutorunAddons("graphics/")
end

system.KeepAlive("game")

do
	local resource = import("goluwa/resource.lua")
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
	resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)
	vfs.MountAddons("os:downloads/")
	vfs.InitAddons()
end
