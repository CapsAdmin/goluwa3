local json = import("goluwa/codecs/json.lua")
local base64 = import("goluwa/codecs/base64.lua")
local callback = import("goluwa/callback.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local FrameRecorder = import("goluwa/render/frame_recorder.lua")
local mcp = import("addons/mcp/lua/mcp.lua")

local function wait_frames(count)
	local cb = callback.Create()
	local seen = 0

	event.AddListener("PostUpdate", {}, function()
		seen = seen + 1

		if seen < count then return end

		cb:Resolve()
		return event.destroy_tag
	end)

	cb:Get()
end

mcp.AddTool(
	"record_noise",
	{
		description = "Record frames of what is rendered and measure its temporal noise on the gpu: flicker (frame to frame change), boil (variation of a moving average, slow blotches) and how long the noise stays correlated. Returns the numbers and one image with four quarters: middle frame with the slice row in cyan, flicker heat, boil heat (same scale), and that row stacked over time (time runs down, each column's mean removed and contrast stretched). Optionally loads a saved view and sets runtime pvars first (restored afterwards; build time pvars need GOLUWA_PVARS at launch).",
		inputSchema = {
			type = "object",
			properties = {
				map = {
					type = "string",
					description = "Saved view scene, e.g. a3_hotel_street. Needs view.",
				},
				view = {type = "string", description = "Saved view name, e.g. appartment2."},
				ev_offset = {
					type = "number",
					description = "Stops darker than the saved view's exposure, so bright debug views do not clip.",
				},
				pvars = {
					type = "object",
					description = "Runtime pvars to set for the recording, e.g. {\"radiance_debug\": true}.",
				},
				frames = {
					type = "integer",
					description = "Frames to record (default 300). Must exceed the largest lag (64).",
				},
				settle = {
					type = "integer",
					description = "Frames to wait before recording (default 120).",
				},
				source = {
					type = "string",
					description = "\"output\" (presented image, 8 bit, default) or \"scene\" (hdr before tonemapping, stored as r32f luma, sees changes below one 8 bit step).",
				},
				row = {
					type = "number",
					description = "Slice row as a fraction of the height (default 0.5).",
				},
				video = {
					type = "boolean",
					description = "Also save an h264 mp4 of the recording (output source only).",
				},
				inline = {
					type = "boolean",
					description = "Return the panel image in the response (default true).",
				},
			},
		},
		callback = function(args)
			local out = vfs.GetStorageDirectory("storage") .. "mcp/noise_" .. mcp.Role .. "/"
			assert(fs.create_directory_recursive(out))
			local source = args.source or "output"
			local frames = args.frames or 300
			local restore = {}

			for key, value in pairs(args.pvars or {}) do
				restore[key] = pvars.Get(key)
				pvars.SetSession(key, value)
			end

			if args.view then
				local saved_views = import("lua/saved_views.lua")
				local cb = callback.Create()

				saved_views.Apply(args.map, args.view, function(view, entry)
					if args.ev_offset then view:SetExposureLock(entry.ev + args.ev_offset) end

					cb:Resolve()
				end)

				cb:Get()
			end

			wait_frames(args.settle or 120)
			local cb = callback.Create()

			FrameRecorder.Record({
				frames = frames,
				fixed_dt = 1 / 60,
				host = true,
				channels = {
					{
						name = "frames",
						source = source,
						format = source == "scene" and "r32f" or "rgba8",
					},
				},
			}, function(clip)
				cb:Resolve(clip)
			end)

			local clip = cb:Get()

			for key, value in pairs(restore) do
				pvars.SetSession(key, value)
			end

			local ok, result = pcall(function()
				local channel = clip:GetChannel("frames")
				local noise = clip:Noise("frames", {row = math.floor(channel.height * (args.row or 0.5))})
				noise.panel_path = clip:SaveFrame(noise.panel, 1, out .. "panel.png")

				if args.video and source == "output" then
					noise.video_path = clip:SaveVideo(
						"frames",
						out .. "recording.mp4",
						{fps = 60, codec_args = {"-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p"}}
					)
				end

				noise.frames = clip:GetFrameCount()
				noise.source = source
				noise.size = {channel.width, channel.height}
				noise.panel = nil
				noise.reading = "flicker and boil are mean luma change in the source's units (srgb encoded 0..1 for output, linear for scene); relative_* divide by the mean luma. correlation is boil_ratio over what uncorrelated per frame noise would give: about 1 is fresh noise every frame, well above 1 is blotches that persist and drift. autocorrelation is the mean correlation of a pixel with itself `lags` frames later over pixels that vary; lifetime is the lag in frames where it falls to 0.5."
				return noise
			end)
			clip:Remove()

			if not ok then
				return {content = {{type = "text", text = tostring(result)}}, isError = true}
			end

			local content = {{type = "text", text = json.encode(result)}}

			if args.inline ~= false then
				local file = assert(io.open(result.panel_path, "rb"))
				table.insert(content, mcp.Image(base64.Encode(file:read("*a")), "image/png"))
				file:close()
			end

			return {content = content}
		end,
	}
)
