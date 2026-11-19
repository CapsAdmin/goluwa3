local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local png = import("goluwa/codecs/png.lua")
local fs = import("goluwa/filesystem/fs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local process = import("goluwa/bindings/process.lua")
local FrameRecorder = {}
FrameRecorder.__index = FrameRecorder
local Clip = {}
Clip.__index = Clip
FrameRecorder.Clip = Clip
local Frame = {}
Frame.__index = Frame
FrameRecorder.CHUNK_BYTES = 256 * 1024 * 1024
FrameRecorder.FORMATS = {
	rgba8 = {code = 0, bytes = 4, components = 4, element = "uint8_t", element_bytes = 1},
	r8 = {code = 1, bytes = 1, components = 1, element = "uint8_t", element_bytes = 1},
	r16f = {code = 2, bytes = 2, components = 1, element = "uint16_t", element_bytes = 2},
	rg16f = {code = 3, bytes = 4, components = 2, element = "uint16_t", element_bytes = 2},
	rgba16f = {code = 4, bytes = 8, components = 4, element = "uint16_t", element_bytes = 2},
	r32f = {code = 5, bytes = 4, components = 1, element = "float", element_bytes = 4},
	rg32f = {code = 6, bytes = 8, components = 2, element = "float", element_bytes = 4},
	rgba32f = {code = 7, bytes = 16, components = 4, element = "float", element_bytes = 4},
}
local ChannelInfo = ffi.typeof([[struct {
	uint64_t frames;
	int32_t width, height, words_per_row, format, count, pad;
}]])
local ChannelInfoArray = ffi.typeof("$[?]", ChannelInfo)
local uint64_ptr = ffi.typeof("uint64_t *")
local float_ptr = ffi.typeof("float *")
local BufferCopy = ffi.typeof("$[1]", import("goluwa/bindings/vk.lua").VkBufferCopy)
local COMMON = [[
	layout(buffer_reference, scalar) buffer FrameWords { uint w[]; };
	layout(buffer_reference, scalar) readonly buffer FrameAddresses { uint64_t a[]; };
	struct ChannelInfo { uint64_t frames; int width; int height; int words_per_row; int format; int count; int pad; };
	layout(buffer_reference, scalar) readonly buffer ChannelInfos { ChannelInfo c[]; };
	layout(buffer_reference, scalar) readonly buffer FrameMetas { vec4 m[]; };

	float luma(vec4 v) { return dot(v.rgb, vec3(0.2126, 0.7152, 0.0722)); }
	vec3 recorder_to_linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045))); }
	vec3 recorder_to_srgb(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, greaterThan(c, vec3(0.0031308))); }

	vec4 decode_pixel(uint64_t address, int row, int x, int format) {
		FrameWords f = FrameWords(address);

		if (format == 0) return unpackUnorm4x8(f.w[row + x]);

		if (format == 1) {
			float v = float((f.w[row + (x >> 2)] >> uint(8 * (x & 3))) & 255u) / 255.0;
			return vec4(v, v, v, 1.0);
		}

		if (format == 2) {
			float v = unpackHalf2x16(f.w[row + (x >> 1)])[x & 1];
			return vec4(v, v, v, 1.0);
		}

		if (format == 3) return vec4(unpackHalf2x16(f.w[row + x]), 0.0, 1.0);

		if (format == 4) return vec4(unpackHalf2x16(f.w[row + x * 2]), unpackHalf2x16(f.w[row + x * 2 + 1]));

		if (format == 5) {
			float v = uintBitsToFloat(f.w[row + x]);
			return vec4(v, v, v, 1.0);
		}

		if (format == 6) return vec4(uintBitsToFloat(f.w[row + x * 2]), uintBitsToFloat(f.w[row + x * 2 + 1]), 0.0, 1.0);

		return uintBitsToFloat(uvec4(f.w[row + x * 4], f.w[row + x * 4 + 1], f.w[row + x * 4 + 2], f.w[row + x * 4 + 3]));
	}
]]
local STORE = [[
	void store_group(uint64_t address, ivec2 group, ivec2 size, int words_per_row, int format) {
		FrameWords f = FrameWords(address);
		int row = group.y * words_per_row;

		if (format == 0) {
			f.w[row + group.x] = packUnorm4x8(produce(group));
		} else if (format == 1) {
			uint word = 0u;

			for (int i = 0; i < 4; i++) {
				int x = group.x * 4 + i;

				if (x < size.x) word |= uint(clamp(produce(ivec2(x, group.y)).r, 0.0, 1.0) * 255.0 + 0.5) << uint(8 * i);
			}

			f.w[row + group.x] = word;
		} else if (format == 2) {
			vec2 v = vec2(0.0);

			for (int i = 0; i < 2; i++) {
				int x = group.x * 2 + i;

				if (x < size.x) v[i] = produce(ivec2(x, group.y)).r;
			}

			f.w[row + group.x] = packHalf2x16(v);
		} else if (format == 3) {
			f.w[row + group.x] = packHalf2x16(produce(group).xy);
		} else if (format == 4) {
			vec4 v = produce(group);
			f.w[row + group.x * 2] = packHalf2x16(v.xy);
			f.w[row + group.x * 2 + 1] = packHalf2x16(v.zw);
		} else if (format == 5) {
			f.w[row + group.x] = floatBitsToUint(produce(group).r);
		} else if (format == 6) {
			vec2 v = produce(group).xy;
			f.w[row + group.x * 2] = floatBitsToUint(v.x);
			f.w[row + group.x * 2 + 1] = floatBitsToUint(v.y);
		} else {
			vec4 v = produce(group);

			for (int i = 0; i < 4; i++) f.w[row + group.x * 4 + i] = floatBitsToUint(v[i]);
		}
	}

	void main() {
		ivec2 group = ivec2(gl_GlobalInvocationID.xy);

		if (group.x >= compute.groups_per_row || group.y >= compute.dst_height) return;

		store_group(compute.dst, group, output_size(), compute.words_per_row, compute.format);
	}
]]
local PARAMS = [[
	ivec2 output_size() { return ivec2(compute.dst_width, compute.dst_height); }
	float param(int i) { return i == 0 ? compute.p0 : i == 1 ? compute.p1 : i == 2 ? compute.p2 : compute.p3; }
]]
FrameRecorder.BOX_AVERAGE = [[
	vec4 preprocess(ivec2 pixel) {
		vec2 ratio = vec2(source_size()) / vec2(output_size());
		ivec2 a = ivec2(floor(vec2(pixel) * ratio));
		ivec2 b = max(ivec2(ceil(vec2(pixel + 1) * ratio)), a + 1);
		vec4 sum = vec4(0.0);

		for (int y = a.y; y < b.y; y++) {
			for (int x = a.x; x < b.x; x++) {
				sum += source(ivec2(x, y));
			}
		}

		return sum / float((b.x - a.x) * (b.y - a.y));
	}
]]
local state = {}

local function write_store_constants(block)
	block.dst = state.dst
	block.dst_width, block.dst_height = state.width, state.height
	block.words_per_row = state.words_per_row
	block.groups_per_row = state.groups_per_row
	block.format = state.format
	block.p0, block.p1, block.p2, block.p3 = state.p0, state.p1, state.p2, state.p3
end

local get_capture_pipeline

do
	local pipelines = {}

	function get_capture_pipeline(glsl)
		if pipelines[glsl] then return pipelines[glsl] end

		pipelines[glsl] = EasyPipeline.Compute{
			name = "frame_recorder_capture",
			DescriptorSetCount = 1,
			LocalSize = {x = 8, y = 8, z = 1},
			block = {
				{"dst", "uint64_t"},
				{"src_x", "int"},
				{"src_y", "int"},
				{"src_width", "int"},
				{"src_height", "int"},
				{"dst_width", "int"},
				{"dst_height", "int"},
				{"src_tex", "int"},
				{"prev_tex", "int"},
				{"words_per_row", "int"},
				{"groups_per_row", "int"},
				{"format", "int"},
				{"decode", "int"},
				{"encode", "int"},
				{"luma", "int"},
				{"exposure", "float"},
				{"p0", "float"},
				{"p1", "float"},
				{"p2", "float"},
				{"p3", "float"},
			},
			write = function(self, block)
				write_store_constants(block)
				block.src_x, block.src_y = state.src_x, state.src_y
				block.src_width, block.src_height = state.src_w, state.src_h
				block.src_tex = state.src_tex
				block.prev_tex = state.prev_tex
				block.decode = state.decode
				block.encode = state.encode
				block.luma = state.luma
				block.exposure = state.exposure
				return block
			end,
			shader = COMMON .. [[
				ivec2 source_size() { return ivec2(compute.src_width, compute.src_height); }

				vec4 recorder_fetch(int index, ivec2 p) {
					p = clamp(p, ivec2(0), source_size() - 1) + ivec2(compute.src_x, compute.src_y);
					vec4 v = texelFetch(TEXTURE(index), p, 0);

					if (compute.decode != 0) v.rgb = recorder_to_linear(v.rgb);

					return v;
				}

				vec4 source(ivec2 p) { return recorder_fetch(compute.src_tex, p); }
				vec4 previous(ivec2 p) { return recorder_fetch(compute.prev_tex, p); }
			]] .. PARAMS .. glsl .. [[
				vec4 produce(ivec2 pixel) {
					vec4 v = preprocess(pixel);

					if (compute.luma != 0) v.rgb = vec3(luma(v));

					v.rgb *= compute.exposure;

					if (compute.encode != 0) v.rgb = recorder_to_srgb(clamp(v.rgb, 0.0, 1.0));

					return v;
				}
			]] .. STORE,
		}
		return pipelines[glsl]
	end
end

local function allocate_channel(config)
	local format = FrameRecorder.FORMATS[config.format] or
		error("unknown frame recorder format " .. tostring(config.format), 3)
	local words_per_row = math.ceil(config.width * format.bytes / 4)
	local frame_bytes = words_per_row * 4 * config.height
	local stride = math.ceil(frame_bytes / 256) * 256
	local per_chunk = math.max(1, math.floor(FrameRecorder.CHUNK_BYTES / stride))
	local channel = {
		name = config.name,
		format = config.format,
		format_info = format,
		width = config.width,
		height = config.height,
		words_per_row = words_per_row,
		groups_per_row = format.bytes < 4 and words_per_row or config.width,
		frame_bytes = frame_bytes,
		count = config.count,
		host = config.host,
		buffers = {},
		frames = {},
	}
	local remaining = config.count

	while remaining > 0 do
		local n = math.min(per_chunk, remaining)
		local buffer = render.CreateBuffer{
			byte_size = n * stride,
			buffer_usage = {"storage_buffer", "shader_device_address", "transfer_src"},
			memory_property = config.host and
				{"host_visible", "host_coherent", "host_cached"} or
				{"device_local"},
			label = "frame_recorder " .. config.name,
		}
		local base = buffer:GetDeviceAddress()
		table.insert(channel.buffers, buffer)

		for i = 0, n - 1 do
			table.insert(channel.frames, {buffer = buffer, offset = i * stride, address = base + i * stride})
		end

		remaining = remaining - n
	end

	channel.table = render.CreateBuffer{
		byte_size = config.count * 8,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		label = "frame_recorder " .. config.name .. " table",
	}
	return channel
end

local function write_channel_table(channel)
	local table_ptr = ffi.cast(uint64_ptr, channel.table:Map())

	for i, frame in ipairs(channel.frames) do
		table_ptr[i - 1] = frame.address
	end

	channel.table:Unmap()
end

local function remove_channel(channel)
	for _, buffer in ipairs(channel.buffers) do
		buffer:Remove()
	end

	channel.table:Remove()
	channel.buffers = {}
	channel.frames = {}
end

function FrameRecorder.New(config)
	local defaults = {frames = 120, every = 1, scale = 1, exposure = 1}

	for k, v in pairs(config or {}) do
		defaults[k] = v
	end

	config = defaults
	assert(config.frames > 0, "frame recorder needs room for at least one frame")
	local self = setmetatable({config = config}, FrameRecorder)
	self.channel_configs = {}

	for _, channel in ipairs(config.channels or {{name = "color"}}) do
		local source = channel.source or "output"
		local format = channel.format or "rgba8"
		local info = FrameRecorder.FORMATS[format] or
			error("unknown frame recorder format " .. tostring(format), 2)
		local color = source == "output" or source == "scene"
		local merged = {
			source = source,
			format = format,
			scale = config.scale,
			crop = config.crop,
			exposure = config.exposure,
			encode = color and (format == "rgba8" or format == "r8") and "srgb" or "none",
			luma = color and info.components == 1,
			glsl = FrameRecorder.BOX_AVERAGE,
		}

		for k, v in pairs(channel) do
			merged[k] = v
		end

		table.insert(self.channel_configs, merged)
	end

	return self
end

local function resolve_source(source)
	if source == "output" then return render.target:GetOutputTexture() end

	if type(source) == "function" then return source() end

	if source == "scene" then
		return import("goluwa/render3d/post_source.lua").GetSceneSourceTexture({name = "blit_compute"})
	end

	if type(source) == "string" then
		local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")

		if source == "depth" then return gbuffer_layout.GetDepthTexture() end

		return assert(
			gbuffer_layout.attachment_index[source] and gbuffer_layout.GetTexture(source),
			"no gbuffer texture named " .. source
		)
	end

	return source
end

function FrameRecorder:Start()
	assert(not self.remove, "frame recorder is already recording")
	self.channels = {}
	self.rendered = 0
	self.stored = 0
	self.meta = {}

	for _, config in ipairs(self.channel_configs) do
		local texture = resolve_source(config.source)
		local crop = config.crop or {0, 0, 1, 1}
		local src_x = math.floor(crop[1] * texture:GetWidth())
		local src_y = math.floor(crop[2] * texture:GetHeight())
		local src_w = math.max(1, math.floor(crop[3] * texture:GetWidth()))
		local src_h = math.max(1, math.floor(crop[4] * texture:GetHeight()))
		local channel = allocate_channel{
			name = config.name,
			format = config.format,
			width = config.width or math.max(1, math.floor(src_w * config.scale + 0.5)),
			height = config.height or math.max(1, math.floor(src_h * config.scale + 0.5)),
			count = self.config.frames,
			host = self.config.host,
		}
		channel.config = config
		channel.src_x, channel.src_y, channel.src_w, channel.src_h = src_x, src_y, src_w, src_h
		channel.source_width, channel.source_height = texture:GetWidth(), texture:GetHeight()
		channel.pipeline = get_capture_pipeline(config.glsl)
		channel.uses_previous = config.glsl:find("previous%s*%(") ~= nil

		if config.source == "output" or channel.uses_previous then
			channel.copies = {}

			for i = 1, channel.uses_previous and 2 or 1 do
				channel.copies[i] = Texture.New{
					width = texture:GetWidth(),
					height = texture:GetHeight(),
					format = texture.format,
					mip_map_levels = 1,
				}
			end
		end

		channel.decode = config.source == "output" and not texture.format:find("srgb") and 1 or 0
		table.insert(self.channels, channel)
	end

	if self.config.fixed_dt then
		self.previous_fixed_dt = system.GetFixedFrameTime()
		system.SetFixedFrameTime(self.config.fixed_dt)
	end

	self.remove = event.AddListener("PostRenderPass", {}, function(cmd)
		self:Capture(cmd)
	end)
	return self
end

function FrameRecorder:IsRecording()
	return self.remove ~= nil
end

function FrameRecorder:Capture(cmd)
	self.rendered = self.rendered + 1
	local keep

	if self.config.fps then
		local time = system.GetElapsedTime()
		keep = not self.next_time or time >= self.next_time - 0.000001

		if keep then
			self.next_time = math.max((self.next_time or time) + 1 / self.config.fps, time)
		end
	else
		keep = (self.rendered - 1) % self.config.every == 0
	end

	local slot = self.stored % self.config.frames + 1

	for _, channel in ipairs(self.channels) do
		local texture = resolve_source(channel.config.source)

		if
			texture:GetWidth() ~= channel.source_width or
			texture:GetHeight() ~= channel.source_height
		then
			error("frame recorder source " .. channel.name .. " changed size while recording")
		end

		local current = texture
		local previous = texture

		if channel.copies and (keep or channel.uses_previous) then
			current = channel.copies[self.rendered % #channel.copies + 1]
			previous = channel.copies[(self.rendered + 1) % #channel.copies + 1]
			current:CopyFrom(texture, texture:GetWidth(), texture:GetHeight(), 0, 0, 0, 0)
			render.TransitionResourceToShaderRead(current, {cmd = cmd, srcStage = "transfer", srcAccess = "transfer_write"})

			if self.rendered == 1 then previous = current end
		elseif keep then
			render.TransitionResourceToShaderRead(texture, {cmd = cmd, srcStage = "all_commands"})
		end

		if keep then
			local config = channel.config
			state.dst = channel.frames[slot].address
			state.width, state.height = channel.width, channel.height
			state.words_per_row = channel.words_per_row
			state.groups_per_row = channel.groups_per_row
			state.format = channel.format_info.code
			state.src_x, state.src_y, state.src_w, state.src_h = channel.src_x, channel.src_y, channel.src_w, channel.src_h
			state.src_tex = channel.pipeline:GetTextureIndex(current)
			state.prev_tex = channel.pipeline:GetTextureIndex(previous)
			state.decode = channel.decode
			state.encode = config.encode == "srgb" and 1 or 0
			state.luma = config.luma and 1 or 0
			state.exposure = config.exposure
			state.p0, state.p1, state.p2, state.p3 = config.p0 or 0, config.p1 or 0, config.p2 or 0, config.p3 or 0
			channel.pipeline:Dispatch(
				cmd,
				math.ceil(channel.groups_per_row / 8),
				math.ceil(channel.height / 8),
				1,
				1
			)
		end
	end

	if not keep then return end

	local meta = {
		time = system.GetElapsedTime(),
		frame = system.GetFrameNumber(),
		rendered = self.rendered,
	}

	if self.config.on_frame then self.config.on_frame(meta) end

	self.meta[slot] = meta
	self.stored = self.stored + 1

	if not self.config.rolling and self.stored >= self.config.frames then
		self.remove()
		self.remove = nil
		self.full = true
	end
end

function FrameRecorder:Stop()
	if self.remove then
		self.remove()
		self.remove = nil
	end

	if self.config.fixed_dt then system.SetFixedFrameTime(self.previous_fixed_dt) end

	render.GetDevice():WaitIdle()
	local count = math.min(self.stored, self.config.frames)
	local first = self.stored > self.config.frames and self.stored % self.config.frames or 0
	local clip = setmetatable(
		{
			channels = {},
			by_name = {},
			frames = {},
			count = count,
			host = self.config.host,
		},
		Clip
	)

	for i = 1, count do
		clip.frames[i] = self.meta[(first + i - 1) % self.config.frames + 1]
	end

	for _, channel in ipairs(self.channels) do
		if channel.copies then
			for _, texture in ipairs(channel.copies) do
				channel.pipeline:ReleaseTextureIndex(texture)
				texture:Remove()
			end

			channel.copies = nil
		end

		local frames = {}

		for i = 1, count do
			frames[i] = channel.frames[(first + i - 1) % self.config.frames + 1]
		end

		channel.frames = frames
		channel.count = count
		channel.pipeline = nil
		clip:AddChannel(channel)
	end

	self.channels = nil
	clip:WriteMeta()
	return clip
end

function FrameRecorder.Record(config, cb)
	local recorder = FrameRecorder.New(config)
	recorder.config.rolling = false
	recorder:Start()

	event.AddListener("PostUpdate", {}, function()
		if not recorder.full then return end

		cb(recorder:Stop())
		return event.destroy_tag
	end)

	return recorder
end

function Clip:AddChannel(channel)
	assert(
		not self.by_name[channel.name],
		"clip already has a channel named " .. channel.name
	)
	write_channel_table(channel)
	table.insert(self.channels, channel)
	self.by_name[channel.name] = channel
	self.infos_dirty = true
	return channel
end

function Clip:GetChannel(name)
	return self.by_name[name] or error("clip has no channel named " .. tostring(name), 2)
end

function Clip:GetFrameCount()
	return self.count
end

function Clip:GetFrameMeta(frame)
	return self.frames[frame]
end

function Clip:WriteMeta()
	self.meta_buffer = render.CreateBuffer{
		byte_size = math.max(self.count, 1) * 16,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		label = "frame_recorder meta",
	}
	local ptr = ffi.cast(float_ptr, self.meta_buffer:Map())

	for i, meta in ipairs(self.frames) do
		local previous = self.frames[i - 1] or meta
		ptr[(i - 1) * 4 + 0] = meta.time
		ptr[(i - 1) * 4 + 1] = meta.time - previous.time
		ptr[(i - 1) * 4 + 2] = meta.rendered
		ptr[(i - 1) * 4 + 3] = meta.frame
	end

	self.meta_buffer:Unmap()
end

function Clip:GetInfosAddress()
	if self.infos_dirty then
		if self.infos then self.infos:Remove() end

		local infos = ChannelInfoArray(#self.channels)

		for i, channel in ipairs(self.channels) do
			local info = infos[i - 1]
			info.frames = channel.table:GetDeviceAddress()
			info.width = channel.width
			info.height = channel.height
			info.words_per_row = channel.words_per_row
			info.format = channel.format_info.code
			info.count = channel.count
		end

		self.infos = render.CreateBuffer{
			byte_size = ffi.sizeof(infos),
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "frame_recorder channels",
		}
		self.infos:CopyData(infos, ffi.sizeof(infos))
		self.infos_dirty = false
	end

	return self.infos:GetDeviceAddress()
end

local get_map_pipeline

do
	local pipelines = {}

	function get_map_pipeline(clip, glsl)
		local defines = {}

		for i, channel in ipairs(clip.channels) do
			defines[i] = "const int " .. channel.name .. " = " .. (i - 1) .. ";"
		end

		local key = table.concat(defines, "\n") .. "\n" .. glsl

		if pipelines[key] then return pipelines[key] end

		pipelines[key] = EasyPipeline.Compute{
			name = "frame_recorder_map",
			DescriptorSetCount = 1,
			LocalSize = {x = 8, y = 8, z = 1},
			block = {
				{"dst", "uint64_t"},
				{"channels", "uint64_t"},
				{"meta", "uint64_t"},
				{"dst_width", "int"},
				{"dst_height", "int"},
				{"frame", "int"},
				{"frame_count", "int"},
				{"words_per_row", "int"},
				{"groups_per_row", "int"},
				{"format", "int"},
				{"p0", "float"},
				{"p1", "float"},
				{"p2", "float"},
				{"p3", "float"},
			},
			write = function(self, block)
				write_store_constants(block)
				block.channels = state.channels
				block.meta = state.meta
				block.frame = state.frame
				block.frame_count = state.frame_count
				return block
			end,
			shader = COMMON .. table.concat(defines, "\n") .. [[

				ChannelInfo channel_info(int channel) { return ChannelInfos(compute.channels).c[channel]; }
				ivec2 channel_size(int channel) { ChannelInfo c = channel_info(channel); return ivec2(c.width, c.height); }
				int channel_frames(int channel) { return channel_info(channel).count; }
				int frame_count() { return compute.frame_count; }
			]] .. PARAMS .. [[
				vec4 frame_meta(int frame) { return FrameMetas(compute.meta).m[clamp(frame, 0, frame_count() - 1)]; }

				vec4 fetch(int channel, int frame, ivec2 pixel) {
					ChannelInfo c = channel_info(channel);
					frame = clamp(frame, 0, c.count - 1);
					pixel = clamp(pixel, ivec2(0), ivec2(c.width, c.height) - 1);
					return decode_pixel(FrameAddresses(c.frames).a[frame], pixel.y * c.words_per_row, pixel.x, c.format);
				}
			]] .. glsl .. [[
				vec4 produce(ivec2 pixel) { return map(compute.frame, pixel); }
			]] .. STORE,
		}
		return pipelines[key]
	end
end

function Clip:Map(config)
	local first = self.channels[1]
	local frames = config.frames or self.count
	local pipeline = get_map_pipeline(self, config.glsl)
	local channel = allocate_channel{
		name = config.name,
		format = config.format or "rgba16f",
		width = config.width or first.width,
		height = config.height or first.height,
		count = frames,
		host = config.host or self.host,
	}
	write_channel_table(channel)
	local infos = self:GetInfosAddress()
	local batch = config.batch or 4

	for batch_first = 1, frames, batch do
		local cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()

		for frame = batch_first, math.min(batch_first + batch - 1, frames) do
			state.dst = channel.frames[frame].address
			state.width, state.height = channel.width, channel.height
			state.words_per_row = channel.words_per_row
			state.groups_per_row = channel.groups_per_row
			state.format = channel.format_info.code
			state.channels = infos
			state.meta = self.meta_buffer:GetDeviceAddress()
			state.frame = frame - 1
			state.frame_count = self.count
			state.p0, state.p1, state.p2, state.p3 = config.p0 or 0, config.p1 or 0, config.p2 or 0, config.p3 or 0
			pipeline:Dispatch(
				cmd,
				math.ceil(channel.groups_per_row / 8),
				math.ceil(channel.height / 8),
				1,
				1
			)
		end

		cmd:PipelineBarrier{srcStage = "compute", dstStage = "all_commands", memoryBarrier = true}
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Remove()
	end

	return self:AddChannel(channel)
end

function Clip:Diff(source, config)
	config = config or {}
	local block = config.block or 1
	local size = self:GetChannel(source)
	return self:Map{
		name = config.name or source .. "_diff",
		format = config.format or "rgba16f",
		width = math.ceil(size.width / block),
		height = math.ceil(size.height / block),
		p0 = block,
		glsl = ([[
			vec4 map(int frame, ivec2 cell) {
				int block = int(param(0));
				vec3 sum = vec3(0.0);

				for (int y = 0; y < block; y++) {
					for (int x = 0; x < block; x++) {
						ivec2 pixel = cell * block + ivec2(x, y);
						float current = luma(fetch(SOURCE, frame, pixel));
						float delta = frame > 0 ? current - luma(fetch(SOURCE, frame - 1, pixel)) : 0.0;
						sum += vec3(delta, abs(delta), current);
					}
				}

				return vec4(sum / float(block * block), 0.0);
			}
		]]):gsub("SOURCE", source),
	}
end

function Clip:Flow(source, config)
	config = config or {}
	local block = config.block or 8
	local size = self:GetChannel(source)
	return self:Map{
		name = config.name or source .. "_flow",
		format = "rgba32f",
		width = math.ceil(size.width / block),
		height = math.ceil(size.height / block),
		p0 = block,
		p1 = config.radius or 8,
		p2 = config.stride or 2,
		glsl = ([[
			float block_difference(int frame, ivec2 origin, ivec2 shift) {
				float sum = 0.0;
				float count = 0.0;
				int block = int(param(0));
				int stride = int(param(2));

				for (int y = 0; y < block; y += stride) {
					for (int x = 0; x < block; x += stride) {
						ivec2 pixel = origin + ivec2(x, y);
						sum += abs(luma(fetch(SOURCE, frame, pixel)) - luma(fetch(SOURCE, frame - 1, pixel + shift)));
						count += 1.0;
					}
				}

				return sum / count;
			}

			vec4 map(int frame, ivec2 cell) {
				if (frame == 0) return vec4(0.0);

				ivec2 origin = cell * int(param(0));
				int radius = int(param(1));
				float still = block_difference(frame, origin, ivec2(0));
				float best = still;
				ivec2 best_shift = ivec2(0);

				for (int sy = -radius; sy <= radius; sy++) {
					for (int sx = -radius; sx <= radius; sx++) {
						float difference = block_difference(frame, origin, ivec2(sx, sy));

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
						float a = block_difference(frame, origin, best_shift - step_vec);
						float b = block_difference(frame, origin, best_shift + step_vec);
						float denominator = a - 2.0 * best + b;

						if (denominator > 1e-5) refined[axis] += clamp(0.5 * (a - b) / denominator, -0.5, 0.5);
					}
				}

				return vec4(-refined, best, still);
			}
		]]):gsub("SOURCE", source),
	}
end

function Clip:Variance(source, config)
	config = config or {}
	return self:Map{
		name = config.name or source .. "_variance",
		format = "rgba32f",
		width = self:GetChannel(source).width,
		height = self:GetChannel(source).height,
		frames = 1,
		glsl = ([[
			vec4 map(int frame, ivec2 pixel) {
				int count = channel_frames(SOURCE);
				float sum = 0.0;
				float sum2 = 0.0;
				float change = 0.0;
				float max_change = 0.0;
				float last = luma(fetch(SOURCE, 0, pixel));

				for (int i = 0; i < count; i++) {
					float v = luma(fetch(SOURCE, i, pixel));
					float delta = abs(v - last);
					sum += v;
					sum2 += v * v;
					change += delta;
					max_change = max(max_change, delta);
					last = v;
				}

				float mean = sum / float(count);
				return vec4(mean, sqrt(max(sum2 / float(count) - mean * mean, 0.0)), change / float(max(count - 1, 1)), max_change);
			}
		]]):gsub("SOURCE", source),
	}
end

function Clip:Slice(source, config)
	config = config or {}
	local size = self:GetChannel(source)
	local column = config.column ~= nil
	return self:Map{
		name = config.name or source .. (column and "_column" or "_row"),
		format = config.format or size.format,
		width = column and self.count or size.width,
		height = column and size.height or self.count,
		frames = 1,
		p0 = column and 1 or 0,
		p1 = column and config.column or (config.row or math.floor(size.height / 2)),
		glsl = ([[
			vec4 map(int frame, ivec2 pixel) {
				if (param(0) > 0.5) return fetch(SOURCE, pixel.x, ivec2(int(param(1)), pixel.y));

				return fetch(SOURCE, pixel.y, ivec2(pixel.x, int(param(1))));
			}
		]]):gsub("SOURCE", source),
	}
end

function Clip:Stats(source, config)
	config = config or {}
	local block = 16
	local size = self:GetChannel(source)
	local name = "_stats_" .. source
	local cells = self:Map{
		name = name,
		format = "rgba32f",
		width = math.ceil(size.width / block),
		height = math.ceil(size.height / block),
		frames = size.count,
		p0 = block,
		p1 = config.threshold or 0.02,
		glsl = ([[
			vec4 map(int frame, ivec2 cell) {
				int block = int(param(0));
				ivec2 size = channel_size(SOURCE);
				float sum = 0.0;
				float peak = 0.0;
				float above = 0.0;
				float count = 0.0;

				for (int y = 0; y < block; y++) {
					for (int x = 0; x < block; x++) {
						ivec2 pixel = cell * block + ivec2(x, y);

						if (pixel.x >= size.x || pixel.y >= size.y) continue;

						vec4 v = fetch(SOURCE, frame, pixel);
						float m = EXPRESSION;
						sum += m;
						peak = max(peak, m);
						above += m >= param(1) ? 1.0 : 0.0;
						count += 1.0;
					}
				}

				return vec4(sum, peak, above, count);
			}
		]]):gsub("SOURCE", source):gsub("EXPRESSION", config.expression or "abs(v.y)"),
	}
	local stats = {}

	for frame = 1, cells.count do
		local data = self:ReadFrame(name, frame)
		local values = ffi.cast(float_ptr, data.data)
		local sum, peak, active, count = 0, 0, 0, 0

		for i = 0, cells.width * cells.height - 1 do
			sum = sum + values[i * 4]
			peak = math.max(peak, values[i * 4 + 1])
			active = active + values[i * 4 + 2]
			count = count + values[i * 4 + 3]
		end

		stats[frame] = {
			time = self.frames[frame] and self.frames[frame].time,
			mean = sum / count,
			max = peak,
			active = active / count,
		}
	end

	self:RemoveChannel(name)
	return stats
end

do
	local function percentile(frame, component, fraction)
		local values = {}

		for y = 0, frame.height - 1, 2 do
			for x = 0, frame.width - 1, 2 do
				local v = select(component, frame:GetPixel(x, y))

				if v == v then values[#values + 1] = v end
			end
		end

		table.sort(values)
		return values[math.max(1, math.floor(#values * fraction))] or 0
	end

	function Clip:Noise(source, config)
		config = config or {}
		local channel = self:GetChannel(source)
		local window = config.window or 8
		local lags = config.lags or {1, 4, 16, 64}
		local prefix = config.name or source .. "_noise"
		local row = config.row or math.floor(channel.height / 2)
		assert(#lags == 4, "Noise takes four lags")
		assert(
			self.count > window and self.count > lags[4],
			"the clip is too short for the window and lags"
		)
		self:Map{
			name = prefix,
			format = "rgba32f",
			frames = 1,
			batch = 1,
			p0 = window,
			glsl = ([[
				vec4 map(int frame, ivec2 pixel) {
					int count = channel_frames(SOURCE);
					int window = int(param(0));
					float sum = 0.0;
					float flicker = 0.0;
					float last = luma(fetch(SOURCE, 0, pixel));
					float running = 0.0;
					float smooth_sum = 0.0;
					float smooth_sum2 = 0.0;

					for (int i = 0; i < window; i++) running += luma(fetch(SOURCE, i, pixel));

					for (int i = 0; i < count; i++) {
						float v = luma(fetch(SOURCE, i, pixel));
						sum += v;
						flicker += abs(v - last);
						last = v;

						if (i >= window) running += v - luma(fetch(SOURCE, i - window, pixel));

						if (i >= window - 1) {
							float average = running / float(window);
							smooth_sum += average;
							smooth_sum2 += average * average;
						}
					}

					float smooth_count = float(count - window + 1);
					float smooth_mean = smooth_sum / smooth_count;
					return vec4(sum / float(count), flicker / float(count - 1), sqrt(max(smooth_sum2 / smooth_count - smooth_mean * smooth_mean, 0.0)), 0.0);
				}
			]]):gsub("SOURCE", source),
		}
		self:Map{
			name = prefix .. "_autocorrelation",
			format = "rgba32f",
			frames = 1,
			batch = 1,
			p0 = lags[1],
			p1 = lags[2],
			p2 = lags[3],
			p3 = lags[4],
			glsl = ([[
				float correlation(ivec2 pixel, int lag, float mean, float variance) {
					int count = channel_frames(SOURCE) - lag;
					float sum = 0.0;

					for (int i = 0; i < count; i++) {
						sum += (luma(fetch(SOURCE, i, pixel)) - mean) * (luma(fetch(SOURCE, i + lag, pixel)) - mean);
					}

					return sum / float(count) / variance;
				}

				vec4 map(int frame, ivec2 pixel) {
					int count = channel_frames(SOURCE);
					float sum = 0.0;
					float sum2 = 0.0;

					for (int i = 0; i < count; i++) {
						float v = luma(fetch(SOURCE, i, pixel));
						sum += v;
						sum2 += v * v;
					}

					float mean = sum / float(count);
					float variance = sum2 / float(count) - mean * mean;

					if (variance <= mean * mean * 1e-8) return vec4(uintBitsToFloat(0x7fc00000u));

					return vec4(
						correlation(pixel, int(param(0)), mean, variance),
						correlation(pixel, int(param(1)), mean, variance),
						correlation(pixel, int(param(2)), mean, variance),
						correlation(pixel, int(param(3)), mean, variance)
					);
				}
			]]):gsub("SOURCE", source),
		}
		self:Slice(source, {row = row, name = prefix .. "_slice"})
		local noise = self:ReadFrame(prefix, 1)
		local result = {
			window = window,
			lags = lags,
			row = row,
			flicker_p99 = percentile(noise, 2, 0.99),
			boil_p99 = percentile(noise, 3, 0.99),
			white_noise_boil_ratio = 1 / math.sqrt(window) / (2 / math.sqrt(math.pi)),
			autocorrelation = {0, 0, 0, 0},
			varying_fraction = 0,
		}
		local luma_sum, flicker_sum, boil_sum, count = 0, 0, 0, 0

		for y = 0, noise.height - 1, 2 do
			for x = 0, noise.width - 1, 2 do
				local l, f, b = noise:GetPixel(x, y)
				luma_sum, flicker_sum, boil_sum, count = luma_sum + l, flicker_sum + f, boil_sum + b, count + 1
			end
		end

		result.mean = luma_sum / count
		result.flicker = flicker_sum / count
		result.boil = boil_sum / count
		result.boil_ratio = result.boil / result.flicker
		result.correlation = result.boil_ratio / result.white_noise_boil_ratio
		result.relative_flicker = result.flicker / result.mean
		result.relative_boil = result.boil / result.mean
		local autocorrelation = self:ReadFrame(prefix .. "_autocorrelation", 1)
		local varying = 0

		for y = 0, autocorrelation.height - 1, 2 do
			for x = 0, autocorrelation.width - 1, 2 do
				local a, b, c, d = autocorrelation:GetPixel(x, y)

				if a == a then
					local sums = result.autocorrelation
					sums[1], sums[2], sums[3], sums[4] = sums[1] + a, sums[2] + b, sums[3] + c, sums[4] + d
					varying = varying + 1
				end
			end
		end

		for i = 1, 4 do
			result.autocorrelation[i] = varying > 0 and result.autocorrelation[i] / varying or 0
		end

		result.varying_fraction = varying / count

		do
			local values = result.autocorrelation

			if values[1] < 0.5 then
				result.lifetime = lags[1] * values[1] / 0.5
			else
				for i = 2, 4 do
					if values[i] < 0.5 then
						local t = (values[i - 1] - 0.5) / (values[i - 1] - values[i])
						result.lifetime = math.exp(math.log(lags[i - 1]) + t * (math.log(lags[i]) - math.log(lags[i - 1])))

						break
					end
				end
			end
		end

		local scale = math.max(result.flicker_p99, result.boil_p99, 1e-12)
		local panel_width = config.panel_width or math.min(channel.width, 1280)
		local panel_height = math.floor(panel_width * channel.height / channel.width / 2) * 2
		result.panel = prefix .. "_panel"
		self:Map{
			name = result.panel,
			format = "rgba8",
			frames = 1,
			width = panel_width,
			height = panel_height,
			p0 = 1 / scale,
			p1 = row,
			p2 = 0.5 / math.max(result.boil_p99, 1e-12),
			p3 = (
					channel.format == "rgba8" or
					channel.format == "r8"
				)
				and
				0 or
				0.18 / math.max(result.mean, 1e-30),
			glsl = ([[
				vec3 heat(float v) {
					v = clamp(v, 0.0, 1.0);
					return clamp(vec3(v * 3.0, v * 3.0 - 1.0, v * 3.0 - 2.0), 0.0, 1.0);
				}

				vec4 map(int frame, ivec2 pixel) {
					ivec2 half_size = output_size() / 2;
					ivec2 quadrant = min(pixel / half_size, ivec2(1));
					ivec2 local_pixel = pixel - quadrant * half_size;
					ivec2 size = channel_size(SOURCE);
					ivec2 source_pixel = local_pixel * size / half_size;

					if (quadrant == ivec2(0, 0)) {
						if (abs(source_pixel.y - int(param(1))) * half_size.y < size.y) return vec4(0.0, 1.0, 1.0, 1.0);

						vec3 color = fetch(SOURCE, channel_frames(SOURCE) / 2, source_pixel).rgb;

						if (param(3) > 0.0) color = recorder_to_srgb(clamp(color * param(3), 0.0, 1.0));

						return vec4(color, 1.0);
					}

					vec4 n = fetch(NOISE, 0, source_pixel);

					if (quadrant == ivec2(1, 0)) return vec4(heat(n.y * param(0)), 1.0);

					if (quadrant == ivec2(0, 1)) return vec4(heat(n.z * param(0)), 1.0);

					ivec2 slice_pixel = local_pixel * channel_size(SLICE) / half_size;
					float mean = fetch(NOISE, 0, ivec2(slice_pixel.x, int(param(1)))).x;
					return vec4(vec3(0.5 + (luma(fetch(SLICE, 0, slice_pixel)) - mean) * param(2)), 1.0);
				}
			]]):gsub("SOURCE", source):gsub("NOISE", prefix):gsub("SLICE", prefix .. "_slice"),
		}
		return result
	end
end

function Clip:RemoveChannel(name)
	local channel = self:GetChannel(name)
	remove_channel(channel)

	for i, other in ipairs(self.channels) do
		if other == channel then
			table.remove(self.channels, i)

			break
		end
	end

	self.by_name[name] = nil
	self.infos_dirty = true
end

function Clip:Remove()
	for _, channel in ipairs(self.channels) do
		remove_channel(channel)
	end

	self.channels = {}
	self.by_name = {}

	if self.infos then self.infos:Remove() end

	if self.meta_buffer then self.meta_buffer:Remove() end

	self.infos = nil
	self.meta_buffer = nil
end

function Clip:ReadFrame(name, frame)
	local channel = self:GetChannel(name)
	local location = channel.frames[frame] or
		error(("channel %s has no frame %s"):format(name, tostring(frame)), 2)
	local data = ffi.new("uint8_t[?]", channel.frame_bytes)

	if channel.host then
		ffi.copy(data, location.buffer:Map(location.offset), channel.frame_bytes)
	else
		if not channel.readback then
			channel.readback = render.CreateBuffer{
				byte_size = channel.frame_bytes,
				buffer_usage = {"transfer_dst"},
				memory_property = {"host_visible", "host_coherent", "host_cached"},
				label = "frame_recorder readback",
			}
			table.insert(channel.buffers, channel.readback)
		end

		local copy = BufferCopy()
		copy[0].srcOffset = location.offset
		copy[0].dstOffset = 0
		copy[0].size = channel.frame_bytes
		local cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()
		cmd:CopyBuffer(location.buffer, channel.readback, copy, 1)
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Remove()
		ffi.copy(data, channel.readback:Map(), channel.frame_bytes)
	end

	local format = channel.format_info
	return setmetatable(
		{
			data = data,
			values = ffi.cast(format.element .. " *", data),
			width = channel.width,
			height = channel.height,
			format = channel.format,
			format_info = format,
			row_elements = channel.words_per_row * 4 / format.element_bytes,
			meta = self.frames[frame],
		},
		Frame
	)
end

function Frame:GetSize()
	return self.width, self.height
end

do
	local function decode(element, v)
		if element == "uint8_t" then return v / 255 end

		if element == "uint16_t" then return math.half2float(v) end

		return v
	end

	function Frame:GetPixel(x, y)
		local format = self.format_info
		local components = format.components
		local element = format.element
		local base = y * self.row_elements + x * components
		local values = self.values
		local r = decode(element, values[base])

		if components == 1 then return r, r, r, 1 end

		local g = decode(element, values[base + 1])

		if components == 2 then return r, g, 0, 1 end

		return r, g, decode(element, values[base + 2]), decode(element, values[base + 3])
	end
end

function Frame:ToPNG(opt)
	opt = opt or {}
	local scale = opt.scale or 1
	local offset = opt.offset or 0
	local w, h = self.width, self.height
	local pixels = ffi.new("uint8_t[?]", w * h * 3)

	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local r, g, b = self:GetPixel(x, y)
			local i = (y * w + x) * 3

			if opt.abs then r, g, b = math.abs(r), math.abs(g), math.abs(b) end

			pixels[i] = math.floor(math.clamp(r * scale + offset, 0, 1) * 255 + 0.5)
			pixels[i + 1] = math.floor(math.clamp(g * scale + offset, 0, 1) * 255 + 0.5)
			pixels[i + 2] = math.floor(math.clamp(b * scale + offset, 0, 1) * 255 + 0.5)
		end
	end

	local file = png.Encode(w, h, "rgb")
	file:write(pixels)
	return file:getData()
end

local function write_file(path, data)
	assert(fs.create_directory_recursive(file_path.GetFolderFromPath(path)))
	assert(fs.write_file(path, data))
	return path
end

function Frame:Save(path, opt)
	return write_file(path, self:ToPNG(opt))
end

function Clip:SaveFrame(name, frame, path, opt)
	return self:ReadFrame(name, frame):Save(path, opt)
end

function Clip:SaveSequence(name, path_prefix, opt)
	local paths = {}

	for frame = 1, self:GetChannel(name).count do
		paths[frame] = self:SaveFrame(name, frame, ("%s%04d.png"):format(path_prefix, frame), opt)
	end

	return paths
end

function Clip:SaveSheet(name, path, opt)
	opt = opt or {}
	local channel = self:GetChannel(name)
	local frames = opt.frames or math.min(channel.count, 16)

	if type(frames) == "number" then
		local count = frames
		frames = {}

		for i = 1, count do
			frames[i] = count == 1 and
				1 or
				math.floor((i - 1) * (channel.count - 1) / (count - 1) + 0.5) + 1
		end
	end

	local columns = opt.columns or math.ceil(math.sqrt(#frames))
	local rows = math.ceil(#frames / columns)
	local w, h = channel.width, channel.height
	local sheet_w, sheet_h = w * columns, h * rows
	local pixels = ffi.new("uint8_t[?]", sheet_w * sheet_h * 3)
	local scale = opt.scale or 1
	local offset = opt.offset or 0

	for i, frame in ipairs(frames) do
		local data = self:ReadFrame(name, frame)
		local ox = ((i - 1) % columns) * w
		local oy = math.floor((i - 1) / columns) * h

		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local r, g, b = data:GetPixel(x, y)
				local o = ((oy + y) * sheet_w + ox + x) * 3

				if opt.abs then r, g, b = math.abs(r), math.abs(g), math.abs(b) end

				pixels[o] = math.floor(math.clamp(r * scale + offset, 0, 1) * 255 + 0.5)
				pixels[o + 1] = math.floor(math.clamp(g * scale + offset, 0, 1) * 255 + 0.5)
				pixels[o + 2] = math.floor(math.clamp(b * scale + offset, 0, 1) * 255 + 0.5)
			end
		end
	end

	local file = png.Encode(sheet_w, sheet_h, "rgb")
	file:write(pixels)
	return write_file(path, file:getData())
end

function Clip:SaveVideo(name, path, opt)
	opt = opt or {}
	local channel = self:GetChannel(name)
	assert(
		channel.format == "rgba8" or channel.format == "r8",
		"SaveVideo needs an rgba8 or r8 channel, Map other formats to rgba8 first"
	)
	local fps = opt.fps

	if not fps then
		local span = self.count > 1 and self.frames[self.count].time - self.frames[1].time or 0
		fps = span > 0 and (self.count - 1) / span or 60
	end

	assert(fs.create_directory_recursive(file_path.GetFolderFromPath(path)))
	local args = {
		"-y",
		"-loglevel",
		"error",
		"-f",
		"rawvideo",
		"-pix_fmt",
		channel.format == "rgba8" and
		"rgba" or
		"gray",
		"-s",
		channel.width .. "x" .. channel.height,
		"-r",
		tostring(fps),
		"-i",
		"-",
	}

	for _, arg in ipairs(opt.codec_args or {"-c:v", "ffv1"}) do
		table.insert(args, arg)
	end

	table.insert(args, path)
	local env

	if jit.os == "Linux" then
		-- the library path the engine runs with (nix vulkan and glslang) breaks system binaries
		env = process.get_environment()
		env.LD_LIBRARY_PATH = nil
	end

	local proc = assert(process.spawn{command = "ffmpeg", args = args, stdin = "pipe", env = env})
	local row_bytes = channel.width * channel.format_info.bytes
	local stride = channel.words_per_row * 4

	local function write_all(data)
		local written = 0

		while written < #data do
			local n = assert(proc:write(written == 0 and data or data:sub(written + 1)))
			written = written + n
		end
	end

	for frame = 1, channel.count do
		local data = self:ReadFrame(name, frame).data

		for y = 0, channel.height - 1, 64 do
			local rows = math.min(64, channel.height - y)

			if row_bytes == stride then
				write_all(ffi.string(data + y * stride, rows * stride))
			else
				local parts = {}

				for r = 0, rows - 1 do
					parts[r + 1] = ffi.string(data + (y + r) * stride, row_bytes)
				end

				write_all(table.concat(parts))
			end
		end
	end

	proc:close()
	local exit_code = proc:wait()
	assert(exit_code == 0, "ffmpeg exited with code " .. tostring(exit_code))
	return path
end

return FrameRecorder
