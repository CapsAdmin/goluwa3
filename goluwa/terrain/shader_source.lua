local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local TerrainSource = import("goluwa/terrain/source.lua")
local ShaderSource = setmetatable({}, {__index = TerrainSource})
ShaderSource.__index = ShaderSource
local FloatArray = ffi.typeof("float[?]")
local BakeConstants = ffi.typeof([[
	struct {
		float origin_x;
		float origin_z;
		float step_x;
		float step_z;
		float sample_step;
		int texture0;
		int texture1;
		int texture2;
		int texture3;
		int layer0;
		int layer1;
		int layer2;
		int layer3;
		int layer4;
		int layer5;
		int layer6;
		int layer7;
	}
]])
local BAKE_DECLARATIONS = [[
layout(push_constant, scalar) uniform TerrainBakeConstants {
	float origin_x;
	float origin_z;
	float step_x;
	float step_z;
	float sample_step;
	int texture0;
	int texture1;
	int texture2;
	int texture3;
	// source specific ids of the chunk's layers, see SelectChunkLayers
	int layer0;
	int layer1;
	int layer2;
	int layer3;
	int layer4;
	int layer5;
	int layer6;
	int layer7;
} terrain_bake;
]]
local BAKE_STEP_HELPER = [[
float terrain_bake_step() {
	return terrain_bake.sample_step;
}
]]
local BAKE_HELPERS = [[
vec2 terrain_bake_world_pos() {
	vec2 pixel = gl_FragCoord.xy - vec2(0.5);
	return vec2(terrain_bake.origin_x, terrain_bake.origin_z) + pixel * vec2(terrain_bake.step_x, terrain_bake.step_z);
}

vec3 terrain_bake_normal(vec2 p) {
	float s = terrain_bake.sample_step;
	float h_left = terrain_height(p - vec2(s, 0.0));
	float h_right = terrain_height(p + vec2(s, 0.0));
	float h_down = terrain_height(p - vec2(0.0, s));
	float h_up = terrain_height(p + vec2(0.0, s));
	return normalize(vec3(h_left - h_right, 2.0 * s, h_down - h_up));
}
]]
local HEIGHT_BAKE = [[
	float h = terrain_height(terrain_bake_world_pos());
	return vec4(h, h, h, 1.0);
]]
local NORMAL_BAKE = [[
	vec3 n = terrain_bake_normal(terrain_bake_world_pos());
	return vec4(n.x * 0.5 + 0.5, n.z * 0.5 + 0.5, n.y * 0.5 + 0.5, 1.0);
]]
local SPLAT_BAKE = [[
	vec2 p = terrain_bake_world_pos();
	float h = terrain_height(p);
	vec3 n = terrain_bake_normal(p);
	return terrain_splat(p, h, n);
]]
local SPLAT2_BAKE = [[
	vec2 p = terrain_bake_world_pos();
	float h = terrain_height(p);
	vec3 n = terrain_bake_normal(p);
	return terrain_splat2(p, h, n);
]]
local COLOR_BAKE = [[
	vec2 p = terrain_bake_world_pos();
	float h = terrain_height(p);
	vec3 n = terrain_bake_normal(p);
	return vec4(terrain_color(p, h, n), 1.0);
]]

local function make_bake_texture(self, size, format, cmd)
	local key = size .. ":" .. format
	local pooled = self.texture_pool[key]

	if pooled and pooled[1] then return table.remove(pooled) end

	local texture = Texture.New{
		width = size,
		height = size,
		format = format,
		mip_map_levels = 1,
		cmd = cmd,
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	texture.pool_key = key
	return texture
end

function ShaderSource.New(config)
	local self = setmetatable(TerrainSource.New(config), ShaderSource)
	self.Textures = config.Textures or {}
	self.HasSplat = config.SplatGLSL ~= nil
	self.HasSplat2 = config.Splat2GLSL ~= nil
	self.HasColor = config.ColorGLSL ~= nil
	self.ColorFormat = config.ColorFormat or "r8g8b8a8_unorm"
	self.SelectChunkLayers = config.SelectChunkLayers
	self.ShaderHeader = table.concat(
		{
			BAKE_STEP_HELPER,
			config.Header or
			"",
			config.HeightGLSL,
			config.SplatGLSL or
			"",
			config.Splat2GLSL or
			"",
			config.ColorGLSL or
			"",
			BAKE_HELPERS,
		},
		"\n"
	)
	self.batch = nil
	self.texture_pool = {}
	self.in_flight = {}
	self.free_fences = {}
	return self
end

function ShaderSource:GetShaderHeader()
	return self.ShaderHeader
end

do
	local bake = {}

	local function get_bake_constants(_, _, pipeline)
		local textures = bake.textures
		local layer_ids = bake.layer_ids
		return BakeConstants(
			bake.origin_x,
			bake.origin_z,
			bake.step,
			bake.step,
			bake.step,
			textures[1] and pipeline:GetTextureIndex(textures[1]) or -1,
			textures[2] and pipeline:GetTextureIndex(textures[2]) or -1,
			textures[3] and pipeline:GetTextureIndex(textures[3]) or -1,
			textures[4] and pipeline:GetTextureIndex(textures[4]) or -1,
			layer_ids[1] or -1,
			layer_ids[2] or -1,
			layer_ids[3] or -1,
			layer_ids[4] or -1,
			layer_ids[5] or -1,
			layer_ids[6] or -1,
			layer_ids[7] or -1,
			layer_ids[8] or -1
		)
	end

	local NO_LAYER_IDS = {}
	local push_constants = {size = ffi.sizeof(BakeConstants), get_data = get_bake_constants}

	local function record_bake(self, batch, size, format, glsl, request, texel_centered, layer_ids)
		local texture = make_bake_texture(self, size, format, batch.cmd)
		local step = texel_centered and request.size / size or request.size / (size - 1)
		local offset = texel_centered and step * 0.5 or 0
		bake.textures = self.Textures
		bake.origin_x = request.min_x + offset
		bake.origin_z = request.min_z + offset
		bake.step = step
		bake.layer_ids = layer_ids or NO_LAYER_IDS
		batch.refs[#batch.refs + 1] = texture:Shade(
			glsl,
			{
				cmd = batch.cmd,
				header = self.ShaderHeader,
				custom_declarations = BAKE_DECLARATIONS,
				textures = self.Textures,
				fragment_push_constants = push_constants,
			}
		)
		return texture
	end

	function ShaderSource:RequestChunk(request, callback)
		local batch = self.batch

		if not batch then
			local cmd = render.GetCommandPool():AllocateCommandBuffer()
			cmd:Begin()
			batch = {cmd = cmd, refs = {}, chunks = {}, callbacks = {}, height_textures = {}}
			self.batch = batch
		end

		local chunk = {request = request}

		if request.samples then
			batch.height_textures[#batch.chunks + 1] = record_bake(self, batch, request.samples, "r32_sfloat", HEIGHT_BAKE, request, false)
		end

		if request.detail_size then
			chunk.normal_texture = record_bake(self, batch, request.detail_size, "r8g8b8a8_unorm", NORMAL_BAKE, request, true)
		end

		local layer_ids

		if self.SelectChunkLayers then
			chunk.layers, layer_ids = self.SelectChunkLayers(request)
		end

		if request.splat_size and self.HasSplat then
			chunk.splat_texture = record_bake(
				self,
				batch,
				request.splat_size,
				"r8g8b8a8_unorm",
				SPLAT_BAKE,
				request,
				true,
				layer_ids
			)
		end

		-- the layers after the fourth have their weights in a second texture
		if request.splat_size and self.HasSplat2 and layer_ids and layer_ids[5] then
			chunk.splat2_texture = record_bake(
				self,
				batch,
				request.splat_size,
				"r8g8b8a8_unorm",
				SPLAT2_BAKE,
				request,
				true,
				layer_ids
			)
		end

		if request.color_size and self.HasColor then
			chunk.color_texture = record_bake(
				self,
				batch,
				request.color_size,
				self.ColorFormat,
				COLOR_BAKE,
				request,
				true,
				layer_ids
			)
		end

		batch.chunks[#batch.chunks + 1] = chunk
		batch.callbacks[#batch.callbacks + 1] = callback
	end
end

-- allocating and freeing the memory of a chunk's textures costs more than baking into them, and the textures of a chunk
-- are the same few sizes. a texture is only recycled when nothing can draw with it any more (Terrain.ReleaseFrames)
local MAX_POOLED = 128
local CHUNK_TEXTURES = {"normal_texture", "splat_texture", "splat2_texture", "color_texture"}

function ShaderSource:RecycleTexture(texture)
	local pooled = self.texture_pool[texture.pool_key]

	if not pooled then
		pooled = {}
		self.texture_pool[texture.pool_key] = pooled
	end

	if #pooled >= MAX_POOLED then
		texture:Remove()
	else
		pooled[#pooled + 1] = texture
	end
end

function ShaderSource:ReleaseChunk(chunk)
	for i = 1, #CHUNK_TEXTURES do
		local name = CHUNK_TEXTURES[i]

		if chunk[name] then
			self:RecycleTexture(chunk[name])
			chunk[name] = nil
		end
	end

	chunk.heights = nil
end

function ShaderSource:GetPendingCount()
	local chunks = self.batch and #self.batch.chunks or 0

	for _, batch in ipairs(self.in_flight) do
		chunks = chunks + #batch.chunks
	end

	return #self.in_flight, chunks
end

function ShaderSource:Submit()
	local batch = self.batch

	if not batch then return end

	self.batch = nil
	local cmd = batch.cmd
	local offsets = {}
	local bytes = 0

	for i, chunk in ipairs(batch.chunks) do
		if batch.height_textures[i] then
			offsets[i] = bytes
			bytes = bytes + chunk.request.samples * chunk.request.samples * 4
		end
	end

	if bytes > 0 then
		batch.staging = Buffer.New{
			device = render.GetDevice(),
			size = bytes,
			usage = "transfer_dst",
			properties = {"host_visible", "host_coherent"},
		}

		for i, texture in pairs(batch.height_textures) do
			local samples = batch.chunks[i].request.samples
			render.TransitionResourceTo(
				texture,
				"transfer_src_optimal",
				{
					cmd = cmd,
					srcStage = "all_commands",
					dstStage = "transfer",
				}
			)
			cmd:CopyImageToBuffer{
				image = texture:GetImage(),
				image_layout = "transfer_src_optimal",
				buffer = batch.staging,
				buffer_offset = offsets[i],
				width = samples,
				height = samples,
			}
		end
	end

	batch.offsets = offsets
	cmd:End()
	batch.fence = table.remove(self.free_fences) or Fence.New(render.GetDevice())
	render.Submit(cmd, batch.fence)
	self.in_flight[#self.in_flight + 1] = batch
end

function ShaderSource:CompleteBatch(batch)
	render.GetQueue():RetireFence(batch.fence)
	self.free_fences[#self.free_fences + 1] = batch.fence
	local mapped = batch.staging and ffi.cast("float*", batch.staging:Map())

	for i, chunk in ipairs(batch.chunks) do
		local texture = batch.height_textures[i]

		if texture then
			local count = chunk.request.samples * chunk.request.samples
			local heights = FloatArray(count)
			ffi.copy(heights, mapped + batch.offsets[i] / 4, count * 4)
			self:RecycleTexture(texture)
			local min_height = math.huge
			local max_height = -math.huge

			for j = 0, count - 1 do
				local h = heights[j]

				if h < min_height then min_height = h end

				if h > max_height then max_height = h end
			end

			chunk.heights = heights
			chunk.min_height = min_height
			chunk.max_height = max_height
		end
	end

	if batch.staging then
		batch.staging:Unmap()
		batch.staging:Remove()
	end

	batch.cmd:Remove()

	for i, chunk in ipairs(batch.chunks) do
		batch.callbacks[i](chunk)
	end
end

function ShaderSource:Update()
	local in_flight = self.in_flight

	while in_flight[1] and in_flight[1].fence:IsSignaled() do
		self:CompleteBatch(table.remove(in_flight, 1))
	end
end

function ShaderSource:Finish()
	self:Submit()
	local in_flight = self.in_flight

	while in_flight[1] do
		local batch = table.remove(in_flight, 1)
		batch.fence:Wait()
		self:CompleteBatch(batch)
	end

	for _, pooled in pairs(self.texture_pool) do
		for i = #pooled, 1, -1 do
			pooled[i]:Remove()
			pooled[i] = nil
		end
	end
end

return ShaderSource
