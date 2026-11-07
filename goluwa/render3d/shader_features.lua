local shader_features = {}
shader_features.list = {
	{name = "terrain", define = "TERRAIN_LAYERS"},
	{name = "overlays", define = "SURFACE_OVERLAYS"},
	{name = "conditions", define = "SURFACE_CONDITIONS"},
}
shader_features.ALL = 0

for i, feature in ipairs(shader_features.list) do
	feature.bit = 2 ^ (i - 1)
	shader_features[feature.name:upper()] = feature.bit
	shader_features.ALL = shader_features.ALL + feature.bit
end

shader_features.COUNT = shader_features.ALL + 1

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
