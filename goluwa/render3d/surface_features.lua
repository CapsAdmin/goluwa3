local surface_features = {}
surface_features.default_list = {
	import("goluwa/render3d/features/core.lua"),
	import("goluwa/render3d/features/specular.lua"),
	import("goluwa/render3d/features/transmission.lua"),
	import("goluwa/render3d/features/clearcoat.lua"),
	import("goluwa/render3d/features/secondary_specular.lua"),
	import("goluwa/render3d/features/sheen.lua"),
	import("goluwa/render3d/features/specular_tint.lua"),
	import("goluwa/render3d/features/displacement.lua"),
	import("goluwa/render3d/features/refraction.lua"),
	import("goluwa/render3d/features/weather_response.lua"),
	import("goluwa/render3d/features/terrain.lua"),
	import("goluwa/render3d/features/detail.lua"),
	import("goluwa/render3d/features/vegetation.lua"),
	import("goluwa/render3d/features/grass.lua"),
}

-- the registry of a list of features, the engine uses the one for default_list. a list is a
-- parameter so the generation can be tested with features of its own
function surface_features.New(source_list)
local self = {}
local list = {}

for i, source in ipairs(source_list) do
	list[i] = table.copy(source)
end

self.list = list

-- a field with a member (its name unless member says another, false for none) gets the member in
-- Surface, its default, its decode and its write generated, ahead of the feature's own snippets
for _, feature in ipairs(list) do
	local generated = {
		surface_members = {},
		surface_default = {},
		material_init = {},
		surface_decode = {},
		gbuffer_write = {},
	}

	for _, field in ipairs(feature.fields or {}) do
		local member = field.member

		if member == nil then member = field.name end

		if member then
			local type = field.kind == "octa" and "vec3" or "float"
			table.insert(generated.surface_members, string.format("%s %s;", type, member))

			if field.kind ~= "octa" then
				table.insert(generated.surface_default, string.format("s.%s = %s;", member, field.default))
				table.insert(
					generated.surface_decode,
					string.format("s.%s = gbuffer_%s(uv);", member, field.accessor or field.name)
				)
				table.insert(
					generated.gbuffer_write,
					field.encode and
						string.format("set_%s(gbuffer_encode_%s(s.%s));", field.name, field.name, member) or
						string.format("set_%s(s.%s);", field.name, member)
				)
			end

			if field.material then
				table.insert(generated.material_init, string.format("s.%s = %s;", member, field.material))
			end
		end
	end

	for key, lines in pairs(generated) do
		if #lines > 0 then
			feature[key] = table.concat(lines, "\n") .. "\n" .. (feature[key] or "")
		end
	end
end

function self.GetParams()
	local params = {}

	for _, feature in ipairs(list) do
		for _, param in ipairs(feature.params or {}) do
			params[#params + 1] = param
		end
	end

	return params
end

function self.GetFields()
	local fields = {}

	for _, feature in ipairs(list) do
		for _, field in ipairs(feature.fields or {}) do
			fields[#fields + 1] = field
		end
	end

	return fields
end

local function join(key)
	local out = {}

	for _, feature in ipairs(list) do
		if feature[key] then out[#out + 1] = feature[key] end
	end

	return table.concat(out, "\n")
end

local function build_function(signature, key)
	return signature .. " {\n" .. join(key) .. "\n}\n"
end

-- A feature is one table in features/*.lua. Every key is optional. The GLSL snippets are
-- statements, spliced in feature order, and `s` is the Surface they work on.
--
-- fields: gbuffer fields, see gbuffer_layout.lua. besides what it stores a field gives the
--   Surface a member, and the default, decode and write of it are generated. key member renames
--   the member (false for none, the feature then does it all), material is the GLSL expression the
--   member gets from the material, with uv in scope
-- params: material parameters, {name, default, requires, callback, kind, getter, getter_expression}.
--   They become Material GetSets (kind is float, vec4 for a Color or texture) and fields of the
--   factor block, and a material with all of its floats at their default skips the upload.
--   getter names a GLSL function that reads the param, getter_expression is what it returns of
--   the value v. block = "own" gives the feature a uniform block of its own, <name>_model, that
--   is only uploaded for a material the function active says is using the feature, and
--   block = "none" gives the params no block at all, for what Lua code reads through the material
-- category: the Material category the params are listed under, the name by default. a param can name
--   another one, from it on. block = false on a param keeps it out of the block, Lua reads it
-- getters: GLSL functions reading factor_model, next to the other material getters
-- common: GLSL helper functions the snippets use
-- encoders, decoders: GLSL for the gbuffer's encode and decode side, decoders use COORD for the
--   coordinate type
-- surface_members: members added to struct Surface, besides the generated ones
--
-- building a Surface, each besides what is generated from the fields:
--   surface_default: when there is no material, defaults. scope: s, with geometric_N set
--   material_init: from the material, after surface_default. scope: s, uv, with geometric_N set
--   weather: reacts to the rain and snow on the surface. scope: s, w (SurfaceWeather)
--   surface_decode: from the gbuffer in the lighting pass. scope: s with the core members
--     and geometric_N set, uv, size
--   surface_finish: last, once every feature has set its members. scope: s
--   gbuffer_write: stores the members. scope: s
--
-- lobes, spliced into get_direct_light and get_indirect_light:
--   direct_peak: refines lobe_alpha_min, the smoothest lobe's alpha, which scales how bright
--     a light has to be to show on screen. scope: s, lobe_alpha_min
--   direct_shadow: runs before the shadow lookup. scope: s, L, shadow_N (inout),
--     shadow_facing (inout)
--   direct_layer: layers over the base lobe, before it is added. scope: s, light, type, L, H,
--     LoH, glow_widening, radiance (inout), diffuse_weight (inout), specular (inout)
--   direct: after the base lobe is added, with what the layers left of the radiance. scope: as
--     direct_layer, and diffuse (inout)
--   indirect: scope: s, in_uv, sky_visibility, irradiance, ambient_occlusion,
--     ambient_diffuse (inout), ambient_specular (inout)
--   indirect_layer: the same, layered over what indirect and the base made
--
-- weather_input: before the weather is applied, what this surface asks of it. scope: s, w
--   (SurfaceWeather) with porosity, wet_scale and snow_scale set, core derives the porosity from
--   the roughness and metal
--
-- other passes:
--   reflection: see GetReflectionGLSL
--   thin: a GLSL bool expression of c, a gbuffer coordinate, true where the surface is thin
-- the getters of the params that name one, reading the block the param is in
function self.GetGetterGLSL()
	local out = {join("getters")}

	for _, feature in ipairs(list) do
		for _, param in ipairs(feature.params or {}) do
			if param.getter then
				local block = feature.block == "own" and feature.name .. "_model" or "factor_model"
				table.insert(
					out,
					string.format(
						"float %s() {\n\tfloat v = %s.%s;\n\treturn %s;\n}\n",
						param.getter,
						block,
						param.name,
						param.getter_expression or "v"
					)
				)
			end
		end
	end

	return table.concat(out, "\n")
end

function self.GetCommonGLSL()
	return join("common")
end

function self.GetEncodersGLSL()
	return join("encoders")
end

function self.GetDecodersGLSL()
	return join("decoders")
end

function self.GetDirectPeakGLSL()
	return join("direct_peak")
end

function self.GetDirectShadowGLSL()
	return join("direct_shadow")
end

function self.GetDirectLayerGLSL()
	return join("direct_layer")
end

function self.GetDirectGLSL()
	return join("direct")
end

function self.GetIndirectGLSL()
	return join("indirect")
end

-- statements for the ssr pass, which traces one ray per pixel off the surface's reflection. scope:
-- gbuffer_pos (ivec2), world_pos, view_depth, V, geometric_N, footprint (meters a pixel covers on
-- the surface), N (inout, what the ray reflects off), roughness (inout, perceptual). a feature
-- whose lobe is smoother than the surface under it traces off that
function self.GetReflectionGLSL()
	return join("reflection")
end

-- bool gbuffer_is_thin(COORD c), true for what is a thin card, for passes that treat those
-- differently
function self.GetThinExpressionGLSL()
	local out = {}

	for _, feature in ipairs(list) do
		if feature.thin then out[#out + 1] = "(" .. feature.thin .. ")" end
	end

	return #out > 0 and table.concat(out, " || ") or "false"
end

function self.GetIndirectLayerGLSL()
	return join("indirect_layer")
end

-- struct Surface and SurfaceWeather. any shader that builds a Surface includes this, and the
-- guard lets several of them
function self.GetSurfaceGLSL()
	return "\n" .. [[
		#ifndef GOLUWA_SURFACE_STRUCT
		#define GOLUWA_SURFACE_STRUCT
		// what rain and snow did to a surface, for the features to react to
		struct SurfaceWeather {
			// how much snow covers it
			float snow;
			// the rain's film over it, its ggx alpha, and how exposed to the rain it is
			float film;
			float film_alpha;
			float rain;
			// what the surface asks of the weather: how much water its pores soak up, and how much
			// of the wetness and the snow it takes. prepare_surface_weather sets them
			float porosity;
			float wet_scale;
			float snow_scale;
		};

		// everything the lobes shade a point with. a feature adds its members to it
		// instead of a parameter to every lighting function
		struct Surface {
			vec3 F0;
			float NdotV;
			float perceptual_roughness;
			vec3 world_pos;
			vec3 V;
			vec3 N;
			vec3 geometric_N;
			]] .. join("surface_members") .. [[
		};
		#endif
	]] .. "\n"
end

-- void default_surface_features(inout Surface s), for shaders that have no material
function self.GetDefaultFunctionGLSL()
	return build_function("void default_surface_features(inout Surface s)", "surface_default")
end

-- void init_surface_features(inout Surface s, vec2 uv), from the material
function self.GetInitFunctionGLSL()
	return "void init_surface_features(inout Surface s, vec2 uv) {\n" .. join("surface_default") .. "\n" .. join("material_init") .. "\n}\n"
end

-- void prepare_surface_weather(inout Surface s, out SurfaceWeather w)
function self.GetPrepareWeatherFunctionGLSL()
	return build_function("void prepare_surface_weather(in Surface s, out SurfaceWeather w)", "weather_input")
end

function self.GetWeatherFunctionGLSL()
	return build_function("void weather_surface_features(inout Surface s, SurfaceWeather w)", "weather")
end

function self.GetFinishFunctionGLSL()
	return build_function("void finish_surface_features(inout Surface s)", "surface_finish")
end

-- void write_surface_features(Surface s), in the passes that write the gbuffer
function self.GetWriteFunctionGLSL()
	return "void write_surface_features(Surface s) {\n" .. join("gbuffer_write") .. "\ngbuffer_flush_packed();\n}\n"
end

-- void decode_surface_features(inout Surface s, vec2 uv, ivec2 size), from the gbuffer
function self.GetDecodeFunctionGLSL()
	return build_function("void decode_surface_features(inout Surface s, vec2 uv, ivec2 size)", "surface_decode")
end

return self
end

local default = surface_features.New(surface_features.default_list)

for key, value in pairs(default) do
	surface_features[key] = value
end

return surface_features
