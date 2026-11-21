local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local water_field = {}
local SIZE = 1024
local MIP_LEVELS = 11
local WORLD_HALF = 1024
local REFILL_DISTANCE = 256
local ROWS_PER_FRAME = 32
local DEEP_CLAMP = 100
local WAVE_DEPTH_RATIO = 0.8
local SHELTER_STEPS = 24
local TEXEL = WORLD_HALF * 2 / SIZE
local float_array = ffi.typeof("float[?]")
local height_source
local texture
local active_origin = {0, 0}
local fill
local heights
local heights_version = 0

function water_field.SetHeightSource(source)
	height_source = source
	fill = nil
	texture = nil
	heights = nil
	heights_version = heights_version + 1
end

function water_field.GetHeightSource()
	return height_source
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

function water_field.GetHeights()
	return heights,
	heights_version,
	SIZE,
	active_origin[1],
	active_origin[2],
	WORLD_HALF
end

function water_field.Update()
	if not height_source then return end

	local cam = render3d.GetCamera():GetPosition()
	local floor = render3d.GetOceanLevel() - DEEP_CLAMP

	if not texture then
		local blank = float_array(SIZE * SIZE)

		for i = 0, SIZE * SIZE - 1 do
			blank[i] = floor
		end

		texture = Texture.New{
			width = SIZE,
			height = SIZE,
			format = "r32_sfloat",
			buffer = blank,
			mip_map_levels = MIP_LEVELS,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
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
			fill.buffer[row * SIZE + column] = math.max(
				height_source(fill.origin_x + ((column + 0.5) / SIZE * 2 - 1) * WORLD_HALF, z),
				floor
			)
		end
	end

	fill.row = last + 1

	if fill.row >= SIZE then
		texture:Upload(fill.buffer, true)
		texture:GenerateMipmaps("transfer_dst_optimal")
		active_origin = {fill.origin_x, fill.origin_z}
		heights = fill.buffer
		heights_version = heights_version + 1
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
		{"field_wave_dir", "vec2"},
		{"field_wavelength", "float"},
	}
end

function water_field.WriteBlock(self, block, shoal_depth)
	water_field.Update()
	local waves = water.GetOceanWaves()
	block.field_tex = texture and active_origin[1] ~= math.huge and self:GetTextureIndex(texture) or -1
	block.field_origin[0] = active_origin[1] ~= math.huge and active_origin[1] or 0
	block.field_origin[1] = active_origin[2] ~= math.huge and active_origin[2] or 0
	block.field_half = WORLD_HALF
	block.field_ocean_level = render3d.GetOceanLevel()
	block.shoal_depth = shoal_depth
	block.field_wave_dir[0] = math.cos(waves.dominant_angle)
	block.field_wave_dir[1] = math.sin(waves.dominant_angle)
	block.field_wavelength = waves.dominant_wavelength
end

function water_field.GetGLSL(block_name)
	return (
		[[
		vec2 water_field_uv(vec2 world_xz) {
			return (world_xz - $B.field_origin) / (2.0 * $B.field_half) + 0.5;
		}

		bool water_field_covers(vec2 uv) {
			return $B.field_tex >= 0 && all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
		}

		float water_field_height(vec2 world_xz, float lod) {
			return textureLod(TEXTURE($B.field_tex), water_field_uv(world_xz), lod).r;
		}

		float water_field_depth(vec2 world_xz) {
			if (!water_field_covers(water_field_uv(world_xz))) return 1e4;

			return $B.field_ocean_level - water_field_height(world_xz, 0.0);
		}

		float water_field_damping(float depth) {
			return smoothstep(0.0, $B.shoal_depth, depth);
		}

		float water_field_height_scale(float height, float depth) {
			float cap = max(]] .. WAVE_DEPTH_RATIO .. [[ * depth, 1e-3);
			float ratio = height / cap;

			if (abs(ratio) < 1e-3) return 1.0;

			return tanh(ratio) / ratio;
		}

		float water_field_breaking(float crest_height, float depth) {
			return 0.3 * smoothstep(0.5, 1.0, max(crest_height, 0.0) / max(depth, 0.05)) * step(depth, 1e3) * step(0.0, depth);
		}

		vec2 water_field_waves(vec2 world_xz) {
			if (!water_field_covers(water_field_uv(world_xz))) return vec2(0.0);

			float wavelength = $B.field_wavelength;
			float spacing = clamp(wavelength * 0.5, 2.0, 48.0);
			float lod = log2(spacing / ]] .. TEXEL .. [[);
			float depth = max($B.field_ocean_level - water_field_height(world_xz, lod), 0.0);
			vec2 uphill = vec2(
				water_field_height(world_xz + vec2(spacing, 0.0), lod) - water_field_height(world_xz - vec2(spacing, 0.0), lod),
				water_field_height(world_xz + vec2(0.0, spacing), lod) - water_field_height(world_xz - vec2(0.0, spacing), lod)
			) / (2.0 * spacing);
			float slope = length(uphill);
			float k = 6.28318530718 / wavelength;
			float speed_ratio = sqrt(tanh(k * depth));
			vec2 deep_dir = $B.field_wave_dir;
			float turn = 0.0;

			if (slope > 1e-4) {
				vec2 normal = uphill / slope;
				float deep_angle = atan(normal.x * deep_dir.y - normal.y * deep_dir.x, dot(normal, deep_dir));
				float side = sign(deep_angle);
				float off = abs(deep_angle);
				float refracted = off <= 1.5707963 ? asin(sin(off) * speed_ratio) : asin(speed_ratio) + (off - 1.5707963) * speed_ratio * speed_ratio;
				turn = (side * refracted - deep_angle) * smoothstep(0.002, 0.02, slope);
			}

			float shelter = 0.0;
			float reach = clamp(wavelength * 6.0, 60.0, 240.0);
			float step_size = reach / float(]] .. SHELTER_STEPS .. [[);
			float march_lod = log2(max(step_size, 1.0) / ]] .. TEXEL .. [[);

			for (int i = 1; i <= ]] .. SHELTER_STEPS .. [[; i++) {
				float along = float(i) * step_size;
				vec2 p = world_xz - deep_dir * along;

				if (!water_field_covers(water_field_uv(p))) break;

				float land = smoothstep(-2.0, 0.5, water_field_height(p, march_lod) - $B.field_ocean_level);
				shelter = max(shelter, land * (1.0 - along / reach));
			}

			return vec2(turn, shelter);
		}
	]]
	):gsub("%$B", block_name)
end

return water_field
