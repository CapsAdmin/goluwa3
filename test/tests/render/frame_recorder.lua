local T = import("test/environment.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local FrameRecorder = import("goluwa/render/frame_recorder.lua")
local SIZE = 16
local STEP = 8

local function draw_moving_square(w, h, frame)
	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, w, h)
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(frame * STEP, 32, SIZE, SIZE)
end

local results = {}

T.Test2DFrames("FrameRecorder stores frames, skips, crops, converts and maps them", 8, function(w, h, frame)
	draw_moving_square(w, h, frame)

	if frame == 1 then
		results.full = nil
		results.small = nil

		FrameRecorder.Record({frames = 6}, function(clip)
			results.full = clip
		end)

		FrameRecorder.Record({
			frames = 3,
			every = 2,
			host = true,
			crop = {0, 0, 0.5, 0.5},
			scale = 0.5,
			channels = {{name = "luma", format = "r8"}},
		}, function(clip)
			results.small = clip
		end)
	end
end)

T.Test("FrameRecorder full clip holds the frames as rendered", function()
	local clip = assert(results.full, "the full recording did not finish")
	T(clip:GetFrameCount())["=="](6)

	for frame = 1, 6 do
		local data = clip:ReadFrame("color", frame)
		local r, g, b = data:GetPixel(frame * STEP + SIZE / 2, 32 + SIZE / 2)
		assert(
			r > 0.9 and g < 0.1 and b < 0.1,
			"frame " .. frame .. " should show the square where it was drawn"
		)
		r, g, b = data:GetPixel((frame + 3) * STEP, 32 + SIZE / 2)
		assert(r < 0.1, "frame " .. frame .. " should be black ahead of the square")
		T(data.meta.rendered)["=="](frame)
	end

	local diff = clip:Diff("color")
	local first = clip:ReadFrame(diff.name, 1)
	local second = clip:ReadFrame(diff.name, 2)
	local square_luma = 0.2126
	T(math.abs(select(1, first:GetPixel(STEP + 1, 33))))["<"](0.001)
	T(select(1, second:GetPixel(2 * STEP + SIZE - 2, 33)))[">"](square_luma * 0.9)
	T(select(1, second:GetPixel(STEP + 1, 33)))["<"](-square_luma * 0.9)
	local stats = clip:Stats(diff.name)
	T(#stats)["=="](6)
	T(stats[1].max)["<"](0.001)
	T(stats[3].max)[">"](square_luma * 0.9)
	T(stats[3].active)[">"](0)
	local variance = clip:ReadFrame(clip:Variance("color").name, 1)
	T(select(4, variance:GetPixel(4 * STEP + 1, 33)))[">"](square_luma * 0.9)
	T(select(2, variance:GetPixel(0, 0)))["<"](0.001)
	local slice = clip:ReadFrame(clip:Slice("color", {row = 32 + SIZE / 2}).name, 1)
	T(slice.height)["=="](6)

	for frame = 1, 6 do
		T(select(1, slice:GetPixel(frame * STEP + 1, frame - 1)))[">"](0.9)
	end

	local flow = clip:ReadFrame(clip:Flow("color", {block = 16, radius = 10}).name, 3)
	T(math.abs(select(1, flow:GetPixel(1, 2)) - STEP))["<="](0.5)
	clip:Remove()
end)

T.Test("FrameRecorder skipping, crop, scale and r8 in host memory", function()
	local clip = assert(results.small, "the small recording did not finish")
	T(clip:GetFrameCount())["=="](3)
	local data = clip:ReadFrame("luma", 1)
	local w, h = data:GetSize()
	T(data.format)["=="]("r8")

	for frame = 1, 3 do
		T(clip:GetFrameMeta(frame).rendered)["=="](frame * 2 - 1)
	end

	local square_x = math.floor((STEP + SIZE / 2) / 2)
	local luma = select(1, data:GetPixel(square_x, math.floor((32 + SIZE / 2) / 2)))
	T(luma)[">"](0.4)
	T(luma)["<"](0.6)
	T(w)[">"](0)
	T(h)[">"](0)
	clip:Remove()
end)

local rolling = {}

T.Test2DFrames("FrameRecorder rolling keeps the last frames and previous() sees the frame before", 7, function(w, h, frame)
	draw_moving_square(w, h, frame)

	if frame == 1 then
		rolling.recorder = FrameRecorder.New{
			frames = 3,
			rolling = true,
			channels = {
				{name = "color"},
				{
					name = "change",
					format = "r16f",
					glsl = [[vec4 preprocess(ivec2 pixel) { return abs(source(pixel) - previous(pixel)); }]],
				},
			},
		}
		rolling.recorder:Start()
	end
end)

T.Test("FrameRecorder rolling clip", function()
	local clip = rolling.recorder:Stop()
	T(clip:GetFrameCount())["=="](3)

	for i = 1, 3 do
		local rendered = clip:GetFrameMeta(i).rendered
		T(rendered)["=="](i + 4)
		local r = clip:ReadFrame("color", i):GetPixel(rendered * STEP + 1, 33)
		T(r)[">"](0.9)
		local change = clip:ReadFrame("change", i):GetPixel(rendered * STEP + SIZE - 2, 33)
		T(change)[">"](0.1)
	end

	clip:Remove()
end)

local noise_run = {}

T.Test2DFrames("FrameRecorder Noise tells flicker from boiling", 48, function(w, h, frame)
	render2d.SetColor(0, 0, 0, 1)
	render2d.DrawRect(0, 0, w, h)
	local flicker = (frame * 7919 % 13) / 13
	render2d.SetColor(flicker, flicker, flicker, 1)
	render2d.DrawRect(32, 32, 64, 64)
	local boil = 0.5 + 0.3 * math.sin(frame / 48 * math.pi * 2)
	render2d.SetColor(boil, boil, boil, 1)
	render2d.DrawRect(160, 32, 64, 64)

	if frame == 1 then
		noise_run.clip = nil

		FrameRecorder.Record({frames = 48, channels = {{name = "color"}, {name = "small", scale = 0.5}}}, function(clip)
			noise_run.clip = clip
		end)
	end
end)

T.Test("FrameRecorder Noise maps", function()
	local clip = assert(noise_run.clip, "the noise recording did not finish")
	local result = clip:Noise("color", {lags = {1, 2, 4, 8}, panel_width = 256})
	local noise = clip:ReadFrame("color_noise", 1)
	local autocorrelation = clip:ReadFrame("color_noise_autocorrelation", 1)
	local _, flicker_a, boil_a = noise:GetPixel(64, 64)
	local _, flicker_b, boil_b = noise:GetPixel(192, 64)
	T(flicker_a)[">"](0.1)
	T(boil_a / flicker_a)["<"](0.6)
	T(boil_b / flicker_b)[">"](2)
	T(select(1, autocorrelation:GetPixel(64, 64)))["<"](0.5)
	T(select(1, autocorrelation:GetPixel(192, 64)))[">"](0.9)
	local a = autocorrelation:GetPixel(300, 300)
	assert(a ~= a, "a pixel that never changes has no autocorrelation")
	T(result.varying_fraction)[">"](0)
	T(result.varying_fraction)["<"](0.2)
	local panel = clip:ReadFrame(result.panel, 1)
	T(panel.width)["=="](256)
	T(panel.height)["=="](256)
	clip:Noise("small", {lags = {1, 2, 4, 8}})
	local small = clip:ReadFrame("small_noise", 1)
	T(small.width)["=="](clip:GetChannel("small").width)
	T(select(2, small:GetPixel(32, 32)))[">"](0.1)
	T(select(2, small:GetPixel(96, 32)))["<"](select(2, small:GetPixel(32, 32)))
	clip:Remove()
end)
