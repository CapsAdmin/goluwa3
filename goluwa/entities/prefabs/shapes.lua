local Vec3 = import("goluwa/structs/vec3.lua")

local function model_input(name, type, default, key, extra)
	local input = {
		Name = name,
		Type = type,
		Default = default,
		Targets = {{Node = "root", Component = "model", Property = "ModelOptions", Key = key}},
	}

	for k, v in pairs(extra or {}) do
		input[k] = v
	end

	return input
end

local function shape(model_path, inputs)
	inputs[#inputs + 1] = {
		Name = "Material",
		Type = "table",
		Hidden = true,
		Targets = {{Node = "root", Component = "model", Property = "MaterialConfig"}},
	}
	return {
		inputs = inputs,
		entities = {
			{guid = "root", components = {model = {ModelPath = model_path}}},
		},
	}
end

return {
	box = shape(
		"models/box.lua",
		{
			model_input("Size", "vec3", Vec3(1, 1, 1), "size"),
			model_input("Subdivisions", "number", 1, "subdivisions", {Min = 1}),
		}
	),
	sphere = shape("models/sphere.lua", {model_input("Radius", "number", 0.5, "radius", {Min = 0})}),
	cone = shape(
		"models/cone.lua",
		{
			model_input("Radius", "number", 0.5, "radius", {Min = 0}),
			model_input("Height", "number", 1, "height", {Min = 0}),
		}
	),
	capsule = shape(
		"models/capsule.lua",
		{
			model_input("Radius", "number", 0.5, "radius", {Min = 0}),
			model_input("Height", "number", 1, "height", {Min = 0}),
		}
	),
}
