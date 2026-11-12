local Texture = import("goluwa/render/texture.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local HeightmapSource = {}
local CLAMPED = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}
local NEAREST = {
	min_filter = "nearest",
	mag_filter = "nearest",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}

-- A terrain from maps. data:
-- size: the side of the square map in meters
-- origin: {x, z}, the world position the map is measured from
-- uv: {a, b, c, d}, the map coordinates of a world position x, z are, with p = (x, z) - origin,
--   u = (a * p.x + b * p.z) / size and v = (c * p.x + d * p.z) / size, the map is where both are in 0..1
-- outside: the height outside the map: "zero", "clamp" (the height of the nearest edge sample) or a number
--   (a constant height). The colors and layers outside always take the edge of the map.
-- max_height: the height of a full sample
-- min_height: the height of a zero sample (optional, 0)
-- height: {width, height, samples = uint16 array of width * height} (a height map)
-- color: a Texture, the color map, covering the map
-- indices: {width, height, samples = uint8 array}, the layer id of every cell, 0 is none (optional)
-- layers: {[id] = {albedo, normal, height, height_scale, scale, detail, additive_detail, specular,
--   scatter, roughness}}, the detail layers by id
-- Returns a terrain source, source.Data is the data.
function HeightmapSource.New(data)
	local size = math.max(data.size, 1)
	local min_height = data.min_height or 0
	local height = data.height
	local indices = data.indices
	local has_layers = indices ~= nil
	local layers = data.layers or {}
	local uv = data.uv
	local outside = data.outside
	local outside_glsl

	if outside == "zero" then
		outside_glsl = "if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;"
	elseif outside == "clamp" then
		outside_glsl = "uv = clamp(uv, vec2(0.0), vec2(1.0));"
	else
		assert(type(outside) == "number", "outside is zero, clamp or a height")
		outside_glsl = string.format(
			"if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return %.6f;",
			outside
		)
	end

	local height_texture = Texture.New{
		width = height.width,
		height = height.height,
		format = "r16_unorm",
		buffer = height.samples,
		mip_map_levels = 1,
		sampler = CLAMPED,
	}
	local index_texture = has_layers and
		Texture.New{
			width = indices.width,
			height = indices.height,
			format = "r8_unorm",
			buffer = indices.samples,
			mip_map_levels = 1,
			sampler = NEAREST,
		} or
		nil
	local source = ShaderSource.New{
		Textures = {height_texture, data.color, index_texture},
		HeightGLSL = string.format(
			[[

			vec2 map_uv(vec2 world) {
				vec2 p = world - vec2(%.9f, %.9f);
				return vec2(%.9f * p.x + %.9f * p.y, %.9f * p.x + %.9f * p.y) / %.6f;
			}

			vec2 map_uv_clamped(vec2 world) {
				return clamp(map_uv(world), vec2(0.0), vec2(1.0));
			}

			float terrain_height(vec2 world) {
				vec2 uv = map_uv(world);
				%s

				return %.6f + texture(TEXTURE(terrain_bake.texture0), uv + vec2(%.9f, %.9f)).r * %.6f;
			}
		]],
			data.origin[1],
			data.origin[2],
			uv[1],
			uv[2],
			uv[3],
			uv[4],
			size,
			outside_glsl,
			min_height,
			0.5 / height.width,
			0.5 / height.height,
			data.max_height - min_height
		),
		SplatGLSL = has_layers and
			[[

			int map_slot(int id) {
				if (id == terrain_bake.layer1) return 1;
				if (id == terrain_bake.layer2) return 2;
				if (id == terrain_bake.layer3) return 3;
				if (id == terrain_bake.layer4) return 4;
				if (id == terrain_bake.layer5) return 5;
				if (id == terrain_bake.layer6) return 6;
				if (id == terrain_bake.layer7) return 7;
				return 0;
			}

			vec4 map_slot_weights(vec2 world, int first_slot) {
				ivec2 size = textureSize(TEXTURE(terrain_bake.texture2), 0);
				vec2 p = map_uv_clamped(world) * vec2(size) - 0.5;
				ivec2 base = ivec2(floor(p));
				vec2 f = p - vec2(base);
				vec4 weights = vec4(0.0);

				for (int i = 0; i < 4; i++) {
					ivec2 offset = ivec2(i & 1, i >> 1);
					ivec2 cell = clamp(base + offset, ivec2(0), size - 1);
					int id = int(texelFetch(TEXTURE(terrain_bake.texture2), cell, 0).r * 255.0 + 0.5);
					float weight = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
					int slot = map_slot(id) - first_slot;

					if (slot >= 0 && slot < 4) weights[slot] += weight;
				}

				return weights;
			}

			vec4 terrain_splat(vec2 world, float h, vec3 n) {
				return map_slot_weights(world, 0);
			}
		]] or
			nil,
		Splat2GLSL = has_layers and
			[[

			vec4 terrain_splat2(vec2 world, float h, vec3 n) {
				return map_slot_weights(world, 4);
			}
		]] or
			nil,
		ColorGLSL = [[
			vec3 terrain_color(vec2 world, float h, vec3 n) {
				return texture(TEXTURE(terrain_bake.texture1), map_uv_clamped(world)).rgb;
			}
		]],
		ColorFormat = "r8g8b8a8_srgb",
		SelectChunkLayers = has_layers and
			function(request)
				local samples = indices.samples
				local u1, v1 = HeightmapSource.ToMap(data, request.min_x, request.min_z)
				local u2, v2 = HeightmapSource.ToMap(data, request.min_x + request.size, request.min_z + request.size)
				local first_column = math.clamp(math.floor(math.min(u1, u2) * indices.width), 0, indices.width - 1)
				local last_column = math.clamp(math.ceil(math.max(u1, u2) * indices.width), 0, indices.width - 1)
				local first_row = math.clamp(math.floor(math.min(v1, v2) * indices.height), 0, indices.height - 1)
				local last_row = math.clamp(math.ceil(math.max(v1, v2) * indices.height), 0, indices.height - 1)
				local stride = math.max(math.floor(math.max(last_row - first_row, last_column - first_column) / 64), 1)
				local counts = {}
				local ids = {}

				for row = first_row, last_row, stride do
					for column = first_column, last_column, stride do
						local id = samples[row * indices.width + column]

						if id ~= 0 and layers[id] then
							if not counts[id] then ids[#ids + 1] = id end

							counts[id] = (counts[id] or 0) + 1
						end
					end
				end

				table.sort(ids, function(a, b)
					return counts[a] > counts[b]
				end)

				local chunk_layers = {}

				for i = 9, #ids do
					ids[i] = nil
				end

				for i, id in ipairs(ids) do
					chunk_layers[i] = layers[id]
				end

				return chunk_layers, ids
			end or
			nil,
		MinHeight = min_height,
		MaxHeight = data.max_height,
		Layers = {},
	}
	source.Data = data
	return source
end

-- the map coordinates of a world position, the map is where both are in 0..1
function HeightmapSource.ToMap(data, x, z)
	local size = math.max(data.size, 1)
	local uv = data.uv
	local px, pz = x - data.origin[1], z - data.origin[2]
	return (uv[1] * px + uv[2] * pz) / size, (uv[3] * px + uv[4] * pz) / size
end

-- the height in meters at a world position, bilinear in the samples
function HeightmapSource.SampleHeight(data, x, z)
	local u, v = HeightmapSource.ToMap(data, x, z)

	if u < 0 or u > 1 or v < 0 or v > 1 then
		local outside = data.outside

		if outside == "zero" then return 0 end

		if type(outside) == "number" then return outside end

		u, v = math.clamp(u, 0, 1), math.clamp(v, 0, 1)
	end

	local width, height = data.height.width, data.height.height
	local samples = data.height.samples
	local sample_x = math.min(u * width, width - 1)
	local sample_y = math.min(v * height, height - 1)
	local x0, y0 = math.floor(sample_x), math.floor(sample_y)
	local x1, y1 = math.min(x0 + 1, width - 1), math.min(y0 + 1, height - 1)
	local tx, ty = sample_x - x0, sample_y - y0
	local raw = math.lerp(
		ty,
		math.lerp(tx, samples[y0 * width + x0], samples[y0 * width + x1]),
		math.lerp(tx, samples[y1 * width + x0], samples[y1 * width + x1])
	)
	local min_height = data.min_height or 0
	return min_height + raw / 65535 * (data.max_height - min_height)
end

-- the surface type of the layer under a world position, nil without layers
function HeightmapSource.SampleSurface(data, x, z)
	local indices = data.indices

	if not indices then return nil end

	local u, v = HeightmapSource.ToMap(data, x, z)
	local row = math.clamp(math.floor(v * indices.height), 0, indices.height - 1)
	local column = math.clamp(math.floor(u * indices.width), 0, indices.width - 1)
	local layer = data.layers and data.layers[indices.samples[row * indices.width + column]]
	return layer and layer.surface
end

return HeightmapSource
