-- a debug tree in the wind: a pole with 4 branches pointing out, each with 4 planes for leaves, 4 of them on a plane.
-- flat colored materials, the vertex colors follow the bending convention of the foliage trees (addons/foliage): the
-- pole is rigid, a branch loses FLEX of its stiffness a meter out, a plane flutters at its top edge and is held at
-- its bottom edge. hold q for the wind controls
-- luajit glw --3d lua "import('addons/examples/lua/examples/render3d/wind_debug.lua')"
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local MeshBuilder = import("lua/foliage/mesh_builder.lua")
local trees = import("lua/foliage/trees.lua")
local HEIGHT = 6
local POLE_RADIUS = 0.08
local BRANCH_HEIGHT = 4.5
local BRANCH_LENGTH = 2
local BRANCH_RADIUS = 0.04
local PLANE_SIZE = 0.4
local FLEX = 0.1
-- far past real wind, to exaggerate. the engine eases the sway towards a limit as the wind gets stronger, the
-- bending slider scales the Bending of the materials past it
local MAX_SPEED = 100
local MAX_BENDING = 10
local BRANCH_COLORS = {
	Color(0.9, 0.25, 0.2, 1),
	Color(0.25, 0.8, 0.3, 1),
	Color(0.25, 0.45, 0.95, 1),
	Color(0.95, 0.8, 0.2, 1),
}

if _G.wind_debug then _G.wind_debug.Remove() end

local scene = {}
_G.wind_debug = scene
scene.root = Entity.New{Name = "wind_debug", Parent = Entity.World}
scene.root:AddComponent("transform")

scene.materials = {}

local function material(color, double_sided)
	local out = Material.New{
		ColorMultiplier = color,
		MetallicMultiplier = 0,
		RoughnessMultiplier = 0.8,
		DoubleSided = double_sided,
		Bending = 1,
		DetailBending = "leaves",
		BendDetailPhase = 1,
	}
	scene.materials[#scene.materials + 1] = out
	return out
end

local function primitive(parent, polygon, mat)
	local ent = Entity.New{Name = polygon:GetName(), Parent = parent}
	ent:AddComponent("transform")
	ent:AddComponent("visual_primitive"):SetPolygon3D(polygon)
	ent.visual_primitive:SetMaterial(mat)
	return ent
end

-- the parts of the tree: the pole, then a branch and its planes for each direction, {polygon, material}
local parts = {}

do
	local mesh = MeshBuilder.New()
	mesh:Tube(
		{
			{0, 0, 0, POLE_RADIUS, 0, 0, 1},
			{0, HEIGHT * 0.5, 0, POLE_RADIUS, 0, 0, 1},
			{0, HEIGHT, 0, POLE_RADIUS * 0.5, 0, 0, 1},
		},
		{sides = 10, cap = true}
	)
	parts[1] = {mesh:Build{bend_height = HEIGHT, name = "wind_debug_pole"}, material(Color(0.85, 0.85, 0.85, 1))}
end

for i, color in ipairs(BRANCH_COLORS) do
	local angle = (i - 1) * math.pi * 0.5
	local dir = Vec3(math.cos(angle), 0, math.sin(angle))
	local side = Vec3(-dir.z, 0, dir.x)
	local phase = (i - 1) / 4
	local branch = MeshBuilder.New()
	local points = {}

	for k = 0, 4 do
		local t = k / 4
		local p = dir * (t * BRANCH_LENGTH)
		points[#points + 1] = {
			p.x,
			BRANCH_HEIGHT,
			p.z,
			BRANCH_RADIUS * (1 - t * 0.5),
			0,
			phase,
			trees.Stiffness(t * BRANCH_LENGTH, FLEX),
		}
	end

	branch:Tube(points, {sides = 8, cap = true})
	parts[#parts + 1] = {
		branch:Build{bend_height = HEIGHT, name = "wind_debug_branch_" .. i},
		material(color),
	}
	local planes = MeshBuilder.New()

	for k = 1, 4 do
		local reach = BRANCH_LENGTH * k / 4
		local stiffness = trees.Stiffness(reach, FLEX)
		local base = dir * reach + Vec3(0, BRANCH_HEIGHT, 0)
		local first = planes:GetVertexCount()

		-- the bottom edge is held by the branch, the top flutters
		for corner = 0, 3 do
			local sx = (corner == 1 or corner == 2) and 1 or -1
			local top = corner >= 2
			local p = base + dir * (sx * PLANE_SIZE * 0.5) + Vec3(0, top and PLANE_SIZE or 0, 0)
			planes:SetColor(top and 1 or 0, phase, stiffness)
			planes:Vertex(p.x, p.y, p.z, side.x, side.y, side.z, sx > 0 and 1 or 0, top and 1 or 0)
		end

		planes:Quad(first, first + 1, first + 2, first + 3)
	end

	parts[#parts + 1] = {
		planes:Build{bend_height = HEIGHT, name = "wind_debug_planes_" .. i},
		material(color * 0.5 + Color(0.5, 0.5, 0.5, 0.5), true),
	}
end

do
	local polygon = Polygon3D.New()
	shapes.BuildPlane(polygon, Vec3(0, 0, 0), Vec3(0, 1, 0), 60, 60, 10, 12, 12, Vec3(0, 0, -1))
	polygon:BuildBoundingBox()
	polygon:Upload()
	polygon:SetName("wind_debug_ground")
	local ground = Entity.New{Name = "wind_debug_ground", Parent = scene.root}
	ground:AddComponent("transform")
	ground:AddComponent("visual")
	primitive(ground, polygon, Material.New{ColorMultiplier = Color(0.4, 0.4, 0.42, 1), MetallicMultiplier = 0, RoughnessMultiplier = 0.9})
	ground.visual:BuildAABB()
end

for i, position in ipairs{Vec3(-6, 0, -6), Vec3(6, 0, -6), Vec3(-6, 0, 6), Vec3(6, 0, 6)} do
	local tree = Entity.New{Name = "wind_debug_tree_" .. i, Parent = scene.root}
	tree:AddComponent("transform"):SetPosition(position)
	tree:AddComponent("visual")

	for _, part in ipairs(parts) do
		primitive(tree, part[1], part[2])
	end

	tree.visual:BuildAABB()
end

local spawn = Entity.New{Name = "wind_debug_spawn", Parent = scene.root}
spawn:AddComponent("transform"):SetPosition(Vec3(0, 3, 18))
spawn:AddComponent("spawn_point", {Group = "start"})
-- the wind as a direction (degrees, 0 blows towards +x, 90 towards +z) and a speed in m/s
scene.direction = 0
scene.speed = 6
scene.bending = 1

local function apply_wind()
	local angle = math.rad(scene.direction)
	weather.SetWind(Vec3(math.cos(angle), 0, math.sin(angle)) * scene.speed)
end

apply_wind()

-- an arrow over the middle of the trees, the way the wind blows and as long as it is fast
event.AddListener("Update", "wind_debug", function()
	local angle = math.rad(scene.direction)
	local dir = Vec3(math.cos(angle), 0, math.sin(angle))
	local from = Vec3(0, HEIGHT + 1, 0) - dir * (scene.speed * 0.25)
	local to = Vec3(0, HEIGHT + 1, 0) + dir * (scene.speed * 0.25)
	local side = Vec3(-dir.z, 0, dir.x) * 0.4
	local color = Color(0.3, 0.8, 1, 1)
	debug_draw.DrawLine{id = "wind_debug_arrow", from = from, to = to, color = color, line_width = 3, time = 0.1}
	debug_draw.DrawLine{id = "wind_debug_arrow_l", from = to, to = to - dir * 0.6 + side, color = color, line_width = 3, time = 0.1}
	debug_draw.DrawLine{id = "wind_debug_arrow_r", from = to, to = to - dir * 0.6 - side, color = color, line_width = 3, time = 0.1}
end)

-- the controls, shown while q is held
local panel = NULL
scene.controls_shown = false
local readout

local function update_readout()
	readout.text:SetText(("direction %3d deg   speed %.1f m/s   bending %.2f"):format(scene.direction, scene.speed, scene.bending))
end

local function show()
	if not panel:IsValid() then
		panel = Panel.World:Ensure(
			Window{
				Key = "WindDebugWindow",
				Title = "WIND",
				RequestMouse = true,
				Closable = false,
				Minimizable = false,
				Maximizable = false,
				MinSize = Vec2(360, 0),
			}{
				Column{layout = {ChildGap = "S", Padding = "M", GrowWidth = 1, AlignmentX = "stretch"}}{
					Text{Text = "direction", IgnoreMouseInput = true},
					Slider{
						Min = 0,
						Max = 360,
						Value = scene.direction,
						OnChange = function(value)
							scene.direction = math.floor(value + 0.5)
							apply_wind()
							update_readout()
						end,
						layout = {GrowWidth = 1, MinSize = Vec2(320, 16)},
					},
					Text{Text = "speed", IgnoreMouseInput = true},
					Slider{
						Min = 0,
						Max = MAX_SPEED,
						Value = scene.speed,
						OnChange = function(value)
							scene.speed = value
							apply_wind()
							update_readout()
						end,
						layout = {GrowWidth = 1, MinSize = Vec2(320, 16)},
					},
					Text{Text = "bending", IgnoreMouseInput = true},
					Slider{
						Min = 0,
						Max = MAX_BENDING,
						Value = scene.bending,
						OnChange = function(value)
							scene.bending = value

							for _, mat in ipairs(scene.materials) do
								mat:SetBending(value)
							end

							update_readout()
						end,
						layout = {GrowWidth = 1, MinSize = Vec2(320, 16)},
					},
					Text{
						Ref = function(self)
							readout = self
						end,
						Text = "",
						Color = "text_disabled",
						IgnoreMouseInput = true,
					},
				},
			}
		)
		update_readout()
	end

	panel.transform:SetPosition(Vec2(16, 16))
	panel.visual:SetVisible(true)
end

event.AddListener("Update", "wind_debug_controls", function()
	local down = input.IsKeyDown("q")

	if down == scene.controls_shown then return end

	scene.controls_shown = down

	if down then
		show()
	elseif panel:IsValid() then
		-- the window is gone when the ui was rebuilt while q was held
		panel.visual:SetVisible(false)
	end
end)

function scene.Remove()
	event.RemoveListener("Update", "wind_debug")
	event.RemoveListener("Update", "wind_debug_controls")

	if panel:IsValid() then panel:Remove() end

	scene.root:Remove()
	_G.wind_debug = nil
end

return scene
