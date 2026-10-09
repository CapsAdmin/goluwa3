local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local STEP_HEIGHTS = {0.1, 0.2, 0.3, 0.34, 0.4, 0.5}
local STEP_COUNT = 6
local STEP_DEPTH = 0.6
local LANE_WIDTH = 8
local LANE_SPACING = 24
local BOX_Z = 0
local CONVEX_Z = 30

if _G.stairs_showcase then
	for _, ent in ipairs(_G.stairs_showcase.entities) do
		if ent:IsValid() then ent:Remove() end
	end
end

local showcase = {entities = {}, lanes = {}}
_G.stairs_showcase = showcase

local function track(ent)
	list.insert(showcase.entities, ent)
	return ent
end

local floor_material = shapes.Material{Color = Color(0.45, 0.47, 0.5, 1), Roughness = 0.9}
local step_material = shapes.Material{Color = Color(0.8, 0.55, 0.35, 1), Roughness = 0.7}
local convex_material = shapes.Material{Color = Color(0.35, 0.6, 0.8, 1), Roughness = 0.7}

for row, z0 in ipairs{BOX_Z, CONVEX_Z} do
	local convex = row == 2
	track(
		shapes.Box{
			Name = "stairs_floor",
			Position = Vec3(
				LANE_SPACING * (#STEP_HEIGHTS - 1) / 2,
				-0.5,
				z0 - STEP_COUNT * STEP_DEPTH / 2 - 2
			),
			Size = Vec3(LANE_SPACING * #STEP_HEIGHTS + 10, 1, STEP_COUNT * STEP_DEPTH + 12),
			Material = floor_material,
			RigidBody = {MotionType = "static", Friction = 0.8},
		}
	)

	for lane, height in ipairs(STEP_HEIGHTS) do
		local x = (lane - 1) * LANE_SPACING
		showcase.lanes[#showcase.lanes + 1] = {
			convex = convex,
			height = height,
			steps = STEP_COUNT,
			start = Vec3(x, 0, z0 + 1),
		}

		for i = 1, STEP_COUNT do
			local size = Vec3(LANE_WIDTH, height * i, STEP_DEPTH)
			local position = Vec3(x, size.y / 2, z0 - (i - 0.5) * STEP_DEPTH)

			if convex then
				local poly = Polygon3D.New()
				shapes.BuildCube(poly, 1)

				for _, vertex in ipairs(poly.Vertices) do
					vertex.pos.x = vertex.pos.x * size.x / 2
					vertex.pos.y = vertex.pos.y * size.y / 2
					vertex.pos.z = vertex.pos.z * size.z / 2
				end

				local hull = convex_hull.BuildFromTriangles(poly)
				track(
					shapes.Polygon{
						Name = "convex_step",
						Position = position,
						Material = convex_material,
						Polygon = poly,
						CollisionShape = ConvexShape.New(hull),
						RigidBody = {MotionType = "static", ConvexHull = hull, Friction = 0.8},
					}
				)
			else
				track(
					shapes.Box{
						Name = "box_step",
						Position = position,
						Size = size,
						Material = step_material,
						RigidBody = {MotionType = "static", Friction = 0.8},
					}
				)
			end
		end
	end
end

return showcase
