require("goluwa.global_environment")
--
local crash_trace = import("goluwa/bindings/crash_trace.lua")
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
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local commands = import("goluwa/cli/commands.lua")
local lrun = import("goluwa/lrun.lua")
import.loadfile = vfs.LoadFile
vfs.MountStorageDirectories()
_G.R = vfs.GetAbsolutePath
import("goluwa/test.lua") -- add test command
commands.Add{
	command = "global_flags",
	flags = {
		["fps"] = {type = "number", description = "Limit the fps"},
		["2d"] = {type = "boolean", description = "Run in 2D mode (no 3D or physics)"},
		["3d"] = {
			type = "boolean",
			description = "Run in 3D mode (enable 3D and physics)",
		},
		["3d-simple"] = {
			type = "boolean",
			description = "Run in simple 3D mode",
		},
		["physics"] = {type = "boolean", description = "Enable physics"},
		headless = {type = "boolean", description = "Disable graphics entirely"},
		screenshot = {
			type = "boolean",
			description = "Takes one screenshot at the end of the first frame",
		},
		cli = {type = "boolean", description = "Run in CLI mode (no graphics, limited FPS)"},
		server = {type = "boolean", description = "Run as a dedicated server"},
		["one-frame"] = {type = "boolean", description = "Shut down after the first frame"},
		renderdoc = {type = "boolean", description = "Attach RenderDoc for debugging"},
		no_audio = {type = "boolean", description = "Disable audio"},
	},
	callback = function(...)
		local flags = select(select("#", ...), ...) -- flags is always last
		_G.AUDIO = not flags.no_audio
		_G.SERVER = flags.server
		_G.CLIENT = not SERVER
		_G.RENDER_NOOP = false
		_G.RENDER_2D = not flags.headless and not flags.cli and not flags.server
		_G.RENDER_3D_SIMPLE = flags["3d-simple"]
		_G.RENDER_3D = flags["3d"] or RENDER_3D_SIMPLE
		_G.PHYSICS = RENDER_3D or flags["physics"]

		if flags.renderdoc then
			_G.RENDERDOC = true

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
							"--3d",
							"--renderdoc",
						},
					}
				)
				os.realexit(assert(child:wait()))
			end

			local renderdoc = import("goluwa/bindings/renderdoc.lua")
			renderdoc.init()
			renderdoc.SetCaptureFilePathTemplate(vfs.GetStorageDirectory("root") .. "storage/logs/renderdoc")
			logf("[renderdoc] initialized\n")
		end

		if flags.cli or flags.server or flags.fps then
			local native_threads = import("goluwa/bindings/threads.lua")
			local fps = flags.fps or 30

			event.AddListener("Update", "cli_limit_fps", function()
				native_threads.sleep(1000 / fps)
			end)
		end

		if flags["one-frame"] then
			if system.GetFrameNumber() == 0 then
				event.AddListener("FrameEnd", function()
					system.ShutDown(0)
				end)
			end
		end

		if flags.screenshot then
			local render = import("goluwa/render/render.lua")

			render.Screenshot(function(screenshot_data)
				local path = screenshot_data:Save(nil, true)
				logn("screenshot saved to ", path)
			end)
		end
	end,
}

commands.Add("lua=string", function(code, ...)
	return lrun.Execute(code, {log_error = false, arguments = {...}})
end)

local function run_game()
	import("goluwa/cli/pvars.lua").Initialize()
	import("goluwa/cli/repl.lua").Initialize()
	import("goluwa/filesystem/watcher.lua").Start()
	fs.write_file(".running_pid", tostring(process.current:get_id()))

	event.AddListener("ShutDown", function()
		fs.remove_file(".running_pid")
	end)

	if RENDER_2D then
		local render = import("goluwa/render/render.lua")

		if not render.available then
			logf("[game] Graphics not available - running in headless mode\n")
			_G.RENDER_2D = false
			_G.RENDER_3D_SIMPLE = false
			_G.RENDER_3D = false
		else
			if not system.GetWindows()[1] then
				system.OpenWindow(window_width, window_height)
			end

			render.Initialize({samples = "1"})
			import("goluwa/render2d/render2d.lua").Initialize()
		end
	end

	if RENDER_3D then
		import("goluwa/render3d/render3d.lua").Initialize(
			RENDER_3D_SIMPLE and
				{
					passes = {
						import("goluwa/render3d/passes/gbuffer.lua"),
						import("goluwa/render3d/passes/lighting_simple.lua"),
						import("goluwa/render3d/passes/forward_overlay.lua"),
						import("goluwa/render3d/passes/bloom.lua"),
						import("goluwa/render3d/passes/blit.lua"),
					},
				} or
				nil
		)
	end

	if PHYSICS then import("goluwa/physics.lua") end

	if AUDIO then import("goluwa/audio.lua").Initialize() end

	vfs.AutorunAddons()

	if RENDER_2D then vfs.AutorunAddons("render_2d/") end

	if RENDER_3D then vfs.AutorunAddons("render_3d/") end

	if PHYSICS then vfs.AutorunAddons("physics/") end

	if AUDIO then vfs.AutorunAddons("audio/") end

	if CLIENT then vfs.AutorunAddons("client/") end

	if SERVER then vfs.AutorunAddons("server/") end

	do
		local resource = import("goluwa/resource.lua")
		resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/extras/", true)
		resource.AddProvider("https://raw.githubusercontent.com/CapsAdmin/goluwa-assets/master/base/", true)
		vfs.MountAddons("os:downloads/")
		vfs.InitAddons()
	end

	if RENDER_2D then
		local assets = import("goluwa/assets.lua")

		local function register_virtual_texture(path, module_path)
			assets.RegisterVirtualTexture(path, function(_, options)
				local asset = import(module_path)

				if type(asset) == "function" then return asset(options.config) end

				return asset
			end)
		end

		register_virtual_texture("textures/render/blue_noise.lua", "goluwa/render/textures/blue_noise.lua")
		register_virtual_texture("textures/render/brdf_lut.lua", "goluwa/render/textures/brdf_lut.lua")
		register_virtual_texture("textures/render/glow_line.lua", "goluwa/render/textures/glow_line.lua")
		register_virtual_texture("textures/render/glow_linear.lua", "goluwa/render/textures/glow_linear.lua")
		register_virtual_texture("textures/render/glow_point.lua", "goluwa/render/textures/glow_point.lua")
		register_virtual_texture(
			"textures/render/gradient_linear.lua",
			"goluwa/render/textures/gradient_linear.lua"
		)
		register_virtual_texture("textures/render/metal_frame.lua", "goluwa/render/textures/metal_frame.lua")
	end

	if SERVER or CLIENT then
		import("goluwa/network/network.lua").Initialize()

		if SERVER then commands.RunString("host") end
	end
end

return function(...)
	local args = {...}
	return crash_trace.Run(function()
		if args[1] and commands.IsAdded(args[1]) then
			if not commands.RunArguments(args) then system.ShutDown(1) end
		else
			local remaining_args
			local captured_flags = {}

			for i, arg in ipairs(args) do
				if arg:starts_with("--") then
					table.insert(captured_flags, arg)
				else
					remaining_args = {}

					for i = i, #args do
						table.insert(remaining_args, args[i])
					end

					break
				end
			end

			if captured_flags[1] then
				commands.RunArguments({"global_flags", unpack(captured_flags)})
			else
				commands.RunArguments({"global_flags", "--3d"})
			end

			run_game()

			if remaining_args then
				if not commands.RunArguments(remaining_args) then system.ShutDown(1) end
			end
		end

		system.KeepAlive("game")
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
		os.realexit(os.exitcode)
	end)
end
