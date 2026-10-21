local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local steam = import("goluwa/steam/steam.lua")
local MeshBuilder = import("lua/foliage/mesh_builder.lua")
local Random = import("lua/foliage/random.lua")
local trees = import("lua/foliage/trees.lua")
local grass = import("lua/foliage/grass.lua")
local FLEX = 0.1
local MAX_SPEED = 100
local SCATTER_CENTER = Vec3(0, 0, -34)
local SCATTER_SIZE = 32
local BRANCH_COLORS = {
	Color(0.9, 0.25, 0.2, 1),
	Color(0.25, 0.8, 0.3, 1),
	Color(0.25, 0.45, 0.95, 1),
	Color(0.95, 0.8, 0.2, 1),
}
local PARAMS = {
	"Bending",
	"BendDetailFrequency",
	"BendDetailLeafAmplitude",
	"BendDetailBranchAmplitude",
	"BendDetailPhase",
}

if _G.wind_debug then _G.wind_debug.Remove() end

local scene = {}
_G.wind_debug = scene
scene.root = Entity.New{Name = "wind_debug", Parent = Entity.World}
scene.root:AddComponent("transform")
scene.materials = {}
scene.tracked = {}
scene.labels = {}

local function track(mat)
	if scene.tracked[mat] then return end

	local base = {}

	for _, param in ipairs(PARAMS) do
		base[param] = mat["Get" .. param](mat)
	end

	scene.tracked[mat] = true
	scene.materials[#scene.materials + 1] = {material = mat, base = base}
end

local function material(config)
	config.MetallicMultiplier = 0
	config.RoughnessMultiplier = 0.8
	local out = Material.New(config)
	track(out)
	return out
end

local function tree_material(color, double_sided)
	return material{
		ColorMultiplier = color,
		DoubleSided = double_sided,
		Bending = 1,
		DetailBending = "leaves",
		BendDetailPhase = 1,
		BendDetailFrequency = 1,
	}
end

local grass_material = material{
	ColorMultiplier = Color(0.45, 0.75, 0.3, 1),
	DoubleSided = true,
	Bending = 3,
	DetailBending = "grass",
	BendDetailBranchAmplitude = 0.03,
	BendDetailLeafAmplitude = 0.05,
	BendDetailPhase = 1,
	BendDetailFrequency = 3,
}
local branch_materials, plane_materials = {}, {}
local pole_material = tree_material(Color(0.85, 0.85, 0.85, 1))

for i, color in ipairs(BRANCH_COLORS) do
	branch_materials[i] = tree_material(color)
	plane_materials[i] = tree_material(color * 0.5 + Color(0.5, 0.5, 0.5, 0.5), true)
end

local function build_tree(height)
	local parts = {}
	local branch_height, branch_length, plane_size = height * 0.75, height / 3, height / 15
	local mesh = MeshBuilder.New()
	mesh:Tube(
		{
			{0, 0, 0, height / 75, 0, 0, 1},
			{0, height * 0.5, 0, height / 75, 0, 0, 1},
			{0, height, 0, height / 150, 0, 0, 1},
		},
		{sides = 10, cap = true}
	)
	parts[1] = {
		mesh = mesh:Build{bend_height = height, name = "wind_debug_pole"},
		material = pole_material,
	}

	for i = 1, #BRANCH_COLORS do
		local angle = (i - 1) * math.pi * 0.5
		local dir = Vec3(math.cos(angle), 0, math.sin(angle))
		local side = Vec3(-dir.z, 0, dir.x)
		local phase = (i - 1) / 4
		local branch = MeshBuilder.New()
		local points = {}

		for k = 0, 4 do
			local t = k / 4
			local p = dir * (t * branch_length)
			points[#points + 1] = {
				p.x,
				branch_height,
				p.z,
				height / 150 * (
					1 - t * 0.5
				),
				0,
				phase,
				trees.Stiffness(t * branch_length, FLEX),
			}
		end

		branch:Tube(points, {sides = 8, cap = true})
		parts[#parts + 1] = {
			mesh = branch:Build{bend_height = height, name = "wind_debug_branch_" .. i},
			material = branch_materials[i],
		}
		local planes = MeshBuilder.New()

		for k = 1, 4 do
			local reach = branch_length * k / 4
			local stiffness = trees.Stiffness(reach, FLEX)
			local base = dir * reach + Vec3(0, branch_height, 0)
			local first = planes:GetVertexCount()

			for corner = 0, 3 do
				local sx = (corner == 1 or corner == 2) and 1 or -1
				local top = corner >= 2
				local p = base + dir * (sx * plane_size * 0.5) + Vec3(0, top and plane_size or 0, 0)
				planes:SetColor(top and 1 or 0, phase, stiffness)
				planes:Vertex(p.x, p.y, p.z, side.x, side.y, side.z, sx > 0 and 1 or 0, top and 1 or 0)
			end

			planes:Quad(first, first + 1, first + 2, first + 3)
		end

		parts[#parts + 1] = {
			mesh = planes:Build{bend_height = height, name = "wind_debug_planes_" .. i},
			material = plane_materials[i],
		}
	end

	return parts
end

local function build_grass(size, count, seed)
	local rng = Random.New(seed)
	local mesh = MeshBuilder.New()

	for _ = 1, count do
		local root = Vec3((rng:Next() - 0.5) * size, 0, (rng:Next() - 0.5) * size)
		local angle = rng:Next() * math.pi * 2
		grass.AddBlade(
			mesh,
			root,
			Vec3(math.cos(angle), 0, math.sin(angle)),
			rng:Range(0.35, 0.6),
			0.03,
			rng:Range(0.1, 0.4),
			rng:Range(0, 0.15),
			rng:Range(-1, 1),
			4,
			0,
			1,
			rng:Next()
		)
	end

	return {
		{
			mesh = mesh:Build{bend_height = 0.6, name = "wind_debug_grass"},
			material = grass_material,
		},
	}
end

local function spawn(name, parts, position, yaw, scale, label)
	local ent = Entity.New{Name = name, Parent = scene.root}
	local transform = ent:AddComponent("transform")
	transform:SetPosition(position)
	transform:SetRotation(Quat():SetAngles(Deg3(0, yaw, 0)))
	transform:SetScale(Vec3(scale, scale, scale))
	ent:AddComponent("visual")

	for _, part in ipairs(parts) do
		local child = Entity.New{Name = part.mesh:GetName(), Parent = ent}
		child:AddComponent("transform")
		child:AddComponent("visual_primitive"):SetPolygon3D(part.mesh)
		child.visual_primitive:SetMaterial(part.material)
	end

	ent.visual:BuildAABB()
	scene.labels[#scene.labels + 1] = {position = position, text = label}
	return ent
end

do
	local polygon = Polygon3D.New()
	shapes.BuildPlane(polygon, Vec3(0, 0, 0), Vec3(0, 1, 0), 120, 120, 10, 12, 12, Vec3(0, 0, -1))
	polygon:BuildBoundingBox()
	polygon:Upload()
	polygon:SetName("wind_debug_ground")
	spawn(
		"wind_debug_ground",
		{
			{
				mesh = polygon,
				material = Material.New{
					ColorMultiplier = Color(0.4, 0.4, 0.42, 1),
					MetallicMultiplier = 0,
					RoughnessMultiplier = 0.9,
				},
			},
		},
		Vec3(0, 0, 0),
		0,
		1,
		nil
	)
end

local tree_6 = build_tree(6)
spawn("wind_debug_tree", tree_6, Vec3(-6, 0, -6), 0, 1, "6 m")
spawn("wind_debug_tree_turned", tree_6, Vec3(6, 0, -6), 45, 1, "6 m, turned 45")
spawn(
	"wind_debug_tree_scaled",
	tree_6,
	Vec3(-6, 0, 6),
	120,
	1.5,
	"6 m x1.5, turned 120"
)
spawn("wind_debug_tree_small", tree_6, Vec3(6, 0, 6), -30, 0.6, "6 m x0.6, turned -30")
spawn("wind_debug_tree_short", build_tree(3), Vec3(-15, 0, 0), 0, 1, "3 m")
spawn("wind_debug_tree_tall", build_tree(12), Vec3(15, 0, 0), 0, 1, "12 m")
scene.pending = {}

do
	local info = list.find(steam.GetGames(), function(game)
		return game.appid == 17300
	end)

	if info then
		local root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"

		for i, model in ipairs{
			{"Trees/Palm_Tree/Palm_Tree_large_a.cgf", Vec3(-30, 0, -8)},
			{
				"Trees/Jungle_Tree_Large/Jungle_Tree_Large_small_bright_green.cgf",
				Vec3(-30, 0, 10),
			},
			{"Trees/Twisted_Tree/twisted_tree_a.cgf", Vec3(30, 0, -8)},
			{"Bushes/palm_bush/palmbush_med_a.cgf", Vec3(30, 0, 10)},
		} do
			local ent = Entity.New{Name = "wind_debug_crysis_" .. i, Parent = scene.root}
			ent:AddComponent("transform"):SetPosition(model[2])
			ent:AddComponent("visual"):SetModelPath(root .. model[1])
			scene.pending[#scene.pending + 1] = ent.visual
			scene.labels[#scene.labels + 1] = {position = model[2], text = model[1]:match("([^/]+)%.cgf$")}
		end
	end
end

local grass_patch = build_grass(1.5, 120, 1)
spawn("wind_debug_grass", grass_patch, Vec3(-3, 0, 14), 0, 1, "grass")
spawn("wind_debug_grass_turned", grass_patch, Vec3(0, 0, 14), 60, 1, "grass, turned 60")
spawn("wind_debug_grass_scaled", grass_patch, Vec3(3, 0, 14), 0, 2, "grass x2")
scene.scatter_set = ScatterSet.New{
	Name = "wind_debug",
	Prototypes = {
		{
			model = function()
				return build_grass(0.6, 24, 2)
			end,
			density = 3,
			max_distance = 80,
			full_density_distance = 30,
			conform = true,
			shadow = true,
			yaw = 360,
			align = 1,
			scale = {0.8, 1.3},
		},
		{
			model = function()
				return build_tree(6)
			end,
			density = 0.03,
			max_distance = 150,
			full_density_distance = 150,
			shadow = true,
			yaw = 360,
			tilt = 8,
			align = 0.3,
			scale = {0.4, 0.7},
		},
	},
}

do
	local mesh = MeshBuilder.New()
	local cells = 64
	local half = SCATTER_SIZE * 0.5

	local function height(x, z)
		local edge = math.min(1, (half - math.max(math.abs(x), math.abs(z))) / 4)
		return (
				1.5 + math.sin(x * 0.45) * 0.9 + math.sin(z * 0.6 + x * 0.2) * 0.7
			) * math.max(edge, 0)
	end

	for row = 0, cells do
		for column = 0, cells do
			local x, z = column / cells * SCATTER_SIZE - half, row / cells * SCATTER_SIZE - half
			local e = 0.05
			local nx, nz = height(x - e, z) - height(x + e, z), height(x, z - e) - height(x, z + e)
			mesh:Vertex(x, height(x, z), z, nx, 2 * e, nz, column / 8, row / 8)
		end
	end

	for row = 0, cells - 1 do
		for column = 0, cells - 1 do
			local a = row * (cells + 1) + column
			mesh:Quad(a, a + cells + 1, a + cells + 2, a + 1)
		end
	end

	spawn(
		"wind_debug_scatter_ground",
		{
			{
				mesh = mesh:Build{name = "wind_debug_scatter_ground"},
				material = Material.New{
					ColorMultiplier = Color(0.35, 0.33, 0.3, 1),
					MetallicMultiplier = 0,
					RoughnessMultiplier = 0.9,
					ScatterSet = scene.scatter_set,
				},
			},
		},
		SCATTER_CENTER,
		0,
		1,
		"scatter: grass conform, small trees"
	)
end

local spawn_point = Entity.New{Name = "wind_debug_spawn", Parent = scene.root}
spawn_point:AddComponent("transform"):SetPosition(Vec3(0, 3, 26))
spawn_point:AddComponent("spawn_point", {Group = "start"})
scene.direction = 0
scene.speed = 4
scene.multipliers = {}

for _, param in ipairs(PARAMS) do
	scene.multipliers[param] = 1
end

scene.time_scale = 1

local function apply_wind()
	local angle = math.rad(scene.direction)
	weather.SetWind(Vec3(math.cos(angle), 0, math.sin(angle)) * scene.speed)
	weather.SetWindTimeScale(scene.time_scale)

	for _, entry in ipairs(scene.materials) do
		for _, param in ipairs(PARAMS) do
			entry.material["Set" .. param](entry.material, entry.base[param] * scene.multipliers[param])
		end
	end
end

apply_wind()

event.AddListener("Update", "wind_debug", function()
	for i = #scene.pending, 1, -1 do
		local visual = scene.pending[i]
		local entries = visual:GetRenderEntries()

		if not visual:IsLoading() and entries[1] then
			for _, entry in ipairs(entries) do
				track(visual:GetResolvedMaterial(entry))
			end

			table.remove(scene.pending, i)
			apply_wind()
		end
	end

	local angle = math.rad(scene.direction)
	local dir = Vec3(math.cos(angle), 0, math.sin(angle))
	local from = Vec3(0, 7, 0) - dir * math.min(scene.speed * 0.25, 10)
	local to = Vec3(0, 7, 0) + dir * math.min(scene.speed * 0.25, 10)
	local side = Vec3(-dir.z, 0, dir.x) * 0.4
	local color = Color(0.3, 0.8, 1, 1)
	debug_draw.DrawLine{
		id = "wind_debug_arrow",
		from = from,
		to = to,
		color = color,
		line_width = 3,
		time = 0.1,
	}
	debug_draw.DrawLine{
		id = "wind_debug_arrow_l",
		from = to,
		to = to - dir * 0.6 + side,
		color = color,
		line_width = 3,
		time = 0.1,
	}
	debug_draw.DrawLine{
		id = "wind_debug_arrow_r",
		from = to,
		to = to - dir * 0.6 - side,
		color = color,
		line_width = 3,
		time = 0.1,
	}

	for i, label in ipairs(scene.labels) do
		if label.text then
			debug_draw.DrawText{
				id = "wind_debug_label_" .. i,
				position = label.position + Vec3(0, 0.4, 0),
				text = label.text,
				time = 0.1,
				background_alpha = 0.45,
			}
		end
	end
end)

local panel = NULL
scene.controls_shown = false
local readout
local BEAUFORT = {
	{0.5, "0 calm"},
	{1.5, "1 light air"},
	{3.3, "2 light breeze, leaves rustle"},
	{5.4, "3 gentle breeze, leaves and twigs in constant motion"},
	{7.9, "4 moderate breeze, small branches move"},
	{10.7, "5 fresh breeze, small trees sway"},
	{13.8, "6 strong breeze, large branches move"},
	{17.1, "7 near gale, whole trees move"},
	{20.7, "8 gale, twigs break off"},
	{24.4, "9 strong gale, branches break"},
	{28.4, "10 storm, trees uprooted"},
	{32.6, "11 violent storm"},
	{math.huge, "12 hurricane"},
}

local function update_readout()
	local m = scene.multipliers
	local force

	for _, entry in ipairs(BEAUFORT) do
		if scene.speed <= entry[1] then
			force = entry[2]

			break
		end
	end

	readout.text:SetText(
		(
			"direction %3d deg   speed %.1f m/s   time x%.2f\n" .. "beaufort %s\n" .. "bending x%.2f   frequency x%.2f   leaf x%.2f   branch x%.2f   phase x%.2f"
		):format(
			scene.direction,
			scene.speed,
			scene.time_scale,
			force,
			m.Bending,
			m.BendDetailFrequency,
			m.BendDetailLeafAmplitude,
			m.BendDetailBranchAmplitude,
			m.BendDetailPhase
		)
	)
end

local function slider(children, label, max, get, set)
	children[#children + 1] = Text{Text = label, IgnoreMouseInput = true}
	children[#children + 1] = Slider{
		Min = 0,
		Max = max,
		Value = get(),
		OnChange = function(value)
			set(value)
			apply_wind()
			update_readout()
		end,
		layout = {GrowWidth = 1, MinSize = Vec2(380, 16)},
	}
end

local function multiplier(children, label, param)
	slider(
		children,
		label .. " (x of the material's)",
		4,
		function()
			return scene.multipliers[param]
		end,
		function(value)
			scene.multipliers[param] = value
		end
	)
end

local function show()
	if not panel:IsValid() then
		local children = {}

		slider(
			children,
			"direction",
			360,
			function()
				return scene.direction
			end,
			function(value)
				scene.direction = math.floor(value + 0.5)
			end
		)

		slider(
			children,
			"speed",
			MAX_SPEED,
			function()
				return scene.speed
			end,
			function(value)
				scene.speed = value
			end
		)

		slider(
			children,
			"time scale (0 stops them)",
			2,
			function()
				return scene.time_scale
			end,
			function(value)
				scene.time_scale = value
			end
		)

		multiplier(children, "bending", "Bending")
		multiplier(children, "detail frequency", "BendDetailFrequency")
		multiplier(children, "leaf amplitude", "BendDetailLeafAmplitude")
		multiplier(children, "branch amplitude", "BendDetailBranchAmplitude")
		multiplier(children, "detail phase", "BendDetailPhase")
		children[#children + 1] = Text{
			Ref = function(self)
				readout = self
			end,
			Text = "",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		panel = Panel.World:Ensure(
			Window{
				Key = "WindDebugWindow",
				Title = "WIND",
				RequestMouse = true,
				Closable = false,
				Minimizable = false,
				Maximizable = false,
				MinSize = Vec2(420, 0),
			}{
				Column{layout = {ChildGap = "S", Padding = "M", GrowWidth = 1, AlignmentX = "stretch"}}(children),
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
		panel.visual:SetVisible(false)
	end
end)

function scene.Remove()
	event.RemoveListener("Update", "wind_debug")
	event.RemoveListener("Update", "wind_debug_controls")
	weather.SetWindTimeScale(1)

	for _, entry in ipairs(scene.materials) do
		for _, param in ipairs(PARAMS) do
			entry.material["Set" .. param](entry.material, entry.base[param])
		end
	end

	if panel:IsValid() then panel:Remove() end

	scene.scatter_set:Remove()
	scene.root:Remove()
	_G.wind_debug = nil
end

return scene
