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

function nodes.Muzzle(distance)
	return {
		guid = "muzzle",
		parent = "model",
		properties = {Name = "muzzle"},
		components = {
			transform = {Position = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR * distance},
		},
	}
end

return nodes
