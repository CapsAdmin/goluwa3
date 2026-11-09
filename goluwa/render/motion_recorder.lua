local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local png = import("goluwa/codecs/png.lua")
local fs = import("goluwa/filesystem/fs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local MotionRecorder = {}
MotionRecorder.__index = MotionRecorder
local MotionMap = {}
MotionMap.__index = MotionMap
local float_ptr = ffi.typeof("float *")
local FLOATS_PER_CELL = 4
local state = {}
local pipelines = {}
local PRELUDE = [[
	layout(set = 0, binding = 0, std430) buffer Flow { vec4 flow[]; };
	layout(set = 0, binding = 2) uniform sampler2D prev_tex;
	layout(set = 0, binding = 3) uniform sampler2D cur_tex;

	float luma_of(vec3 color) {
		return sqrt(max(dot(color, vec3(0.2126, 0.7152, 0.0722)), 0.0));
	}

	vec4 fetch_prev(ivec2 pixel) {
		return texelFetch(prev_tex, clamp(pixel, ivec2(0), textureSize(prev_tex, 0) - 1), 0);
	}

	vec4 fetch_cur(ivec2 pixel) {
		return texelFetch(cur_tex, clamp(pixel, ivec2(0), textureSize(cur_tex, 0) - 1), 0);
	}

	float prev_luma(ivec2 pixel) { return luma_of(fetch_prev(pixel).rgb); }
	float cur_luma(ivec2 pixel) { return luma_of(fetch_cur(pixel).rgb); }
	float param(int i) { return i == 0 ? mm.p0 : i == 1 ? mm.p1 : i == 2 ? mm.p2 : mm.p3; }
]]
local MAIN = [[
	void main() {
		ivec2 cell = ivec2(gl_GlobalInvocationID.xy);

		if (cell.x >= mm.cells_x || cell.y >= mm.cells_y) return;

		flow[mm.slot * mm.cells_x * mm.cells_y + cell.y * mm.cells_x + cell.x] = analyze(cell, cell * mm.block);
	}
]]

local function get_pipeline(glsl)
	if pipelines[glsl] then return pipelines[glsl] end

	pipelines[glsl] = EasyPipeline.Compute{
		name = "motion_recorder",
		DescriptorSetCount = 2,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_buffers = {{binding_index = 0}},
		sampled_images = {{binding_index = 2}, {binding_index = 3}},
		uniform_buffers = {
			{
				name = "mm",
				binding_index = 4,
				block = {
					{"cells_x", "int"},
					{"cells_y", "int"},
					{"block", "int"},
					{"slot", "int"},
					{"p0", "float"},
					{"p1", "float"},
					{"p2", "float"},
					{"p3", "float"},
				},
				write = function(self, block)
					block.cells_x = state.cells_x
					block.cells_y = state.cells_y
					block.block = state.block
					block.slot = state.slot
					block.p0, block.p1, block.p2, block.p3 = state.p0, state.p1, state.p2, state.p3
					return block
				end,
			},
		},
		custom_declarations = "",
		shader = PRELUDE .. glsl .. MAIN,
	}
	return pipelines[glsl]
end

MotionRecorder.Diff = {
	block = 4,
	scale = 0.1,
	glsl = [[
		vec4 analyze(ivec2 cell, ivec2 origin) {
			float signed_sum = 0.0;
			float abs_sum = 0.0;
			float cur_sum = 0.0;

			for (int y = 0; y < mm.block; y++) {
				for (int x = 0; x < mm.block; x++) {
					ivec2 pixel = origin + ivec2(x, y);
					float c = cur_luma(pixel);
					float d = c - prev_luma(pixel);
					signed_sum += d;
					abs_sum += abs(d);
					cur_sum += c;
				}
			}

			float n = float(mm.block * mm.block);
			return vec4(signed_sum / n, abs_sum / n, cur_sum / n, 0.0);
		}
	]],
	magnitude = function(x, y)
		return y
	end,
	draw = function(x, y, z, w, scale)
		local v = math.min(y / scale, 1)
		return v, v, v
	end,
}

local function hsv_to_rgb(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i = i % 6

	if i == 0 then return v, t, p end

	if i == 1 then return q, v, p end

	if i == 2 then return p, v, t end

	if i == 3 then return p, q, v end

	if i == 4 then return t, p, v end

	return v, p, q
end

-- block matching: where each cell's content went (xy, in pixels), the match error and the error without any shift. p0 is the search radius, p1 the sample stride
MotionRecorder.Flow = {
	block = 8,
	scale = 8,
	p0 = 8,
	p1 = 2,
	glsl = [[
		float block_difference(ivec2 origin, ivec2 shift) {
			float sum = 0.0;
			float count = 0.0;

			for (int y = 0; y < mm.block; y += int(param(1))) {
				for (int x = 0; x < mm.block; x += int(param(1))) {
					ivec2 pixel = origin + ivec2(x, y);
					sum += abs(cur_luma(pixel) - prev_luma(pixel + shift));
					count += 1.0;
				}
			}

			return sum / count;
		}

		vec4 analyze(ivec2 cell, ivec2 origin) {
			int radius = int(param(0));
			float still = block_difference(origin, ivec2(0));
			float best = still;
			ivec2 best_shift = ivec2(0);

			for (int sy = -radius; sy <= radius; sy++) {
				for (int sx = -radius; sx <= radius; sx++) {
					float difference = block_difference(origin, ivec2(sx, sy));

					if (difference < best - 0.0005) {
						best = difference;
						best_shift = ivec2(sx, sy);
					}
				}
			}

			if (still - best < 0.004) {
				best = still;
				best_shift = ivec2(0);
			}

			vec2 refined = vec2(best_shift);

			if (best_shift != ivec2(0)) {
				for (int axis = 0; axis < 2; axis++) {
					ivec2 step_vec = axis == 0 ? ivec2(1, 0) : ivec2(0, 1);
					float a = block_difference(origin, best_shift - step_vec);
					float b = block_difference(origin, best_shift + step_vec);
					float denominator = a - 2.0 * best + b;

					if (denominator > 1e-5) refined[axis] += clamp(0.5 * (a - b) / denominator, -0.5, 0.5);
				}
			}

			return vec4(-refined, best, still);
		}
	]],
	magnitude = function(x, y)
		return math.sqrt(x * x + y * y)
	end,
	draw = function(x, y, z, w, scale)
		local speed = math.sqrt(x * x + y * y)

		if speed < 0.05 then return 0, 0, 0 end

		return hsv_to_rgb((math.atan2(y, x) / (math.pi * 2)) % 1, 1, math.min(speed / scale, 1))
	end,
}

function MotionRecorder.New(config)
	config = table.merge_many(MotionRecorder.Diff, config or {})
	local self = setmetatable({}, MotionRecorder)
	self.config = config
	self.frames = config.frames or 120
	self.block = config.block
	self.recorded = 0
	self.times = {}
	return self
end

function MotionRecorder:Start()
	local target = render.target:GetTexture()
	self.width = target:GetWidth()
	self.height = target:GetHeight()
	self.cells_x = math.ceil(self.width / self.block)
	self.cells_y = math.ceil(self.height / self.block)
	self.cell_count = self.cells_x * self.cells_y
	self.textures = {}

	for i = 1, 2 do
		self.textures[i] = Texture.New{
			width = self.width,
			height = self.height,
			format = target.format,
			mip_map_levels = 1,
		}
	end

	self.buffer = render.CreateBuffer{
		byte_size = self.frames * self.cell_count * FLOATS_PER_CELL * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent", "host_cached"},
		label = "motion_recorder",
	}
	self.pipeline = get_pipeline(self.config.glsl)
	self.pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, self.buffer, self.buffer:GetSize())
	self.pipeline:UpdateDescriptorSet("storage_buffer", 2, 0, 0, self.buffer, self.buffer:GetSize())
	self.started = false
	self.remove = event.AddListener("PostRenderPass", {}, function()
		self:Capture()
	end)
	return self
end

function MotionRecorder:Capture()
	local cmd = render.GetCommandBuffer()
	local cur = self.textures[self.recorded % 2 + 1]
	local prev = self.textures[(self.recorded + 1) % 2 + 1]
	cur:CopyFrom(render.target:GetTexture(), self.width, self.height, 0, 0, 0, 0)
	render.TransitionResourceTo(
		cur,
		"shader_read_only_optimal",
		{cmd = cmd, srcStage = "transfer", dstStage = "compute"}
	)

	if not self.started then
		self.started = true
		self.recorded = self.recorded + 1
		return
	end

	local slot = self.recorded % 2 + 1
	self.pipeline:BindSampledImage(cmd, slot, 2, prev)
	self.pipeline:BindSampledImage(cmd, slot, 3, cur)
	state.cells_x = self.cells_x
	state.cells_y = self.cells_y
	state.block = self.block
	state.p0, state.p1, state.p2, state.p3 = self.config.p0 or 0, self.config.p1 or 0, self.config.p2 or 0, self.config.p3 or 0
	state.slot = self.recorded - 1
	self.pipeline:UploadConstants()
	self.pipeline.pipeline:Dispatch(
		cmd,
		math.ceil(self.cells_x / 8),
		math.ceil(self.cells_y / 8),
		1,
		slot,
		self.pipeline.dynamic_offsets
	)
	self.times[self.recorded] = system.GetElapsedTime()
	self.recorded = self.recorded + 1

	if self.recorded - 1 >= self.frames then self:Stop() end
end

function MotionRecorder:IsRecording()
	return self.remove ~= nil
end

function MotionRecorder:Stop()
	if self.remove then
		self.remove()
		self.remove = nil
	end

	render.GetDevice():WaitIdle()
	local count = math.min(self.recorded - 1, self.frames)
	local map = setmetatable(
		{
			width = self.width,
			height = self.height,
			cells_x = self.cells_x,
			cells_y = self.cells_y,
			block = self.block,
			config = self.config,
			count = count,
			times = self.times,
			data = ffi.new("float[?]", count * self.cell_count * FLOATS_PER_CELL),
		},
		MotionMap
	)
	ffi.copy(
		map.data,
		ffi.cast(float_ptr, self.buffer:Map()),
		count * self.cell_count * FLOATS_PER_CELL * 4
	)
	self.buffer:Remove()
	self.buffer = nil
	return map
end

-- Records `seconds` of rendering and calls cb(motion_map). opt is a preset (MotionRecorder.Diff, the default, or Flow) or your own:
-- glsl (defines `vec4 analyze(ivec2 cell, ivec2 origin)` for the block of `mm.block` pixels at origin, reading fetch_prev/fetch_cur/prev_luma/cur_luma/param(0..3)),
-- block, p0..p3, frames (max, default seconds * 120), and for the stats and images: magnitude(x, y, z, w) -> number, draw(x, y, z, w, scale) -> r, g, b (0 to 1), scale
function MotionRecorder.Record(seconds, cb, opt)
	opt = opt or {}
	opt = table.merge_many({frames = math.ceil(seconds * 120)}, opt)
	local recorder = MotionRecorder.New(opt)
	local start = system.GetElapsedTime()
	recorder:Start()

	event.AddListener("PostUpdate", {}, function(remove)
		if recorder:IsRecording() and system.GetElapsedTime() - start < seconds then
			return
		end

		if recorder:IsRecording() then cb(recorder:Stop()) end

		return event.destroy_tag
	end)

	return recorder
end

function MotionMap:GetCell(frame, x, y)
	local i = (
			(
				frame - 1
			) * self.cells_x * self.cells_y + y * self.cells_x + x
		) * FLOATS_PER_CELL
	local d = self.data
	return d[i], d[i + 1], d[i + 2], d[i + 3]
end

-- per frame: mean and max of the preset's magnitude, the fraction of cells above `threshold`, and the mean of the 3rd and 4th channels
function MotionMap:GetStats(threshold)
	threshold = threshold or self.config.scale * 0.05
	local stats = {}
	local cells = self.cells_x * self.cells_y
	local magnitude = self.config.magnitude

	for frame = 1, self.count do
		local sum, max, active, z, w = 0, 0, 0, 0, 0
		local base = (frame - 1) * cells * FLOATS_PER_CELL

		for c = 0, cells - 1 do
			local i = base + c * FLOATS_PER_CELL
			local m = magnitude(self.data[i], self.data[i + 1], self.data[i + 2], self.data[i + 3])
			sum = sum + m
			max = math.max(max, m)
			z = z + self.data[i + 2]
			w = w + self.data[i + 3]

			if m >= threshold then active = active + 1 end
		end

		stats[frame] = {
			time = self.times[frame],
			mean = sum / cells,
			max = max,
			active = active / cells,
			z = z / cells,
			w = w / cells,
		}
	end

	return stats
end

local function write_png(path, width, height, pixels)
	local file = png.Encode(width, height, "rgb")
	file:write(pixels)
	assert(fs.create_directory_recursive(file_path.GetFolderFromPath(path)))
	assert(fs.write_file(path, file:getData()))
	return path
end

-- Draws one frame into `pixels` (rgb, row stride `stride` pixels) at (ox, oy) with the preset's draw
function MotionMap:DrawFrame(pixels, stride, ox, oy, frame, zoom, scale)
	scale = scale or self.config.scale

	for cy = 0, self.cells_y - 1 do
		for cx = 0, self.cells_x - 1 do
			local x, y, z, w = self:GetCell(frame, cx, cy)
			local r, g, b = self.config.draw(x, y, z, w, scale)
			r, g, b = math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)

			for sy = 0, zoom - 1 do
				for sx = 0, zoom - 1 do
					local o = ((oy + cy * zoom + sy) * stride + ox + cx * zoom + sx) * 3
					pixels[o], pixels[o + 1], pixels[o + 2] = r, g, b
				end
			end
		end
	end
end

function MotionMap:SaveFrame(frame, path, scale, max_motion)
	scale = scale or 4
	local width, height = self.cells_x * scale, self.cells_y * scale
	local pixels = ffi.new("uint8_t[?]", width * height * 3)
	self:DrawFrame(pixels, width, 0, 0, frame, scale, max_motion)
	return write_png(path, width, height, pixels)
end

-- a contact sheet of every `step`th frame
function MotionMap:SaveSheet(path, columns, step, scale, max_motion)
	columns = columns or 6
	step = step or math.max(1, math.floor(self.count / 24))
	scale = scale or 2
	local frames = {}

	for frame = 1, self.count, step do
		frames[#frames + 1] = frame
	end

	local rows = math.ceil(#frames / columns)
	local tile_w, tile_h = self.cells_x * scale + 2, self.cells_y * scale + 2
	local width, height = columns * tile_w, rows * tile_h
	local pixels = ffi.new("uint8_t[?]", width * height * 3)

	for i, frame in ipairs(frames) do
		self:DrawFrame(
			pixels,
			width,
			((i - 1) % columns) * tile_w,
			math.floor((i - 1) / columns) * tile_h,
			frame,
			scale,
			max_motion
		)
	end

	return write_png(path, width, height, pixels), frames
end

-- where the picture moved over the whole recording: brightness is the mean motion per cell
function MotionMap:SaveHeatmap(path, scale, max_motion)
	scale = scale or 4
	local width, height = self.cells_x * scale, self.cells_y * scale
	local pixels = ffi.new("uint8_t[?]", width * height * 3)

	for cy = 0, self.cells_y - 1 do
		for cx = 0, self.cells_x - 1 do
			local sum = 0

			for frame = 1, self.count do
				sum = sum + self.config.magnitude(self:GetCell(frame, cx, cy))
			end

			local v = math.floor(math.min(sum / self.count / (max_motion or self.config.scale / 4), 1) * 255)

			for sy = 0, scale - 1 do
				for sx = 0, scale - 1 do
					local o = ((cy * scale + sy) * width + cx * scale + sx) * 3
					pixels[o], pixels[o + 1], pixels[o + 2] = v, v, v
				end
			end
		end
	end

	return write_png(path, width, height, pixels)
end

return MotionRecorder
