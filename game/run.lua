local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
import("goluwa/pvars.lua").Initialize()
import("goluwa/repl.lua").Initialize()
import("goluwa/filewatcher.lua").Start()
import("goluwa/love/line.lua")
import("goluwa/gmod/gine.lua")

if _G.GRAPHICS then
	local render = import("goluwa/render/render.lua")

	if not render.available then
		logf("[game] Graphics not available - running in headless mode\n")
		_G.GRAPHICS = false
	else
		if not system.GetWindows()[1] then system.OpenWindow(1920, 1080) end

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

do
	local assets = import("goluwa/assets.lua")

	local function register_virtual_texture(path, module_path)
		assets.RegisterVirtualTexture(path, function(_, options)
			local asset = import(module_path)

			if type(asset) == "function" then return asset(options.config) end

			return asset
		end)
	end

	register_virtual_texture("textures/render/blue_noise.lua", "goluwa/render/textures/blue_noise.lua")
	register_virtual_texture("textures/render/glow_line.lua", "goluwa/render/textures/glow_line.lua")
	register_virtual_texture("textures/render/glow_linear.lua", "goluwa/render/textures/glow_linear.lua")
	register_virtual_texture("textures/render/glow_point.lua", "goluwa/render/textures/glow_point.lua")
	register_virtual_texture(
		"textures/render/gradient_linear.lua",
		"goluwa/render/textures/gradient_linear.lua"
	)
	register_virtual_texture("textures/render/metal_frame.lua", "goluwa/render/textures/metal_frame.lua")
end
