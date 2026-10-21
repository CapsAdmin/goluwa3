local glsl_common = import("goluwa/render3d/glsl_common.lua")
local surface_features = {}
surface_features.default_list = {
	import("goluwa/render3d/features/core.lua"),
	import("goluwa/render3d/features/specular.lua"),
	import("goluwa/render3d/features/transmission.lua"),
	import("goluwa/render3d/features/clearcoat.lua"),
	import("goluwa/render3d/features/secondary_specular.lua"),
	import("goluwa/render3d/features/sheen.lua"),
	import("goluwa/render3d/features/specular_tint.lua"),
	import("goluwa/render3d/features/derived_roughness.lua"),
	import("goluwa/render3d/features/micro_detail.lua"),
	import("goluwa/render3d/features/displacement.lua"),
	import("goluwa/render3d/features/refraction.lua"),
	import("goluwa/render3d/features/weather_response.lua"),
	import("goluwa/render3d/features/terrain.lua"),
	import("goluwa/render3d/features/detail.lua"),
	import("goluwa/render3d/features/vegetation.lua"),
	import("goluwa/render3d/features/scatter.lua"),
}

function surface_features.New(source_list)
	local self = {}
	local list = {}

	for i, source in ipairs(source_list) do
		list[i] = table.copy(source)
	end

	self.list = list

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
		return glsl_common.GetLuminanceGLSL() .. join("common")
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

	function self.GetReflectionGLSL()
		return join("reflection")
	end

	function self.GetThinExpressionGLSL()
		local out = {}

		for _, feature in ipairs(list) do
			if feature.thin then out[#out + 1] = "(" .. feature.thin .. ")" end
		end

		return #out > 0 and table.concat(out, " || ") or "false"
	end

	function self.GetLitFromBehindExpressionGLSL()
		local out = {}

		for _, feature in ipairs(list) do
			if feature.lit_from_behind then
				out[#out + 1] = "(" .. feature.lit_from_behind .. ")"
			end
		end

		return #out > 0 and table.concat(out, " || ") or "false"
	end

	function self.GetIndirectLayerGLSL()
		return join("indirect_layer")
	end

	function self.GetSurfaceGLSL()
		return "\n" .. [[
		#ifndef GOLUWA_SURFACE_STRUCT
		#define GOLUWA_SURFACE_STRUCT
		struct SurfaceWeather {
			float snow;
			float film;
			float film_alpha;
			float rain;
			float porosity;
			float wet_scale;
			float snow_scale;
		};

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

	function self.GetDefaultFunctionGLSL()
		return build_function("void default_surface_features(inout Surface s)", "surface_default")
	end

	function self.GetInitFunctionGLSL()
		return "void init_surface_features(inout Surface s, vec2 uv) {\n" .. join("surface_default") .. "\n" .. join("material_init") .. "\n}\n"
	end

	function self.GetPrepareWeatherFunctionGLSL()
		return build_function(
			"void prepare_surface_weather(in Surface s, out SurfaceWeather w)",
			"weather_input"
		)
	end

	function self.GetWeatherFunctionGLSL()
		return build_function("void weather_surface_features(inout Surface s, SurfaceWeather w)", "weather")
	end

	function self.GetFinishFunctionGLSL()
		return build_function("void finish_surface_features(inout Surface s)", "surface_finish")
	end

	function self.GetWriteFunctionGLSL()
		return "void write_surface_features(Surface s) {\n" .. join("gbuffer_write") .. "\ngbuffer_flush_packed();\n}\n"
	end

	function self.GetDecodeFunctionGLSL()
		return build_function(
			"void decode_surface_features(inout Surface s, vec2 uv, ivec2 size)",
			"surface_decode"
		)
	end

	return self
end

local default = surface_features.New(surface_features.default_list)

for key, value in pairs(default) do
	surface_features[key] = value
end

return surface_features
