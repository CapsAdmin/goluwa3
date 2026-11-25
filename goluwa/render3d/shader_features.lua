local shader_features = {}
shader_features.list = {
	{name = "terrain", define = "TERRAIN_LAYERS"},
	{name = "overlays", define = "SURFACE_OVERLAYS"},
	{name = "conditions", define = "SURFACE_CONDITIONS"},
	{name = "refraction", define = "SURFACE_REFRACTION"},
}
shader_features.param_groups = {
	{
		name = "extra",
		features = {
			"detail",
			"micro_detail",
			"displacement",
			"subsurface",
			"subsurface_color",
			"clearcoat",
			"secondary_specular",
			"sheen",
			"specular_tint",
			"medium",
			"derived_roughness",
		},
	},
}
shader_features.PARAMS = 0
local group_of_feature = {}

for _, group in ipairs(shader_features.param_groups) do
	shader_features.list[#shader_features.list + 1] = {name = group.name, define = "SURFACE_PARAMS_" .. group.name:upper()}
	group.feature = shader_features.list[#shader_features.list]

	for _, name in ipairs(group.features) do
		assert(not group_of_feature[name], name .. " is in two param groups")
		group_of_feature[name] = group
	end
end

shader_features.ALL = 0

for i, feature in ipairs(shader_features.list) do
	feature.bit = 2 ^ (i - 1)
	shader_features[feature.name:upper()] = feature.bit
	shader_features.ALL = shader_features.ALL + feature.bit
end

for _, group in ipairs(shader_features.param_groups) do
	group.bit = group.feature.bit
	group.define = group.feature.define
	shader_features.PARAMS = shader_features.PARAMS + group.bit
end

shader_features.COUNT = shader_features.ALL + 1

function shader_features.GetParamGroup(feature_name)
	return group_of_feature[feature_name]
end

function shader_features.GetDefines(bits)
	local lines = {}

	for i, feature in ipairs(shader_features.list) do
		lines[i] = string.format("#define %s %d\n", feature.define, bit.band(bits, feature.bit) ~= 0 and 1 or 0)
	end

	return table.concat(lines)
end

function shader_features.GetName(bits)
	local names = {}

	for _, feature in ipairs(shader_features.list) do
		if bit.band(bits, feature.bit) ~= 0 then names[#names + 1] = feature.name end
	end

	return table.concat(names, ",")
end

function shader_features.GetDefaultGLSL(name)
	for _, feature in ipairs(shader_features.list) do
		if feature.name == name then
			return string.format("#ifndef %s\n#define %s 1\n#endif\n", feature.define, feature.define)
		end
	end

	error("unknown shader feature " .. tostring(name))
end

return shader_features
