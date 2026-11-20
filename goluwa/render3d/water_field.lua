local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water_field = {}
local SIZE = 512
local WORLD_HALF = 256
local REFILL_DISTANCE = 96
local ROWS_PER_FRAME = 8
local DEEP = -1e4
local WAVE_DEPTH_RATIO = 0.8
local TEXEL = WORLD_HALF * 2 / SIZE
local float_array = ffi.typeof("float[?]")
local height_source
local texture
local active_origin = {0, 0}
local fill

function water_field.SetHeightSource(source)
	height_source = source
	fill = nil
	texture = nil
end

function water_field.GetWorldHalf()
	return WORLD_HALF
end

function water_field.GetOrigin()
	return active_origin[1], active_origin[2]
end

function water_field.GetTexture()
	return texture
end

function water_field.Update()
	if not height_source then return end

	local cam = render3d.GetCamera():GetPosition()

	if not texture then
		local blank = float_array(SIZE * SIZE)

		for i = 0, SIZE * SIZE - 1 do
			blank[i] = DEEP
		end

		texture = Texture.New{
			width = SIZE,
			height = SIZE,
			format = "r32_sfloat",
			buffer = blank,
			mip_map_levels = 1,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		active_origin = {math.huge, math.huge}
	end

	if
		not fill and
		(
			math.abs(cam.x - active_origin[1]) > REFILL_DISTANCE or
			math.abs(cam.z - active_origin[2]) > REFILL_DISTANCE
		)
	then
		fill = {
			buffer = float_array(SIZE * SIZE),
			row = 0,
			origin_x = math.floor(cam.x / TEXEL) * TEXEL,
			origin_z = math.floor(cam.z / TEXEL) * TEXEL,
		}
	end

	if not fill then return end

	local last = math.min(fill.row + ROWS_PER_FRAME, SIZE) - 1

	for row = fill.row, last do
		local z = fill.origin_z + ((row + 0.5) / SIZE * 2 - 1) * WORLD_HALF

		for column = 0, SIZE - 1 do
			fill.buffer[row * SIZE + column] = height_source(fill.origin_x + ((column + 0.5) / SIZE * 2 - 1) * WORLD_HALF, z)
		end
	end

	fill.row = last + 1

	if fill.row >= SIZE then
		texture:Upload(fill.buffer)
		active_origin = {fill.origin_x, fill.origin_z}
		fill = nil
	end
end

function water_field.GetFields()
	return {
		{"field_tex", "int"},
		{"field_origin", "vec2"},
		{"field_half", "float"},
		{"field_ocean_level", "float"},
		{"shoal_depth", "float"},
	}
end

function water_field.WriteBlock(self, block, shoal_depth)
	water_field.Update()
	block.field_tex = texture and active_origin[1] ~= math.huge and self:GetTextureIndex(texture) or -1
	block.field_origin[0] = active_origin[1] ~= math.huge and active_origin[1] or 0
	block.field_origin[1] = active_origin[2] ~= math.huge and active_origin[2] or 0
	block.field_half = WORLD_HALF
	block.field_ocean_level = render3d.GetOceanLevel()
	block.shoal_depth = shoal_depth
end

function water_field.GetGLSL(block_name)
	return [[
		float water_field_depth(vec2 world_xz) {
			if (]] .. block_name .. [[.field_tex < 0) return 1e4;

			vec2 uv = (world_xz - ]] .. block_name .. [[.field_origin) / (2.0 * ]] .. block_name .. [[.field_half) + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 1e4;

			return ]] .. block_name .. [[.field_ocean_level - textureLod(TEXTURE(]] .. block_name .. [[.field_tex), uv, 0.0).r;
		}

		float water_field_damping(float depth) {
			return smoothstep(0.0, ]] .. block_name .. [[.shoal_depth, depth);
		}

		float water_field_height_scale(float height, float depth) {
			float cap = max(]] .. WAVE_DEPTH_RATIO .. [[ * depth, 1e-3);
			float ratio = height / cap;

			if (abs(ratio) < 1e-3) return 1.0;

			return tanh(ratio) / ratio;
		}

		float water_field_breaking(float crest_height, float depth) {
			return 0.3 * smoothstep(0.5, 1.0, max(crest_height, 0.0) / max(depth, 0.05)) * step(depth, 1e3);
		}
	]]
end

return water_field
