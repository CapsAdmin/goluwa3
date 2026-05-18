local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralTerrainSource = {}
ProceduralTerrainSource.__index = ProceduralTerrainSource
local TAU = 6.2831853
local COMMON_SHADER_HEADER = [[
float n2D(vec2 p) {
	vec2 i = floor(p);
	p -= i;
	p *= p * (3.0 - p * 2.0);
	return dot(
		mat2(fract(sin(mod(vec4(0.0, 1.0, 113.0, 114.0) + dot(i, vec2(1.0, 113.0)), 6.2831853)) * 43758.5453)) *
			vec2(1.0 - p.y, p.y),
		vec2(1.0 - p.x, p.x)
	);
}

mat2 rot2(in float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(c, s, -s, c);
}

vec2 hash22(vec2 p) {
	float n = sin(dot(p, vec2(113.0, 1.0)));
	return fract(vec2(2097152.0, 262144.0) * n) * 2.0 - 1.0;
}

float gradN2D(in vec2 f) {
	const vec2 e = vec2(0.0, 1.0);
	vec2 p = floor(f);
	f -= p;
	vec2 w = f * f * (3.0 - 2.0 * f);
	float c = mix(
		mix(dot(hash22(p + e.xx), f - e.xx), dot(hash22(p + e.yx), f - e.yx), w.x),
		mix(dot(hash22(p + e.xy), f - e.xy), dot(hash22(p + e.yy), f - e.yy), w.x),
		w.y
	);
	return c * 0.5 + 0.5;
}

float grad(float x, float offs) {
	x = abs(fract(x / 6.283 + offs - 0.25) - 0.5) * 2.0;
	float x2 = clamp(x * x * (-1.0 + 2.0 * x), 0.0, 1.0);
	x = smoothstep(0.0, 1.0, x);
	return mix(x, x2, 0.15);
}

float sandL(vec2 p) {
	vec2 q = rot2(3.14159 / 18.0) * p;
	q.y += (gradN2D(q * 18.0) - 0.5) * 0.05;
	float grad1 = grad(q.y * 80.0, 0.0);
	q = rot2(-3.14159 / 20.0) * p;
	q.y += (gradN2D(q * 12.0) - 0.5) * 0.05;
	float grad2 = grad(q.y * 80.0, 0.5);
	q = rot2(3.14159 / 4.0) * p;
	float a2 = dot(sin(q * 12.0 - cos(q.yx * 12.0)), vec2(0.25)) + 0.5;
	float a1 = 1.0 - a2;
	return 1.0 - (1.0 - grad1 * a1) * (1.0 - grad2 * a2);
}

float sand(vec2 p) {
	p = vec2(p.y - p.x, p.x + p.y) * 0.7071 / 4.0;
	float c1 = sandL(p);
	vec2 q = rot2(3.14159 / 12.0) * p;
	float c2 = sandL(q * 1.25);
	return mix(c1, c2, smoothstep(0.1, 0.9, gradN2D(p * vec2(4.0))));
}

float ridgeNoise(vec2 p) {
	return 1.0 - abs(gradN2D(p) * 2.0 - 1.0);
}
]]
local TERRAIN_PROFILE_GLSL = {
	desert = [[

float sampleTerrainHeight01(vec2 world_pos) {
	vec2 macro_uv = world_pos * 0.0011;
	float macro = n2D(macro_uv * 0.7) * 0.52;
	macro += n2D(macro_uv * 1.9 + vec2(4.3, -1.2)) * 0.28;
	macro += n2D(macro_uv * 4.4 + vec2(-8.1, 6.7)) * 0.20;
	float ridge = 1.0 - abs(n2D(macro_uv * 2.3 + vec2(2.0, -3.0)) - 0.5) * 2.0;
	ridge = smoothstep(0.15, 1.0, ridge * ridge);
	float dune = sand(world_pos * 0.0032) * 0.14;
	float valley = smoothstep(0.2, 0.9, n2D(macro_uv * 0.32 + vec2(-11.0, 5.0)));
	float h = macro * 0.64 + ridge * 0.24 + dune * 0.12;
	h *= mix(0.84, 1.04, valley);
	return clamp(h, 0.0, 1.0);
}

float sampleTerrainDisplacement01(vec2 world_pos, float h01) {
	float ripples = sand(world_pos * 0.012);
	float grain = gradN2D(world_pos * 0.028 + vec2(7.0, -3.0));
	float detail = mix(ripples, grain, 0.35);
	return clamp(0.5 + (detail - 0.5) * 0.18, 0.0, 1.0);
}

vec3 sampleTerrainColorDetail(vec2 world_pos, float elevation, float h01) {
	float ripples = sand(world_pos * 0.0032);
	float macro = gradN2D(world_pos * 0.0018 + vec2(5.0, -3.0));
	float tint = mix(0.88, 1.14, ripples * 0.7 + macro * 0.3);
	return vec3(tint);
}
]],
	alpine = [[

float sampleTerrainHeight01(vec2 world_pos) {
	vec2 macro_uv = world_pos * 0.00042;
	float continent = smoothstep(0.18, 0.88, n2D(macro_uv * 0.55 + vec2(3.0, -5.0)));
	float massif = n2D(macro_uv * 1.35 + vec2(-4.0, 8.0));
	float ridged = pow(clamp(ridgeNoise(macro_uv * 3.8 + vec2(11.0, -7.0)), 0.0, 1.0), 3.4);
	float sharp = pow(clamp(ridgeNoise(macro_uv * 8.5 + vec2(-13.0, 17.0)), 0.0, 1.0), 5.2);
	float valleys = 1.0 - smoothstep(0.18, 0.7, n2D(macro_uv * 1.1 + vec2(14.0, 2.0)));
	float erosion = gradN2D(world_pos * 0.0016 + vec2(-9.0, 6.0));
	float shelf = gradN2D(world_pos * 0.0038 + vec2(7.0, -12.0));
	float h = continent * (0.16 + massif * 0.18 + ridged * 0.36 + sharp * 0.30);
	h *= mix(0.32, 1.0, valleys);
	h += (erosion - 0.5) * 0.08;
	h += max(shelf - 0.72, 0.0) * 0.08;
	h = pow(clamp(h, 0.0, 1.0), 0.72);
	return clamp(h, 0.0, 1.0);
}

float sampleTerrainDisplacement01(vec2 world_pos, float h01) {
	float rock = gradN2D(world_pos * 0.018) * 0.55 + ridgeNoise(world_pos * 0.026 + vec2(5.0, -8.0)) * 0.45;
	float cracks = ridgeNoise(world_pos * 0.044 + vec2(-11.0, 14.0));
	float snow = smoothstep(0.62, 0.94, h01);
	float detail = mix(rock, cracks, 0.35);
	detail = mix(detail, 0.5, snow * 0.85);
	return clamp(0.5 + (detail - 0.5) * 0.16, 0.0, 1.0);
}

vec3 sampleTerrainColorDetail(vec2 world_pos, float elevation, float h01) {
	float rock = gradN2D(world_pos * 0.0024) * 0.65 + gradN2D(world_pos * 0.009) * 0.35;
	float snow = smoothstep(0.62, 0.94, h01);
	vec3 tint = vec3(mix(0.82, 1.10, rock));
	tint = mix(tint, vec3(1.02, 1.03, 1.05), snow * 0.45);
	return tint;
}
]],
}

local function fract(value)
	return value - math.floor(value)
end

local function clamp(value, min_value, max_value)
	if value < min_value then return min_value end

	if value > max_value then return max_value end

	return value
end

local function mix(a, b, t)
	return a + (b - a) * t
end

local function smoothstep(edge0, edge1, value)
	if edge0 == edge1 then return value >= edge1 and 1 or 0 end

	local t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function mod(value, base)
	return value - math.floor(value / base) * base
end

local function dot2(ax, ay, bx, by)
	return ax * bx + ay * by
end

local function rotate2(x, y, angle)
	local c = math.cos(angle)
	local s = math.sin(angle)
	return c * x - s * y, s * x + c * y
end

local function n2D(x, y)
	local ix = math.floor(x)
	local iy = math.floor(y)
	local fx = x - ix
	local fy = y - iy
	fx = fx * fx * (3 - fx * 2)
	fy = fy * fy * (3 - fy * 2)
	local dot_i = dot2(ix, iy, 1, 113)
	local s0 = fract(math.sin(mod(0 + dot_i, TAU)) * 43758.5453)
	local s1 = fract(math.sin(mod(1 + dot_i, TAU)) * 43758.5453)
	local s2 = fract(math.sin(mod(113 + dot_i, TAU)) * 43758.5453)
	local s3 = fract(math.sin(mod(114 + dot_i, TAU)) * 43758.5453)
	local col0 = s0 * (1 - fy) + s2 * fy
	local col1 = s1 * (1 - fy) + s3 * fy
	return col0 * (1 - fx) + col1 * fx
end

local function hash22(x, y)
	local n = math.sin(dot2(x, y, 113, 1))
	return fract(2097152 * n) * 2 - 1, fract(262144 * n) * 2 - 1
end

local function gradN2D(x, y)
	local px = math.floor(x)
	local py = math.floor(y)
	local fx = x - px
	local fy = y - py
	local wx = fx * fx * (3 - 2 * fx)
	local wy = fy * fy * (3 - 2 * fy)
	local h00x, h00y = hash22(px + 0, py + 0)
	local h10x, h10y = hash22(px + 1, py + 0)
	local h01x, h01y = hash22(px + 0, py + 1)
	local h11x, h11y = hash22(px + 1, py + 1)
	local c0 = mix(dot2(h00x, h00y, fx - 0, fy - 0), dot2(h10x, h10y, fx - 1, fy - 0), wx)
	local c1 = mix(dot2(h01x, h01y, fx - 0, fy - 1), dot2(h11x, h11y, fx - 1, fy - 1), wx)
	return mix(c0, c1, wy) * 0.5 + 0.5
end

local function ridge_noise(x, y)
	return 1 - math.abs(gradN2D(x, y) * 2 - 1)
end

local function grad_wave(x, offs)
	x = math.abs(fract(x / 6.283 + offs - 0.25) - 0.5) * 2
	local x2 = clamp(x * x * (-1 + 2 * x), 0, 1)
	x = smoothstep(0, 1, x)
	return mix(x, x2, 0.15)
end

local function sand_l(x, y)
	local qx, qy = rotate2(x, y, 3.14159 / 18.0)
	qy = qy + (gradN2D(qx * 18.0, qy * 18.0) - 0.5) * 0.05
	local grad1 = grad_wave(qy * 80.0, 0.0)
	qx, qy = rotate2(x, y, -3.14159 / 20.0)
	qy = qy + (gradN2D(qx * 12.0, qy * 12.0) - 0.5) * 0.05
	local grad2 = grad_wave(qy * 80.0, 0.5)
	qx, qy = rotate2(x, y, 3.14159 / 4.0)
	local a2 = (
			math.sin(qx * 12.0 - math.cos(qy * 12.0)) + math.sin(qy * 12.0 - math.cos(qx * 12.0))
		) * 0.25 + 0.5
	local a1 = 1 - a2
	return 1 - (1 - grad1 * a1) * (1 - grad2 * a2)
end

local function sand(x, y)
	local px = (y - x) * 0.7071 / 4.0
	local py = (x + y) * 0.7071 / 4.0
	local c1 = sand_l(px, py)
	local qx, qy = rotate2(px, py, 3.14159 / 12.0)
	local c2 = sand_l(qx * 1.25, qy * 1.25)
	return mix(c1, c2, smoothstep(0.1, 0.9, gradN2D(px * 4.0, py * 4.0)))
end

local function get_seed_offsets(seed)
	seed = tonumber(seed) or 1337
	return Vec2(math.sin(seed * 12.9898) * 16384.0, math.cos(seed * 78.2330) * 16384.0)
end

local function get_color_components(color)
	if color.r then return color.r, color.g, color.b end

	return color[1] or color.x or 1,
	color[2] or color.y or 1,
	color[3] or color.z or 1
end

local function build_default_material_layers(bands)
	local layers = {}
	local default_roughness = {0.96, 0.88, 0.72, 0.42}
	local default_ao = {0.92, 0.96, 0.90, 0.84}

	for i = 1, math.min(4, #(bands or {})) do
		local band = bands[i]
		local r, g, b = get_color_components(band.color or {1, 1, 1})
		layers[#layers + 1] = {
			max_elevation = band.max_elevation,
			checker_scale = 1,
			blend_range = 32,
			roughness = default_roughness[i] or 0.7,
			ambient_occlusion = default_ao[i] or 1.0,
			color_a = {
				clamp(r * 1.08, 0, 1),
				clamp(g * 1.08, 0, 1),
				clamp(b * 1.08, 0, 1),
			},
			color_b = {
				clamp(r * 0.72, 0, 1),
				clamp(g * 0.72, 0, 1),
				clamp(b * 0.72, 0, 1),
			},
		}
	end

	if #layers == 0 then
		layers[1] = {
			checker_scale = 1,
			color_a = {0.8, 0.8, 0.8},
			color_b = {0.5, 0.5, 0.5},
		}
	end

	return layers
end

local function get_material_layer_checker_colors(layer)
	local color_a = layer.color_a or layer.color or {1, 1, 1}
	local color_b = layer.color_b or layer.color2 or layer.color_alt or color_a
	local a_r, a_g, a_b = get_color_components(color_a)
	local b_r, b_g, b_b = get_color_components(color_b)
	return a_r, a_g, a_b, b_r, b_g, b_b
end

local function prepare_material_layers(layers, height_scale)
	for i = 1, #layers do
		local layer = layers[i]
		local a_r, a_g, a_b, b_r, b_g, b_b = get_material_layer_checker_colors(layer)
		layer._checker_scale = math.max(0.0001, layer.checker_scale or 1)
		layer._checker_a_r = a_r
		layer._checker_a_g = a_g
		layer._checker_a_b = a_b
		layer._checker_b_r = b_r
		layer._checker_b_g = b_g
		layer._checker_b_b = b_b
		layer._blend_range_height01 = math.max(layer.blend_height01 or layer.blend_range or 0.06, 0.0001)
		layer._blend_range_elevation = math.max(
			layer.blend_elevation or layer.blend_range or math.max(12, height_scale * 0.08),
			0.0001
		)
	end

	return layers
end

local function pick_material_layer(layers, elevation, height01)
	for i = 1, #layers do
		local layer = layers[i]

		if layer.max_height01 ~= nil and height01 <= layer.max_height01 then
			return i, layer
		end

		if layer.max_elevation ~= nil and elevation <= layer.max_elevation then
			return i, layer
		end

		if layer.max_height01 == nil and layer.max_elevation == nil then
			return i, layer
		end
	end

	return #layers, layers[#layers]
end

local function uses_height01_material_layers(layers)
	for i = 1, #layers do
		if layers[i].max_height01 ~= nil then return true end
	end

	return false
end

local function get_material_layer_value(layer, use_height01)
	if use_height01 then return layer.max_height01 end

	return layer.max_elevation
end

local function get_material_layer_blend_range(layer, use_height01, height_scale)
	if use_height01 then
		return math.max(layer.blend_height01 or layer.blend_range or 0.06, 0.0001)
	end

	return math.max(
		layer.blend_elevation or layer.blend_range or math.max(12, height_scale * 0.08),
		0.0001
	)
end

local function get_material_layer_slope_weight(layer, slope01)
	local min_slope = layer.min_slope
	local max_slope = layer.max_slope

	if min_slope == nil and max_slope == nil then return 1 end

	local blend = math.max(layer.slope_blend or 0.08, 0.0001)
	local weight = 1

	if min_slope ~= nil then
		weight = weight * smoothstep(min_slope - blend, min_slope + blend, slope01)
	end

	if max_slope ~= nil then
		weight = weight * (1 - smoothstep(max_slope - blend, max_slope + blend, slope01))
	end

	return clamp(weight, 0, 1)
end

local function normalize_material_weights(weights)
	local total = 0

	for i = 1, #weights do
		total = total + math.max(weights[i], 0)
	end

	if total <= 0 then return false end

	for i = 1, #weights do
		weights[i] = math.max(weights[i], 0) / total
	end

	return true
end

local function sample_material_checker_color(layer, world_x, world_z)
	local checker_scale = layer._checker_scale or math.max(0.0001, layer.checker_scale or 1)
	local checker_x = math.floor(world_x / checker_scale)
	local checker_z = math.floor(world_z / checker_scale)
	local is_a = (checker_x + checker_z) % 2 == 0

	if is_a then
		return layer._checker_a_r, layer._checker_a_g, layer._checker_a_b
	end

	return layer._checker_b_r, layer._checker_b_g, layer._checker_b_b
end

local function build_material_layer_glsl(layers)
	local use_height01 = uses_height01_material_layers(layers)
	local lines = {
		[[
vec3 sampleTerrainMaterialChecker(vec2 world_pos, float checker_scale, vec3 color_a, vec3 color_b) {
	float safe_scale = max(checker_scale, 0.0001);
	float checker = mod(floor(world_pos.x / safe_scale) + floor(world_pos.y / safe_scale), 2.0);
	return checker < 0.5 ? color_a : color_b;
}

vec3 pickTerrainMaterialColor(vec2 world_pos, float elevation, float h01) {
]],
	}

	for i = 1, #layers do
		local layer = layers[i]
		local a_r, a_g, a_b, b_r, b_g, b_b = get_material_layer_checker_colors(layer)
		local condition = nil

		if layer.max_height01 ~= nil then
			condition = string.format("h01 <= %.6f", layer.max_height01)
		elseif layer.max_elevation ~= nil then
			condition = string.format("elevation <= %.6f", layer.max_elevation)
		end

		local statement = string.format(
			"\treturn sampleTerrainMaterialChecker(world_pos, %.6f, vec3(%.6f, %.6f, %.6f), vec3(%.6f, %.6f, %.6f));",
			layer.checker_scale or 1,
			a_r,
			a_g,
			a_b,
			b_r,
			b_g,
			b_b
		)

		if condition then
			lines[#lines + 1] = string.format("\tif (%s) %s", condition, statement:match("return.+"))
		else
			lines[#lines + 1] = statement
		end
	end

	lines[#lines + 1] = "\treturn vec3(1.0, 1.0, 1.0);"
	lines[#lines + 1] = "}"
	lines[#lines + 1] = "vec4 getTerrainMaterialWeights(vec2 world_pos, float elevation, float h01, float slope01) {"
	lines[#lines + 1] = use_height01 and
		"\tfloat sample_value = h01;" or
		"\tfloat sample_value = elevation;"
	lines[#lines + 1] = "\tvec4 weights = vec4(0.0);"
	local previous_value = nil

	for i = 1, math.min(#layers, 4) do
		local layer = layers[i]
		local upper_value = get_material_layer_value(layer, use_height01)
		local blend_range = use_height01 and layer._blend_range_height01 or layer._blend_range_elevation
		local rise_expression = "1.0"
		local fall_expression = "1.0"
		local slope_expression = "1.0"
		local slope_blend = math.max(layer.slope_blend or 0.08, 0.0001)

		if previous_value ~= nil then
			rise_expression = string.format(
				"smoothstep(%.6f, %.6f, sample_value)",
				previous_value - blend_range,
				previous_value + blend_range
			)
		end

		if upper_value ~= nil then
			fall_expression = string.format(
				"(1.0 - smoothstep(%.6f, %.6f, sample_value))",
				upper_value - blend_range,
				upper_value + blend_range
			)
		end

		if layer.min_slope ~= nil then
			slope_expression = string.format(
				"%s * smoothstep(%.6f, %.6f, slope01)",
				slope_expression,
				layer.min_slope - slope_blend,
				layer.min_slope + slope_blend
			)
		end

		if layer.max_slope ~= nil then
			slope_expression = string.format(
				"%s * (1.0 - smoothstep(%.6f, %.6f, slope01))",
				slope_expression,
				layer.max_slope - slope_blend,
				layer.max_slope + slope_blend
			)
		end

		lines[#lines + 1] = string.format(
			"\tweights[%d] = clamp((%s) * (%s) * (%s), 0.0, 1.0);",
			i - 1,
			rise_expression,
			fall_expression,
			slope_expression
		)
		previous_value = upper_value or previous_value
	end

	lines[#lines + 1] = "\tweights = max(weights, vec4(0.0));"
	lines[#lines + 1] = "\tfloat total = dot(weights, vec4(1.0));"
	lines[#lines + 1] = "\tif (total <= 0.0001) {"

	for i = 1, math.min(#layers, 4) do
		local layer = layers[i]
		local condition = nil

		if layer.max_height01 ~= nil then
			condition = string.format("h01 <= %.6f", layer.max_height01)
		elseif layer.max_elevation ~= nil then
			condition = string.format("elevation <= %.6f", layer.max_elevation)
		end

		if condition then
			lines[#lines + 1] = string.format(
				"\t\tif (%s) return vec4(%s);",
				condition,
				(
					{
						"1.0, 0.0, 0.0, 0.0",
						"0.0, 1.0, 0.0, 0.0",
						"0.0, 0.0, 1.0, 0.0",
						"0.0, 0.0, 0.0, 1.0",
					}
				)[i]
			)
		else
			lines[#lines + 1] = string.format(
				"\t\treturn vec4(%s);",
				(
					{
						"1.0, 0.0, 0.0, 0.0",
						"0.0, 1.0, 0.0, 0.0",
						"0.0, 0.0, 1.0, 0.0",
						"0.0, 0.0, 0.0, 1.0",
					}
				)[i]
			)
		end
	end

	lines[#lines + 1] = "\t\treturn vec4(1.0, 0.0, 0.0, 0.0);"
	lines[#lines + 1] = "\t}"
	lines[#lines + 1] = "\treturn weights / total;"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function build_band_glsl(bands)
	local lines = {"vec3 pickTerrainColor(float elevation) {"}

	for i = 1, #bands do
		local band = bands[i]
		local r, g, b = get_color_components(band.color or {1, 1, 1})
		local condition = band.max_elevation and
			string.format("elevation <= %.6f", band.max_elevation) or
			nil

		if condition then
			lines[#lines + 1] = string.format("\tif (%s) return vec3(%.6f, %.6f, %.6f);", condition, r, g, b)
		else
			lines[#lines + 1] = string.format("\treturn vec3(%.6f, %.6f, %.6f);", r, g, b)
		end
	end

	lines[#lines + 1] = "\treturn vec3(1.0, 1.0, 1.0);"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function pick_band_color(bands, elevation)
	for i = 1, #bands do
		local band = bands[i]

		if band.max_elevation == nil or elevation <= band.max_elevation then
			return get_color_components(band.color or {1, 1, 1})
		end
	end

	return 1, 1, 1
end

local PROFILE_SAMPLERS = {
	desert = function(world_x, world_z, seed_offset)
		local world_pos_x = world_x + seed_offset.x
		local world_pos_z = world_z + seed_offset.y
		local macro_uv_x = world_pos_x * 0.0011
		local macro_uv_z = world_pos_z * 0.0011
		local macro = n2D(macro_uv_x * 0.7, macro_uv_z * 0.7) * 0.52
		macro = macro + n2D(macro_uv_x * 1.9 + 4.3, macro_uv_z * 1.9 - 1.2) * 0.28
		macro = macro + n2D(macro_uv_x * 4.4 - 8.1, macro_uv_z * 4.4 + 6.7) * 0.20
		local ridge = 1 - math.abs(n2D(macro_uv_x * 2.3 + 2.0, macro_uv_z * 2.3 - 3.0) - 0.5) * 2
		ridge = smoothstep(0.15, 1.0, ridge * ridge)
		local dune = sand(world_pos_x * 0.0032, world_pos_z * 0.0032) * 0.14
		local valley = smoothstep(0.2, 0.9, n2D(macro_uv_x * 0.32 - 11.0, macro_uv_z * 0.32 + 5.0))
		local h = macro * 0.64 + ridge * 0.24 + dune * 0.12
		h = h * mix(0.84, 1.04, valley)
		return clamp(h, 0, 1)
	end,
	alpine = function(world_x, world_z, seed_offset)
		local world_pos_x = world_x + seed_offset.x
		local world_pos_z = world_z + seed_offset.y
		local macro_uv_x = world_pos_x * 0.00042
		local macro_uv_z = world_pos_z * 0.00042
		local continent = smoothstep(0.18, 0.88, n2D(macro_uv_x * 0.55 + 3.0, macro_uv_z * 0.55 - 5.0))
		local massif = n2D(macro_uv_x * 1.35 - 4.0, macro_uv_z * 1.35 + 8.0)
		local ridged = clamp(ridge_noise(macro_uv_x * 3.8 + 11.0, macro_uv_z * 3.8 - 7.0), 0, 1) ^ 3.4
		local sharp = clamp(ridge_noise(macro_uv_x * 8.5 - 13.0, macro_uv_z * 8.5 + 17.0), 0, 1) ^ 5.2
		local valleys = 1 - smoothstep(0.18, 0.7, n2D(macro_uv_x * 1.1 + 14.0, macro_uv_z * 1.1 + 2.0))
		local erosion = gradN2D(world_pos_x * 0.0016 - 9.0, world_pos_z * 0.0016 + 6.0)
		local shelf = gradN2D(world_pos_x * 0.0038 + 7.0, world_pos_z * 0.0038 - 12.0)
		local h = continent * (0.16 + massif * 0.18 + ridged * 0.36 + sharp * 0.30)
		h = h * mix(0.32, 1.0, valleys)
		h = h + (erosion - 0.5) * 0.08
		h = h + math.max(shelf - 0.72, 0.0) * 0.08
		h = clamp(h, 0, 1) ^ 0.72
		return clamp(h, 0, 1)
	end,
}

function ProceduralTerrainSource.New(config)
	config = config or {}
	local self = setmetatable({}, ProceduralTerrainSource)
	self.Seed = config.Seed or 1337
	self.SeedOffset = config.SeedOffset or get_seed_offsets(self.Seed)
	self.TerrainProfile = config.TerrainProfile or config.TerrainStyle or "desert"
	self.HeightScale = config.HeightScale or 512
	self.VerticalOffset = config.VerticalOffset or 0
	self.MaterialBands = config.MaterialBands or
		{
			{max_elevation = -80, color = {0.29, 0.24, 0.19}},
			{max_elevation = 10, color = {0.64, 0.54, 0.36}},
			{max_elevation = 90, color = {0.79, 0.69, 0.48}},
			{color = {0.92, 0.86, 0.74}},
		}
	self.MaterialLayers = prepare_material_layers(
		config.MaterialLayers or build_default_material_layers(self.MaterialBands),
		self.HeightScale
	)
	self.MaterialLayersUseHeight01 = uses_height01_material_layers(self.MaterialLayers)
	self.ShaderHeader = COMMON_SHADER_HEADER .. "\n" .. (
			TERRAIN_PROFILE_GLSL[self.TerrainProfile] or
			TERRAIN_PROFILE_GLSL.desert
		)
	return self
end

function ProceduralTerrainSource:GetShaderHeader()
	return self.ShaderHeader
end

function ProceduralTerrainSource:GetMaterialShaderHeader()
	return self.ShaderHeader .. "\n" .. build_band_glsl(self.MaterialBands) .. "\n" .. build_material_layer_glsl(self.MaterialLayers)
end

function ProceduralTerrainSource:BuildBandGLSL()
	return build_band_glsl(self.MaterialBands)
end

function ProceduralTerrainSource:BuildAlbedoShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	texture_width = math.max(1, texture_width or 1)
	texture_height = math.max(1, texture_height or texture_width)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 world_pos = vec2(%.6f, %.6f) + uv01 * %.6f + vec2(%.6f, %.6f);
		float h01 = sampleTerrainHeight01(world_pos);
		float elevation = %.6f + h01 * %.6f - %.6f;
		vec3 col = pickTerrainMaterialColor(world_pos, elevation, h01);
		col *= sampleTerrainColorDetail(world_pos, elevation, h01);
		return vec4(col, 1.0);
	]],
		texture_width,
		texture_height,
		texture_width - 1,
		texture_height - 1,
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y,
		self.VerticalOffset,
		self.HeightScale,
		self.HeightScale * 0.5
	)
end

function ProceduralTerrainSource:BuildHeightShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	texture_width = math.max(1, texture_width or 1)
	texture_height = math.max(1, texture_height or texture_width)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 world_pos = vec2(%.6f, %.6f) + uv01 * %.6f + vec2(%.6f, %.6f);
		float h01 = sampleTerrainHeight01(world_pos);
		return vec4(h01, h01, h01, 1.0);
	]],
		texture_width,
		texture_height,
		texture_width - 1,
		texture_height - 1,
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y
	)
end

function ProceduralTerrainSource:BuildNormalShader(
	chunk_min_x,
	chunk_min_z,
	chunk_world_size,
	texture_width,
	texture_height,
	normal_strength
)
	texture_width = math.max(1, texture_width or 128)
	texture_height = math.max(1, texture_height or texture_width)
	normal_strength = normal_strength or 1
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 world_pos = vec2(%.6f, %.6f) + uv01 * %.6f + vec2(%.6f, %.6f);
		vec2 sample_step = vec2(%.6f, %.6f);
		float h_left = sampleTerrainHeight01(world_pos - vec2(sample_step, 0.0)) * %.6f;
		float h_right = sampleTerrainHeight01(world_pos + vec2(sample_step, 0.0)) * %.6f;
		float h_down = sampleTerrainHeight01(world_pos - vec2(0.0, sample_step)) * %.6f;
		float h_up = sampleTerrainHeight01(world_pos + vec2(0.0, sample_step)) * %.6f;
		vec3 tangent_normal = normalize(vec3((h_left - h_right) * %.6f, (h_down - h_up) * %.6f, sample_step.x + sample_step.y));
		return vec4(tangent_normal * 0.5 + 0.5, 1.0);
	]],
		texture_width,
		texture_height,
		texture_width - 1,
		texture_height - 1,
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y,
		chunk_world_size / math.max(texture_width - 1, 1),
		chunk_world_size / math.max(texture_height - 1, 1),
		self.HeightScale,
		self.HeightScale,
		self.HeightScale,
		self.HeightScale,
		normal_strength,
		normal_strength
	)
end

function ProceduralTerrainSource:BuildMaterialShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	texture_width = math.max(1, texture_width or 128)
	texture_height = math.max(1, texture_height or texture_width)
	local sample_step_x = chunk_world_size / math.max(texture_width - 1, 1)
	local sample_step_y = chunk_world_size / math.max(texture_height - 1, 1)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 world_pos = vec2(%.6f, %.6f) + uv01 * %.6f + vec2(%.6f, %.6f);
		float h01 = sampleTerrainHeight01(world_pos);
		float elevation = %.6f + h01 * %.6f - %.6f;
		vec2 sample_step = vec2(%.6f, %.6f);
		float h_left = sampleTerrainHeight01(world_pos - vec2(sample_step, 0.0)) * %.6f;
		float h_right = sampleTerrainHeight01(world_pos + vec2(sample_step, 0.0)) * %.6f;
		float h_down = sampleTerrainHeight01(world_pos - vec2(0.0, sample_step)) * %.6f;
		float h_up = sampleTerrainHeight01(world_pos + vec2(0.0, sample_step)) * %.6f;
		float dx = (h_right - h_left) / max(sample_step.x * 2.0, 0.0001);
		float dz = (h_up - h_down) / max(sample_step.y * 2.0, 0.0001);
		float slope01 = smoothstep(0.04, 1.2, sqrt(dx * dx + dz * dz));
		return getTerrainMaterialWeights(world_pos, elevation, h01, slope01);
	]],
		texture_width,
		texture_height,
		texture_width - 1,
		texture_height - 1,
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y,
		self.VerticalOffset,
		self.HeightScale,
		self.HeightScale * 0.5,
		sample_step_x,
		sample_step_y,
		self.HeightScale,
		self.HeightScale,
		self.HeightScale,
		self.HeightScale
	)
end

function ProceduralTerrainSource:SampleMaterialWeights(world_x, world_z, height01)
	height01 = height01 or self:SampleHeight01(world_x, world_z)
	local elevation = self.VerticalOffset + height01 * self.HeightScale - self.HeightScale * 0.5
	local slope01 = self:SampleSlope01(world_x, world_z)
	return self:ComputeMaterialWeights(height01, elevation, slope01)
end

function ProceduralTerrainSource:ComputeMaterialWeights(height01, elevation, slope01)
	local layers = self.MaterialLayers or {}
	local use_height01 = self.MaterialLayersUseHeight01
	local sample_value = use_height01 and height01 or elevation
	local previous_value = nil
	local w1, w2, w3, w4 = 0, 0, 0, 0
	local layer_count = math.min(#layers, 4)

	for i = 1, layer_count do
		local layer = layers[i]
		local upper_value = get_material_layer_value(layer, use_height01)
		local blend_range = use_height01 and layer._blend_range_height01 or layer._blend_range_elevation
		local rise = 1
		local fall = 1

		if previous_value ~= nil then
			rise = smoothstep(previous_value - blend_range, previous_value + blend_range, sample_value)
		end

		if upper_value ~= nil then
			fall = 1 - smoothstep(upper_value - blend_range, upper_value + blend_range, sample_value)
		end

		local weight = clamp(rise * fall * get_material_layer_slope_weight(layer, slope01), 0, 1)

		if i == 1 then
			w1 = weight
		elseif i == 2 then
			w2 = weight
		elseif i == 3 then
			w3 = weight
		else
			w4 = weight
		end

		previous_value = upper_value or previous_value
	end

	local total = math.max(w1, 0) + math.max(w2, 0) + math.max(w3, 0) + math.max(w4, 0)

	if total <= 0 then
		local index = pick_material_layer(layers, elevation, height01)
		index = math.min(math.max(index, 1), 4)

		if index == 1 then
			w1 = 1
		elseif index == 2 then
			w2 = 1
		elseif index == 3 then
			w3 = 1
		else
			w4 = 1
		end
	else
		local inv_total = 1 / total
		w1 = math.max(w1, 0) * inv_total
		w2 = math.max(w2, 0) * inv_total
		w3 = math.max(w3, 0) * inv_total
		w4 = math.max(w4, 0) * inv_total
	end

	return w1, w2, w3, w4, elevation
end

function ProceduralTerrainSource:SampleMaterialColor(world_x, world_z, height01, elevation, slope01)
	height01 = height01 or self:SampleHeight01(world_x, world_z)
	elevation = elevation or
		self.VerticalOffset + height01 * self.HeightScale - self.HeightScale * 0.5
	local w1, w2, w3, w4 = self:ComputeMaterialWeights(height01, elevation, slope01 or self:SampleSlope01(world_x, world_z))
	local r, g, b = 0, 0, 0

	for i = 1, math.min(#(self.MaterialLayers or {}), 4) do
		local layer = self.MaterialLayers[i]
		local weight = i == 1 and w1 or i == 2 and w2 or i == 3 and w3 or w4

		if layer and weight > 0 then
			local lr, lg, lb = sample_material_checker_color(layer, world_x, world_z)
			r = r + lr * weight
			g = g + lg * weight
			b = b + lb * weight
		end
	end

	return r, g, b, elevation
end

function ProceduralTerrainSource:BuildDisplacementShader(chunk_min_x, chunk_min_z, chunk_world_size)
	return string.format(
		[[
		vec2 world_pos = vec2(%.6f, %.6f) + uv * %.6f + vec2(%.6f, %.6f);
		float h01 = sampleTerrainHeight01(world_pos);
		float h = sampleTerrainDisplacement01(world_pos, h01);
		return vec4(h, h, h, 1.0);
	]],
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y
	)
end

function ProceduralTerrainSource:SampleDisplacement01(world_x, world_z, height01)
	height01 = height01 or self:SampleHeight01(world_x, world_z)
	local world_pos_x = world_x + self.SeedOffset.x
	local world_pos_z = world_z + self.SeedOffset.y

	if self.TerrainProfile == "alpine" then
		local rock = gradN2D(world_pos_x * 0.018, world_pos_z * 0.018) * 0.55 + ridge_noise(world_pos_x * 0.026 + 5.0, world_pos_z * 0.026 - 8.0) * 0.45
		local cracks = ridge_noise(world_pos_x * 0.044 - 11.0, world_pos_z * 0.044 + 14.0)
		local snow = smoothstep(0.62, 0.94, height01)
		local detail = mix(rock, cracks, 0.35)
		detail = mix(detail, 0.5, snow * 0.85)
		return clamp(0.5 + (detail - 0.5) * 0.16, 0.0, 1.0)
	end

	local ripples = sand(world_pos_x * 0.012, world_pos_z * 0.012)
	local grain = gradN2D(world_pos_x * 0.028 + 7.0, world_pos_z * 0.028 - 3.0)
	local detail = mix(ripples, grain, 0.35)
	return clamp(0.5 + (detail - 0.5) * 0.18, 0.0, 1.0)
end

function ProceduralTerrainSource:SampleColorDetail(world_x, world_z, elevation, height01)
	height01 = height01 or self:SampleHeight01(world_x, world_z)
	elevation = elevation or self:SampleWorldHeight(world_x, world_z)
	local world_pos_x = world_x + self.SeedOffset.x
	local world_pos_z = world_z + self.SeedOffset.y

	if self.TerrainProfile == "alpine" then
		local rock = gradN2D(world_pos_x * 0.0024, world_pos_z * 0.0024) * 0.65 + gradN2D(world_pos_x * 0.009, world_pos_z * 0.009) * 0.35
		local snow = smoothstep(0.62, 0.94, height01)
		local tint = mix(0.82, 1.10, rock)
		local r = mix(tint, 1.02, snow * 0.45)
		local g = mix(tint, 1.03, snow * 0.45)
		local b = mix(tint, 1.05, snow * 0.45)
		return r, g, b
	end

	local ripples = sand(world_pos_x * 0.0032, world_pos_z * 0.0032)
	local macro = gradN2D(world_pos_x * 0.0018 + 5.0, world_pos_z * 0.0018 - 3.0)
	local tint = mix(0.88, 1.14, ripples * 0.7 + macro * 0.3)
	return tint, tint, tint
end

function ProceduralTerrainSource:SampleAlbedo(world_x, world_z, height01)
	height01 = height01 or self:SampleHeight01(world_x, world_z)
	local base_r, base_g, base_b, elevation = self:SampleMaterialColor(world_x, world_z, height01)
	local detail_r, detail_g, detail_b = self:SampleColorDetail(world_x, world_z, elevation, height01)
	return clamp(base_r * detail_r, 0, 1),
	clamp(base_g * detail_g, 0, 1),
	clamp(base_b * detail_b, 0, 1),
	elevation
end

function ProceduralTerrainSource:SampleNormal(world_x, world_z, sample_step_x, sample_step_z, normal_strength)
	sample_step_x = sample_step_x or 1
	sample_step_z = sample_step_z or sample_step_x
	normal_strength = normal_strength or 1
	local h_left = self:SampleHeight01(world_x - sample_step_x, world_z) * self.HeightScale
	local h_right = self:SampleHeight01(world_x + sample_step_x, world_z) * self.HeightScale
	local h_down = self:SampleHeight01(world_x, world_z - sample_step_z) * self.HeightScale
	local h_up = self:SampleHeight01(world_x, world_z + sample_step_z) * self.HeightScale
	local nx = (h_left - h_right) * normal_strength
	local ny = (h_down - h_up) * normal_strength
	local nz = sample_step_x + sample_step_z
	local length = math.sqrt(nx * nx + ny * ny + nz * nz)

	if length <= 0 then return 0.5, 0.5, 1.0, 1.0 end

	nx = nx / length
	ny = ny / length
	nz = nz / length
	return nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0
end

function ProceduralTerrainSource:SampleSlope01(world_x, world_z, sample_step_x, sample_step_z)
	sample_step_x = sample_step_x or self.MaterialSlopeSampleStep or 2
	sample_step_z = sample_step_z or sample_step_x
	local h_left = self:SampleHeight01(world_x - sample_step_x, world_z) * self.HeightScale
	local h_right = self:SampleHeight01(world_x + sample_step_x, world_z) * self.HeightScale
	local h_down = self:SampleHeight01(world_x, world_z - sample_step_z) * self.HeightScale
	local h_up = self:SampleHeight01(world_x, world_z + sample_step_z) * self.HeightScale
	local dx = (h_right - h_left) / math.max(sample_step_x * 2, 0.0001)
	local dz = (h_up - h_down) / math.max(sample_step_z * 2, 0.0001)
	local gradient = math.sqrt(dx * dx + dz * dz)
	return smoothstep(0.04, 1.2, gradient)
end

local function normalize_tile_config(config)
	local width = math.max(1, math.floor(config.width or config.size or 1))
	local height = math.max(1, math.floor(config.height or config.size or width))
	local min_x = config.min_x or 0
	local min_z = config.min_z or 0
	local span_x = config.span_x or config.world_size or config.size_x or 1
	local span_z = config.span_z or config.world_size or config.size_z or span_x
	local denom_x = math.max(1, width - 1)
	local denom_z = math.max(1, height - 1)
	return {
		width = width,
		height = height,
		min_x = min_x,
		min_z = min_z,
		span_x = span_x,
		span_z = span_z,
		step_x = span_x / denom_x,
		step_z = span_z / denom_z,
	}
end

local function build_height_grid(source, tile, padding)
	padding = padding or 0
	local grid_width = tile.width + padding * 2
	local grid_height = tile.height + padding * 2
	local samples = {}
	local index = 1
	local min_x = tile.min_x
	local min_z = tile.min_z
	local step_x = tile.step_x
	local step_z = tile.step_z

	for y = 0, grid_height - 1 do
		local world_z = min_z + (y - padding) * step_z

		for x = 0, grid_width - 1 do
			local world_x = min_x + (x - padding) * step_x
			samples[index] = source:SampleHeight01(world_x, world_z)
			index = index + 1
		end
	end

	return {
		samples = samples,
		width = grid_width,
		height = grid_height,
		padding = padding,
		step_x = tile.step_x,
		step_z = tile.step_z,
	}
end

local function get_height_grid_sample(grid, x, y)
	x = math.clamp(x + grid.padding, 0, grid.width - 1)
	y = math.clamp(y + grid.padding, 0, grid.height - 1)
	return grid.samples[y * grid.width + x + 1]
end

local function get_height_grid_sample_unclamped(grid, x, y)
	return grid.samples[(y + grid.padding) * grid.width + x + grid.padding + 1]
end

local function get_slope01_from_height_grid(source, grid, x, y)
	local h_left = get_height_grid_sample_unclamped(grid, x - 1, y) * source.HeightScale
	local h_right = get_height_grid_sample_unclamped(grid, x + 1, y) * source.HeightScale
	local h_down = get_height_grid_sample_unclamped(grid, x, y - 1) * source.HeightScale
	local h_up = get_height_grid_sample_unclamped(grid, x, y + 1) * source.HeightScale
	local dx = (h_right - h_left) / math.max(grid.step_x * 2, 0.0001)
	local dz = (h_up - h_down) / math.max(grid.step_z * 2, 0.0001)
	local gradient = math.sqrt(dx * dx + dz * dz)
	return smoothstep(0.04, 1.2, gradient)
end

local function get_normal_from_height_grid(source, grid, x, y, normal_strength)
	normal_strength = normal_strength or 1
	local h_left = get_height_grid_sample_unclamped(grid, x - 1, y) * source.HeightScale
	local h_right = get_height_grid_sample_unclamped(grid, x + 1, y) * source.HeightScale
	local h_down = get_height_grid_sample_unclamped(grid, x, y - 1) * source.HeightScale
	local h_up = get_height_grid_sample_unclamped(grid, x, y + 1) * source.HeightScale
	local nx = (h_left - h_right) * normal_strength
	local ny = (h_down - h_up) * normal_strength
	local nz = grid.step_x + grid.step_z
	local length = math.sqrt(nx * nx + ny * ny + nz * nz)

	if length <= 0 then return 0.5, 0.5, 1.0, 1.0 end

	nx = nx / length
	ny = ny / length
	nz = nz / length
	return nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0
end

function ProceduralTerrainSource:GenerateHeightTile(config)
	local tile = normalize_tile_config(config or {})
	local samples = {}
	local index = 1
	local min_x = tile.min_x
	local min_z = tile.min_z
	local step_x = tile.step_x
	local step_z = tile.step_z

	for y = 0, tile.height - 1 do
		local world_z = min_z + y * step_z

		for x = 0, tile.width - 1 do
			local world_x = min_x + x * step_x
			samples[index] = self:SampleHeight01(world_x, world_z)
			index = index + 1
		end
	end

	return samples, tile.width, tile.height
end

function ProceduralTerrainSource:GenerateDisplacementTile(config)
	local tile = normalize_tile_config(config or {})
	local samples = {}
	local index = 1
	local min_x = tile.min_x
	local min_z = tile.min_z
	local step_x = tile.step_x
	local step_z = tile.step_z

	for y = 0, tile.height - 1 do
		local world_z = min_z + y * step_z

		for x = 0, tile.width - 1 do
			local world_x = min_x + x * step_x
			local height01 = self:SampleHeight01(world_x, world_z)
			samples[index] = self:SampleDisplacement01(world_x, world_z, height01)
			index = index + 1
		end
	end

	return samples, tile.width, tile.height
end

function ProceduralTerrainSource:GenerateAlbedoTile(config)
	local tile = normalize_tile_config(config or {})
	local samples = {}
	local height_grid = build_height_grid(self, tile, 1)
	local index = 1
	local min_x = tile.min_x
	local min_z = tile.min_z
	local step_x = tile.step_x
	local step_z = tile.step_z
	local height_scale = self.HeightScale
	local base_elevation = self.VerticalOffset - height_scale * 0.5

	for y = 0, tile.height - 1 do
		local world_z = min_z + y * step_z

		for x = 0, tile.width - 1 do
			local world_x = min_x + x * step_x
			local height01 = get_height_grid_sample_unclamped(height_grid, x, y)
			local elevation = base_elevation + height01 * height_scale
			local slope01 = get_slope01_from_height_grid(self, height_grid, x, y)
			local base_r, base_g, base_b = self:SampleMaterialColor(world_x, world_z, height01, elevation, slope01)
			local detail_r, detail_g, detail_b = self:SampleColorDetail(world_x, world_z, elevation, height01)
			samples[index] = clamp(base_r * detail_r, 0, 1)
			samples[index + 1] = clamp(base_g * detail_g, 0, 1)
			samples[index + 2] = clamp(base_b * detail_b, 0, 1)
			samples[index + 3] = 1
			index = index + 4
		end
	end

	return samples, tile.width, tile.height
end

function ProceduralTerrainSource:GenerateMaterialTile(config)
	local tile = normalize_tile_config(config or {})
	local samples = {}
	local height_grid = build_height_grid(self, tile, 1)
	local index = 1
	local min_x = tile.min_x
	local min_z = tile.min_z
	local step_x = tile.step_x
	local step_z = tile.step_z
	local height_scale = self.HeightScale
	local base_elevation = self.VerticalOffset - height_scale * 0.5

	for y = 0, tile.height - 1 do
		local world_z = min_z + y * step_z

		for x = 0, tile.width - 1 do
			local world_x = min_x + x * step_x
			local height01 = get_height_grid_sample_unclamped(height_grid, x, y)
			local elevation = base_elevation + height01 * height_scale
			local slope01 = get_slope01_from_height_grid(self, height_grid, x, y)
			local w1, w2, w3, w4 = self:ComputeMaterialWeights(height01, elevation, slope01)
			samples[index] = w1
			samples[index + 1] = w2
			samples[index + 2] = w3
			samples[index + 3] = w4
			index = index + 4
		end
	end

	return samples, tile.width, tile.height
end

function ProceduralTerrainSource:GenerateNormalTile(config)
	local tile = normalize_tile_config(config or {})
	local samples = {}
	local normal_strength = config and config.normal_strength or 1
	local height_grid = build_height_grid(self, tile, 1)
	local index = 1

	for y = 0, tile.height - 1 do
		for x = 0, tile.width - 1 do
			local r, g, b, a = get_normal_from_height_grid(self, height_grid, x, y, normal_strength)
			samples[index] = r
			samples[index + 1] = g
			samples[index + 2] = b
			samples[index + 3] = a
			index = index + 4
		end
	end

	return samples, tile.width, tile.height
end

function ProceduralTerrainSource:SampleHeight01(world_x, world_z)
	local sampler = PROFILE_SAMPLERS[self.TerrainProfile] or PROFILE_SAMPLERS.desert
	return sampler(world_x, world_z, self.SeedOffset)
end

function ProceduralTerrainSource:SampleLocalHeight(world_x, world_z)
	return self:SampleHeight01(world_x, world_z) * self.HeightScale - self.HeightScale * 0.5
end

function ProceduralTerrainSource:SampleWorldHeight(world_x, world_z)
	return self.VerticalOffset + self:SampleLocalHeight(world_x, world_z)
end

return ProceduralTerrainSource
