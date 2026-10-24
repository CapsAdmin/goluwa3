local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local commands = import("goluwa/cli/commands.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local GridNav = import("goluwa/navigation/grid_nav.lua")
local AIController = import("lua/components/ai_controller.lua")
local nav_overlay = {}
nav_overlay.Enabled = false
nav_overlay.MaxCells = 60000
nav_overlay.RebuildInterval = 0.5
local LIFT = 0.04
local UP = Vec3(0, 1, 0)
local identity = Matrix44():Identity()
local material = debug_draw.GetMaterial{
	shape_type = "generic",
	color = Color(0.2, 1, 0.45, 0.28),
	emissive = Color(0.05, 0.4, 0.15, 1),
	ignore_z = false,
	translucent = true,
	double_sided = true,
}
local path_color = Color(1, 0.85, 0.2, 1)
local goal_color = Color(1, 0.3, 0.2, 0.9)
local polygons = {}
local counts = {}
local next_rebuild = 0

local function count_ground(nav)
	local n = 0

	for _ in pairs(nav.ground) do
		n = n + 1
	end

	return n
end

local function build(nav)
	local poly = Polygon3D.New()
	local half = nav.cell * 0.45
	local cells = 0

	for key, y in pairs(nav.ground) do
		if y then
			local column = math.floor(key / 512)
			local ix = math.floor(column / 16384) - 8192
			local iz = column % 16384 - 8192
			local x, z = ix * nav.cell, iz * nav.cell
			y = y + LIFT
			local a = {pos = Vec3(x - half, y, z - half), uv = Vec2(0, 0), normal = UP}
			local b = {pos = Vec3(x + half, y, z - half), uv = Vec2(1, 0), normal = UP}
			local c = {pos = Vec3(x + half, y, z + half), uv = Vec2(1, 1), normal = UP}
			local d = {pos = Vec3(x - half, y, z + half), uv = Vec2(0, 1), normal = UP}
			poly:AddVertex(a)
			poly:AddVertex(c)
			poly:AddVertex(b)
			poly:AddVertex(a)
			poly:AddVertex(d)
			poly:AddVertex(c)
			cells = cells + 1

			if cells >= nav_overlay.MaxCells then break end
		end
	end

	if cells == 0 then return nil end

	poly:Upload()
	return poly
end

function nav_overlay.SetEnabled(enabled)
	nav_overlay.Enabled = enabled

	if not enabled then
		polygons = {}
		counts = {}
	end
end

event.AddListener("Draw3DForwardOverlay", "nav_overlay", function()
	if not nav_overlay.Enabled then return end

	local now = system.GetElapsedTime()

	if now >= next_rebuild then
		next_rebuild = now + nav_overlay.RebuildInterval

		for key, nav in pairs(GridNav.GetAll()) do
			local count = count_ground(nav)

			if counts[key] ~= count then
				counts[key] = count
				polygons[key] = build(nav) or nil
			end
		end
	end

	render3d.SetWorldMatrix(identity)
	render3d.SetMaterial(material)
	render3d.UploadForwardOverlayConstants()

	for _, poly in pairs(polygons) do
		poly:Draw()
	end
end)

event.AddListener("Update", "nav_overlay_paths", function()
	if not nav_overlay.Enabled then return end

	for _, ai in ipairs(AIController.Instances or {}) do
		do
			local path = ai:GetPath()

			if path then
				local points = path.points

				for i = 1, #points - 1 do
					debug_draw.DrawLine{
						id = "nav_path_" .. tostring(ai) .. i,
						from = points[i] + UP * 0.1,
						to = points[i + 1] + UP * 0.1,
						color = path_color,
						width = 0.05,
						beam = true,
						time = 0.1,
					}
				end

				debug_draw.DrawSphere{
					id = "nav_goal_" .. tostring(ai),
					position = points[#points],
					radius = 0.2,
					color = goal_color,
					time = 0.1,
				}
			end
		end
	end
end)

commands.Add("nav_debug", function()
	nav_overlay.SetEnabled(not nav_overlay.Enabled)
end)

return nav_overlay
