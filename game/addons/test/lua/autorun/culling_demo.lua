do
	return
end

local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local Material = require("render3d.material")
local ecs = require("ecs")
local Polygon3D = require("render3d.polygon_3d")
local transform = require("components.3d.transform").Component
local model_module = require("components.3d.model")
local model = model_module.Component
local system = require("system")

if HOTRELOAD then ecs.Clear3DWorld() end

local function spawn_sphere(pos, scale, color, use_occlusion)
	local ent = ecs.CreateEntity("sphere")
	local trans = ent:AddComponent(transform)
	trans:SetPosition(pos)
	trans:SetScale(scale or Vec3(1, 1, 1))
	local poly = Polygon3D.New()
	poly:CreateSphere(1, 16, 16)
	poly:AddSubMesh(#poly.Vertices)
	poly:Upload()
	poly.material = Material.New({
		ColorMultiplier = color or Color(1, 1, 1, 1),
	})
	local mdl = ent:AddComponent(model)
	mdl:AddPrimitive(poly)
	mdl:SetUseOcclusionCulling(use_occlusion or false)
	return ent
end

-- Set occlusion culling to 1 to see its effect
model_module.SetOcclusionCulling(true)
-- Create a large wall to block things (Occluder)
-- We don't enable occlusion culling on it so it's always drawn first in the query pass
spawn_sphere(Vec3(0, 0, -5), Vec3(10, 10, 0.1), Color(0.2, 0.2, 0.2, 1), false)

-- Create a grid of spheres behind the wall (Occludees)
-- These use occlusion culling and should be culled on the GPU
for x = -8, 8 do
	for y = -5, 5 do
		spawn_sphere(
			Vec3(x * 1.5, y * 1.5, -15),
			Vec3(0.5, 0.5, 0.5),
			Color(math.random(), math.random(), math.random(), 1),
			true
		)
	end
end

-- Create some spheres clearly visible on the sides
spawn_sphere(Vec3(-10, 0, -10), Vec3(1, 1, 1), Color(1, 0, 0, 1), true)
spawn_sphere(Vec3(10, 0, -10), Vec3(1, 1, 1), Color(0, 1, 0, 1), true)
print("Culling demo loaded. Use 'goluwa_occlusion_culling 1' to enable.")
local command = require("commands")
local event = require("event")
local render2d = require("render2d.render2d")
local fonts = require("render2d.fonts")
local stats_font = nil

event.AddListener("Draw2D", "culling_demo_hud", function()
	if not stats_font then stats_font = fonts.GetDefaultFont() end

	if not stats_font then return end

	local stats = model_module.GetOcclusionStats()
	local str = string.format(
		"Models: %d\nFrustum Culled: %d\nOcclusion Queries: %d\nConditionally Submitted: %d",
		stats.total,
		stats.frustum_culled,
		stats.with_occlusion,
		stats.submitted_with_conditional
	)
	render2d.SetColor(1, 1, 1, 1)
	stats_font:DrawText(str, 10, 10)
end)

command.Add("culling_stats", function()
	local stats = model_module.GetOcclusionStats()
	print(
		string.format(
			"Models: %d | Frustum Culled: %d | Occlusion Queries: %d | Conditionally Submitted: %d",
			stats.total,
			stats.frustum_culled,
			stats.with_occlusion,
			stats.submitted_with_conditional
		)
	)
end)
