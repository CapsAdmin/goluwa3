local commands = import("goluwa/cli/commands.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local ngfx_gputrace = import("goluwa/codecs/ngfx_gputrace.lua")
local CAPTURE_DIRECTORY = "./storage/ngfx_traces/"
local NSIGHT_DIRECTORY = os.getenv("HOME") .. "/Documents/NVIDIA Nsight Graphics/"
local CALIBRATION_DIRECTORY = "./storage/ngfx_calibration/"
local CALIBRATION_MEGABYTES = 8
local CAPTURE_TIMEOUT_SECONDS = 900
local WARMUP_FRAMES = 60

-- trace names end in their capture date, so the greatest name is the newest
local function newest_trace(...)
	local newest, newest_directory

	for _, directory in ipairs{...} do
		for _, name in ipairs(fs.get_files(directory) or {}) do
			if name:ends_with(".ngfx-gputrace") and (not newest or name > newest) then
				newest, newest_directory = name, directory
			end
		end
	end

	return newest and newest_directory .. newest
end

local function find_nsight_cli()
	local configured = os.getenv("NGFX_CLI")

	if configured then return configured end

	local pipe = io.popen("readlink -f \"$(command -v ngfx-ui)\" 2>/dev/null")
	local ui = pipe:read("*l")
	pipe:close()
	assert(
		ui and ui ~= "",
		"ngfx-ui is not on PATH, set NGFX_CLI to the Nsight Graphics ngfx command line tool"
	)
	local directory = ui:match("^(.*)/[^/]+$")

	for _, candidate in ipairs{directory .. "/ngfx", directory .. "/../host/linux-desktop-nomad-x64/ngfx"} do
		if fs.exists(candidate) then return candidate end
	end

	error("could not find the ngfx command line tool next to " .. ui .. ", set NGFX_CLI")
end

-- runs a GPU Trace of `glw <arguments>` with the settings the report relies on and returns the trace path
-- The warp samples come from the real-time shader profiler, which like the metric set is a per architecture
-- option that the command line tool silently ignores unless --architecture names the gpu's architecture.
local function detect_architecture()
	local configured = os.getenv("NGFX_ARCHITECTURE")

	if configured then return configured end

	local pipe = io.popen("nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null")
	local name = pipe:read("*l") or ""
	pipe:close()

	for pattern, architecture in pairs{
		["RTX 50%d%d"] = "Blackwell GB20x",
		["RTX PRO %d+ Blackwell"] = "Blackwell GB20x",
		["RTX 40%d%d"] = "Ada",
		["RTX %d+ Ada"] = "Ada",
		["RTX 30%d%d"] = "Ampere GA10x",
		["RTX A%d+"] = "Ampere GA10x",
		["RTX 20%d%d"] = "Turing",
		["GTX 16%d%d"] = "Turing",
	} do
		if name:find(pattern) then return architecture end
	end

	error(
		"could not tell the Nsight architecture of '" .. name .. "', set NGFX_ARCHITECTURE (Ada, Ampere GA10x, ...)"
	)
end

-- the traced game starts the trace itself (ngfx.StartTrace), from its own script or when the optional
-- GOLUWA_NGFX_CAPTURE trigger fires
local function capture(arguments, environment, trigger, output_directory)
	fs.create_directory_recursive(output_directory)
	local before = newest_trace(output_directory)
	local command = string.format(
		"QT_QPA_PLATFORM=offscreen timeout %d %q --activity %q --exe %q --dir %q --args %q --env %q --start-with-ngfx-sdk --limit-to-frames 1 --architecture %q --metric-set-name %q --real-time-shader-profiler --pc-samples-per-pm-interval-per-sm 10 --allocated-event-buffer-memory-kb 200000 --allocated-timestamps 1000000 --output-dir %q",
		CAPTURE_TIMEOUT_SECONDS,
		find_nsight_cli(),
		"GPU Trace Profiler",
		arg[-1],
		fs.get_current_directory(),
		"glw " .. arguments,
		environment .. (trigger and " GOLUWA_NGFX_CAPTURE=" .. trigger .. ";" or ""),
		detect_architecture(),
		"Top-Level Triage",
		output_directory
	)
	logn("capturing a GPU Trace of glw ", arguments, ", this takes a few minutes")
	os.execute(command)
	local trace = newest_trace(output_directory)
	assert(
		trace and trace ~= before,
		"the capture did not produce a trace in " .. output_directory
	)
	return trace
end

local function run_calibration_scene()
	local render = import("goluwa/render/render.lua")
	local event = import("goluwa/event.lua")
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lines = {}
	local line = {}
	math.randomseed(12345)

	for i = 1, CALIBRATION_MEGABYTES * 1024 * 1024 / 65 do
		for j = 1, 64 do
			local k = math.random(64)
			line[j] = alphabet:sub(k, k)
		end

		lines[i] = table.concat(line)
	end

	-- an incompressible comment that GOLUWA_SHADER_DEBUG embeds in the spir-v, so the trace holds a
	-- blob whose plain text is known for its whole length
	local pipeline = render.CreateComputePipeline{
		name = "ngfx_calibration",
		shader_stages = {
			{
				type = "compute",
				code = "#version 460\nlayout(local_size_x = 1) in;\n/*\n" .. table.concat(lines, "\n") .. "\n*/\nvoid main() {}\n",
				descriptor_sets = {},
			},
		},
	}
	local frames = 0

	event.AddListener("PreRenderPass", "ngfx_calibration", function()
		pipeline:Dispatch(render.GetCommandBuffer(), 1, 1, 1)
		frames = frames + 1

		if frames == WARMUP_FRAMES then
			import("goluwa/bindings/ngfx.lua").StartTrace(render.GetQueue().ptr[0])
		end
	end)
end

commands.Add({
	aliases = "ngfx",
	argtypes = "string|nil",
	flags = {
		screenshot = {
			type = "string",
			description = "Write the png screenshot of the trace to this path",
		},
		capture = {
			type = "string",
			description = "Capture a GPU Trace of `glw <this>` with the Nsight Graphics command line tool, then report it",
		},
		["capture-after"] = {
			type = "string",
			description = "With --capture, when the engine starts the trace: <seconds> after the renderer is ready, or event:<name> for " .. WARMUP_FRAMES .. " frames after that event. Without it the game must start the trace itself (ngfx.StartTrace or the ngfx_capture command)",
		},
		calibrate = {
			type = "boolean",
			description = "Capture the calibration scene and extend the keystream that decodes shader blobs",
		},
		["calibration-scene"] = {
			type = "boolean",
			description = "Run the scene --calibrate captures",
		},
	},
}, function(path, flags)
	if flags["calibration-scene"] then return run_calibration_scene() end

	if flags.calibrate then
		local trace = capture(
			"--2d --background ngfx --calibration-scene",
			"GOLUWA_DUMP_SHADERS=1; GOLUWA_SHADER_DEBUG=1;",
			nil,
			CALIBRATION_DIRECTORY
		)
		logn("keystream is ", ngfx_gputrace.Open(trace):Calibrate(), " bytes")
		system.ShutDown(0)
		return
	end

	if flags.capture then
		path = capture(
			flags.capture,
			"GOLUWA_DUMP_SHADERS=1; GOLUWA_SHADER_DEBUG=1;",
			flags["capture-after"],
			CAPTURE_DIRECTORY
		)
	end

	path = path or
		assert(
			newest_trace(CAPTURE_DIRECTORY, NSIGHT_DIRECTORY),
			"no .ngfx-gputrace in " .. CAPTURE_DIRECTORY .. " or " .. NSIGHT_DIRECTORY
		)
	local trace = ngfx_gputrace.Open(path)
	trace:Calibrate()
	logn(path)
	logn(trace:GetReport())

	if flags.screenshot then
		local file = assert(io.open(flags.screenshot, "wb"))
		file:write(trace:GetScreenshot().png)
		file:close()
		logn("screenshot written to ", flags.screenshot)
	end

	system.ShutDown(0)
end)

local function start_trace()
	local render = import("goluwa/render/render.lua")
	logn("[ngfx] starting the gpu trace")
	import("goluwa/bindings/ngfx.lua").StartTrace(render.GetQueue().ptr[0])
end

commands.Add("ngfx_capture", start_trace)

do
	local trigger = os.getenv("GOLUWA_NGFX_CAPTURE")

	if trigger then
		local event = import("goluwa/event.lua")
		local timer = import("goluwa/timer.lua")
		local event_name = trigger:match("^event:(.+)$")

		event.AddListener("RendererReady", "ngfx_capture", function()
			if not event_name then
				timer.Delay(
					assert(tonumber(trigger), "GOLUWA_NGFX_CAPTURE is seconds or event:<name>"),
					start_trace
				)
				return
			end

			event.AddListener(event_name, "ngfx_capture", function()
				event.RemoveListener(event_name, "ngfx_capture")
				local frames = 0

				event.AddListener("PostDraw", "ngfx_capture", function()
					frames = frames + 1

					if frames == WARMUP_FRAMES then
						event.RemoveListener("PostDraw", "ngfx_capture")
						start_trace()
					end
				end)
			end)
		end)
	end
end
