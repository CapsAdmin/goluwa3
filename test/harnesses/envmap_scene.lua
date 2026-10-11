local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")

for row = 0, 2 do
	for i = 0, 4 do
		local roughness = math.max(i / 4, 0.03)
		local color, metallic
		if row == 0 then color, metallic = Color(0.8, 0.8, 0.8, 1), 0
		elseif row == 1 then color, metallic = Color(1, 0.78, 0.34, 1), 1
		else color, metallic = Color(0.95, 0.95, 0.95, 1), 1 end
		shapes.Sphere{
			Position = Vec3((i - 2) * 2.2, (1 - row) * 2.2, 0),
			Radius = 1,
			Material = shapes.Material{Color = color, Roughness = roughness, Metallic = metallic},
			Collision = false,
			RigidBody = false,
		}
	end
end

