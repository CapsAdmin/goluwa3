require("goluwa.global_environment")
--
local crash_trace = import("goluwa/crash_trace.lua")
crash_trace.Install()
local event = import("goluwa/event.lua")

if false then
	local profiler = import("goluwa/profiler.lua")
	profiler.Start("startup", {trace_recorder = true})

	event.AddListener("Initialize", function()
		profiler.Stop("startup")
	end)
end

local system = import("goluwa/system.lua")
local process = import("goluwa/bindings/process.lua")
local fs = import("goluwa/fs.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local commands = import("goluwa/commands.lua")
import.loadfile = vfs.LoadFile
vfs.MountStorageDirectories()
_G.R = vfs.GetAbsolutePath
import("goluwa/helpers/test.lua") -- add test command
local function init_game()
	import("goluwa/pvars.lua").Initialize()
	import("goluwa/repl.lua").Initialize()
	import("goluwa/filewatcher.lua").Start()

	if _G.GRAPHICS then
		local render = import("goluwa/render/render.lua")

		if not render.available then
			logf("[game] Graphics not available - running in headless mode\n")
			_G.GRAPHICS = false
		else
			if not system.GetWindows()[1] then
				local window_width = 1920
				local window_height = 1080
				local desktop_size = system.GetDesktopSize()

				if desktop_size then
					window_width = math.max(1, math.floor(desktop_size.x / 2))
					window_height = math.max(1, math.floor(desktop_size.y / 2))
				end

				system.OpenWindow(window_width, window_height)
			end

			render.Initialize({samples = "1"})
			import("goluwa/render2d/render2d.lua").Initialize()
			import("goluwa/render2d/gfx.lua").Initialize()

			if _G.GRAPHICS_3D then
				import("goluwa/render3d/render3d.lua").Initialize()
				import("goluwa/render3d/model_loader.lua")
			end

			if _G.PHYSICS then import("goluwa/physics.lua") end
		end
	end

	vfs.AutorunAddons()

	if _G.AUDIO then vfs.AutorunAddons("audio/") end

	if _G.GRAPHICS then
		vfs.AutorunAddons("graphics/")

		if _G.GRAPHICS_3D then vfs.AutorunAddons("graphics_3d/") end
	end

	if _G.PHYSICS then vfs.AutorunAddons("physics/") end

	system.KeepAlive("game")

	do
		local resource = import("goluwa/resource.lua")
		resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
		resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)
		vfs.MountAddons("os:downloads/")
		vfs.InitAddons()
	end

	if _G.GRAPHICS then
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
end

local function normalize_path(path)
	local wdir = vfs.GetStorageDirectory("working_directory")

	if path:starts_with(wdir) then path = path:sub(#wdir + 1, #path) end

	return path
end

commands.Add("run", function(path, ...)
	if _G.GRAPHICS ~= false then _G.GRAPHICS = true end

	_G.AUDIO = true

	event.AddListener("FrameEnd", function()
		system.ShutDown(0)
	end)

	init_game()
	assert(loadfile(normalize_path(path)))(...)
end)

commands.Add("lua", function(code, ...)
	if _G.GRAPHICS ~= false then _G.GRAPHICS = true end

	_G.AUDIO = true

	event.AddListener("FrameEnd", function()
		system.ShutDown(0)
	end)

	init_game()
	assert(loadstring(code))(...)
end)

commands.Add("game=string[3d]", function(mode)
	_G.GRAPHICS = true

	if mode == "3d" then
		_G.GRAPHICS_3D = true
		_G.PHYSICS = true
	elseif mode == "2d" then
		_G.GRAPHICS_3D = false
		_G.PHYSICS = false
	end

	_G.AUDIO = true
	init_game()
end)

commands.Add("cli", function()
	_G.GRAPHICS = false
	_G.AUDIO = true
	_G.GRAPHICS_3D = false
	_G.PHYSICS = false
	fs.write_file(".running_pid", tostring(process.current:get_id()))

	event.AddListener("FrameEnd", function()
		fs.remove_file(".running_pid")
	end)

	init_game()
end)

commands.Add("renderdoc", function()
	if os.getenv("GOLUWA_RENDERDOC_ATTACHED") ~= "1" then
		fs.create_directory_recursive(vfs.GetStorageDirectory("storage") .. "logs/")
		process.setenv("GOLUWA_RENDERDOC_ATTACHED", "1")
		process.setenv("GOLUWA_DISABLE_DYNAMIC_LOGIC_OP", "1")
		local child = assert(
			process.spawn{
				command = "renderdoccmd",
				args = {
					"capture",
					"-d",
					vfs.GetStorageDirectory("working_directory"),
					"-c",
					vfs.GetStorageDirectory("root") .. "storage/logs/renderdoc",
					"-w",
					"luajit",
					"glw",
					"renderdoc",
				},
			}
		)
		os.realexit(assert(child:wait()))
	end

	if _G.GRAPHICS ~= false then _G.GRAPHICS = true end

	_G.AUDIO = true
	_G.RENDER_DISABLE_DYNAMIC_LOGIC_OP = true
	local renderdoc = import("goluwa/bindings/renderdoc.lua")
	renderdoc.init()
	renderdoc.SetCaptureFilePathTemplate(vfs.GetStorageDirectory("root") .. "storage/logs/renderdoc")
	init_game()
	logf("[renderdoc] initialized\n")
end)

local function shutdown_and_exit(code, remove_pid) end

return function(...)
	local args = {...}
	return crash_trace.Run(function()
		if not args[1] then
			args[1] = "game"
		elseif args[1]:ends_with(".lua") then
			args = {"run", args[1], unpack(args, 2)}
		end

		commands.RunArguments(args)
		local last_time = system.GetTime()
		local i = 0
		event.Call("Initialize")

		while system.IsRunning() and not os.exitcode do
			local time = system.GetTime()
			local dt = time - (last_time or 0)
			system.SetFrameTime(dt)
			system.SetFrameNumber(i)
			system.SetElapsedTime(system.GetElapsedTime() + dt)
			event.Call("Update", dt)
			system.SetInternalFrameTime(system.GetTime() - time)
			i = i + 1
			last_time = time
			event.Call("FrameEnd")
		end

		event.Call("ShutDown")
		os.realexit(os.exitcode or 1)
	end)
end
