local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

T.Test3D("the charred overlay darkens a visual and the jrpg conditions name overlays that exist", function(draw)
	import("lua/autorun/render_3d/surface_exposure.lua")
	local kinds = {}

	for _, name in ipairs(surface_overlays.GetKindNames()) do
		kinds[name] = true
	end

	local exposed = 0

	for _, kind in ipairs(surface_conditions.kinds) do
		for _, entry in ipairs(kind.exposure or {}) do
			exposed = exposed + 1
			T(kinds[entry.Overlay])["=="](true)
			T(surface_conditions.Query(Vec3(0, 0, 0), 1, entry.Channel))["=="](0)
		end
	end

	T(exposed)[">="](4)
	local sphere = shapes.Sphere{
		Position = Vec3(0, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 6, 0))
	cam:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
	cam:SetFOV(math.rad(40))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)
	local size = render3d.GetRenderSize()
	local get_time = surface_overlays.GetTime
	local now = 100

	function surface_overlays.GetTime()
		return now
	end

	local function albedo()
		for _ = 1, 4 do
			draw()
		end

		local r, g, b = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
		return r + g + b
	end

	local before = albedo()
	surface_overlays.Add(sphere.visual, "charred", {FadeIn = 0.01, Intensity = 1})
	now = now + 1
	T(albedo())["<"](before * 0.5)
	surface_overlays.Clear(sphere.visual)
	surface_overlays.GetTime = get_time
	sphere:Remove()
end)
