local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ALONG_AIM = Quat():SetAngles(Vec3(math.pi / 2, 0, 0))
local nodes = {}

function nodes.Box(name, size, position, material)
	return {
		guid = name,
		parent = "model",
		properties = {Name = name},
		components = {
			transform = {Position = position},
			model = {
				ModelPath = "models/box.lua",
				ModelOptions = {size = size},
				MaterialConfig = material,
			},
		},
	}
end

function nodes.Cylinder(name, radius, length, position, material, along_aim)
	return {
		guid = name,
		parent = "model",
		properties = {Name = name},
		components = {
			transform = {Position = position, Rotation = along_aim and ALONG_AIM or nil},
			model = {
				ModelPath = "models/cylinder.lua",
				ModelOptions = {radius = radius, height = length},
				MaterialConfig = material,
			},
		},
	}
end

function nodes.Handle(name, radius, length, position, material)
	return nodes.Cylinder(name, radius, length, position, material, false)
end

function nodes.Muzzle(radius, length, tip, material)
	return {
		{
			guid = "muzzle",
			parent = "model",
			properties = {Name = "muzzle"},
			components = {transform = {Position = tip}},
		},
		{
			guid = "muzzle_tube",
			parent = "muzzle",
			properties = {Name = "muzzle_tube"},
			components = {
				transform = {Position = Vec3(0, 0, length / 2), Rotation = ALONG_AIM},
				model = {
					ModelPath = "models/cylinder.lua",
					ModelOptions = {radius = radius, height = length},
					MaterialConfig = material,
				},
			},
		},
	}
end

return nodes
