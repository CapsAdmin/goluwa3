local T = import("test/environment.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")

local function has(text, part)
	return text:find(part, 1, true) ~= nil
end

local function position(text, part)
	return assert(text:find(part, 1, true), part)
end

T.Test("surface features splice a stage in feature order and keep the stages apart", function()
	local registry = surface_features.New{
		{name = "a", direct_layer = "LAYER_A;", direct = "DIRECT_A;", indirect = "INDIRECT_A;", indirect_layer = "COAT_A;"},
		{name = "b", direct_layer = "LAYER_B;", direct = "DIRECT_B;", indirect = "INDIRECT_B;", indirect_layer = "COAT_B;"},
	}
	local layer = registry.GetDirectLayerGLSL()
	T(position(layer, "LAYER_A;") < position(layer, "LAYER_B;"))["=="](true)
	T(has(layer, "DIRECT_A;"))["=="](false)
	local direct = registry.GetDirectGLSL()
	T(position(direct, "DIRECT_A;") < position(direct, "DIRECT_B;"))["=="](true)
	T(has(direct, "LAYER_A;"))["=="](false)
	T(has(registry.GetIndirectGLSL(), "COAT_A;"))["=="](false)
	T(has(registry.GetIndirectLayerGLSL(), "INDIRECT_A;"))["=="](false)
	T(position(registry.GetIndirectLayerGLSL(), "COAT_A;") < position(registry.GetIndirectLayerGLSL(), "COAT_B;"))["=="](true)
end)

T.Test("surface features generate what a field needs", function()
	local source = {
		name = "fake",
		fields = {
			{name = "gloss", kind = "unorm4", default = "0.25", material = "get_gloss()"},
			{name = "gloss_width", member = "width", kind = "unorm8", default = "1.0", encode = "sqrt(v)", decode = "v * v"},
			{name = "gloss_skip", kind = "unorm8", default = "0.0", member = false},
			{name = "gloss_normal", kind = "octa", default = "0.0"},
		},
		surface_default = "MANUAL_DEFAULT;",
		material_init = "MANUAL_INIT;",
		gbuffer_write = "MANUAL_WRITE;",
	}
	local registry = surface_features.New{source}
	local struct = registry.GetSurfaceGLSL()
	T(has(struct, "float gloss;"))["=="](true)
	T(has(struct, "float width;"))["=="](true)
	T(has(struct, "vec3 gloss_normal;"))["=="](true)
	T(has(struct, "gloss_skip"))["=="](false)
	local init = registry.GetInitFunctionGLSL()
	T(has(init, "s.gloss = 0.25;"))["=="](true)
	T(has(init, "s.width = 1.0;"))["=="](true)
	T(position(init, "s.gloss = 0.25;") < position(init, "s.gloss = get_gloss();"))["=="](true)
	T(position(init, "s.gloss = get_gloss();") < position(init, "MANUAL_INIT;"))["=="](true)
	T(position(init, "MANUAL_DEFAULT;") < position(init, "s.gloss = get_gloss();"))["=="](true)
	local decode = registry.GetDecodeFunctionGLSL()
	T(has(decode, "s.gloss = gbuffer_gloss(uv);"))["=="](true)
	T(has(decode, "s.width = gbuffer_gloss_width(uv);"))["=="](true)
	T(has(decode, "gloss_skip"))["=="](false)
	local write = registry.GetWriteFunctionGLSL()
	T(has(write, "set_gloss(s.gloss);"))["=="](true)
	T(has(write, "set_gloss_width(gbuffer_encode_gloss_width(s.width));"))["=="](true)
	T(position(write, "set_gloss(s.gloss);") < position(write, "MANUAL_WRITE;"))["=="](true)
	T(position(write, "MANUAL_WRITE;") < position(write, "gbuffer_flush_packed();\n}"))["=="](true)
	T(source.surface_members)["=="](nil)
end)

T.Test("surface features generate the getter of a param", function()
	local registry = surface_features.New{
		{
			name = "fake",
			params = {
				{name = "Gloss", default = 0.0, getter = "get_gloss"},
				{name = "GlossSize", default = 0.5, getter = "get_gloss_size", getter_expression = "clamp(v, 0.1, 1.0)"},
				{name = "Unread", default = 0.0},
			},
		},
		{
			name = "owned",
			block = "own",
			params = {{name = "Owned", default = 0.0, getter = "get_owned"}},
		},
	}
	local getters = registry.GetGetterGLSL()
	T(has(getters, "float get_gloss() {\n\tfloat v = factor_model.Gloss;\n\treturn v;"))["=="](true)
	T(has(getters, "float v = factor_model.GlossSize;\n\treturn clamp(v, 0.1, 1.0);"))["=="](true)
	T(has(getters, "Unread"))["=="](false)
	T(has(getters, "float v = owned_model.Owned;"))["=="](true)
end)

T.Test("surface features join the thin expressions of the features", function()
	T(surface_features.New{{name = "a"}}.GetThinExpressionGLSL())["=="]("false")
	T(surface_features.New{{name = "a", thin = "x(c)"}, {name = "b"}, {name = "c", thin = "y(c)"}}.GetThinExpressionGLSL())["=="]("(x(c)) || (y(c))")
end)

T.Test("gbuffer layout packs every kind into its own slot", function()
	local fields = {}

	for i = 1, 5 do
		fields[#fields + 1] = {name = "eight_" .. i, kind = "unorm8"}
	end

	for i = 1, 3 do
		fields[#fields + 1] = {name = "four_" .. i, kind = "unorm4"}
	end

	for i = 1, 2 do
		fields[#fields + 1] = {name = "sixteen_" .. i, kind = "unorm16"}
		fields[#fields + 1] = {name = "octa_" .. i, kind = "octa"}
	end

	local targets = gbuffer_layout.Pack(fields)
	local slots = {}

	for _, field in ipairs(fields) do
		for i = 1, #field.swizzle do
			local slot = field.target.texture .. "." .. field.swizzle:sub(i, i) .. "." .. tostring(field.nibble or "")
			T(slots[slot])["=="](nil)
			slots[slot] = field.name
		end
	end

	-- two of the three unorm4 fields share a channel
	T(fields[6].target)["=="](fields[7].target)
	T(fields[6].swizzle)["=="](fields[7].swizzle)
	T(fields[6].nibble)["=="](0)
	T(fields[7].nibble)["=="](1)
	T(fields[8].swizzle ~= fields[6].swizzle or fields[8].target ~= fields[6].target)["=="](true)

	for _, target in ipairs(targets) do
		T(#target.channels > 0)["=="](true)

		if target.class == "8" then
			T(target.format)["=="]("r8g8b8a8_unorm")
		else
			T(target.format:find("r16g16", 1, true) ~= nil)["=="](true)
		end
	end

	-- 5 unorm8 and 2 channels of unorm4 fit in 2 targets of 4 channels, 2 unorm16 and 2 octa need 6 channels
	local count = {["8"] = 0, ["16"] = 0}

	for _, target in ipairs(targets) do
		count[target.class] = count[target.class] + 1
	end

	T(count["8"])["=="](2)
	T(count["16"])["=="](2)
end)
