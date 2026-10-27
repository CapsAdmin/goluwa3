local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
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
local POLE_FLEX = 0.2
local PUSH_FLEX = 0.25
local PUSH_HEIGHT = 3
local PUSH_BRANCH_Y = 2.8
local PUSH_BRANCH_LENGTH = 3.2
local PUSH_ROW = Vec3(0, 0, -13)
local PUSH_RANGE = 10
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

if _G.vegetation_debug then _G.vegetation_debug.Remove() end

local scene = {}
_G.vegetation_debug = scene
scene.root = Entity.New{Name = "vegetation_debug", Parent = Entity.World}
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
	local root = {
		pivot = {0, 0, 0},
		mid = {0, height * 0.5, 0},
		tip = {0, height, 0},
		flex = POLE_FLEX,
	}
	local mesh = MeshBuilder.New()
	mesh:SetChain(0, 0, 0, 0, height * 0.5, 0, 0, height, 0)
	mesh:Tube(
		{
			{0, 0, 0, height / 75, 0, 0, 1},
			{0, height * 0.5, 0, height / 75, 0, 0, 1},
			{0, height, 0, height / 150, 0, 0, 1},
		},
		{sides = 10, cap = true}
	)
	parts[1] = {
		mesh = mesh:Build{bend_height = height, name = "vegetation_debug_pole", root_chain = root},
		material = pole_material,
		collide = true,
	}

	for i = 1, #BRANCH_COLORS do
		local angle = (i - 1) * math.pi * 0.5
		local dir = Vec3(math.cos(angle), 0, math.sin(angle))
		local side = Vec3(-dir.z, 0, dir.x)
		local phase = (i - 1) / 4
		local branch = MeshBuilder.New()
		local points = {}
		local chain = {
			0,
			branch_height,
			0,
			dir.x * branch_length * 0.5,
			branch_height,
			dir.z * branch_length * 0.5,
			dir.x * branch_length,
			branch_height,
			dir.z * branch_length,
		}
		branch:SetChain(unpack(chain))

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
			mesh = branch:Build{bend_height = height, name = "vegetation_debug_branch_" .. i, root_chain = root},
			material = branch_materials[i],
		}
		local planes = MeshBuilder.New()
		planes:SetChain(unpack(chain))

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
			mesh = planes:Build{bend_height = height, name = "vegetation_debug_planes_" .. i, root_chain = root},
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
			mesh = mesh:Build{bend_height = 0.6, name = "vegetation_debug_grass"},
			material = grass_material,
		},
	}
end

local push_wood = tree_material(Color(0.55, 0.35, 0.2, 1))
local push_leaf = tree_material(Color(0.2, 0.7, 0.25, 1), true)

local function build_push_stick()
	local mesh = MeshBuilder.New()
	local points = {}

	for k = 0, 12 do
		local t = k / 12
		points[#points + 1] = {0, PUSH_HEIGHT * t, 0, 0.035, 0, 0, 1 - t}
	end

	mesh:SetChain(0, 0, 0, 0, PUSH_HEIGHT * 0.5, 0, 0, PUSH_HEIGHT, 0)
	mesh:Tube(points, {sides = 8, cap = true})
	return {
		{
			mesh = mesh:Build{bend_height = PUSH_HEIGHT, name = "vegetation_debug_push_stick"},
			material = pole_material,
		},
	}
end

local function build_push_branch(name, leaflets, flutter_gradient)
	local root = {
		pivot = {0, 0, 0},
		mid = {0, PUSH_BRANCH_Y * 0.5, 0},
		tip = {0, PUSH_BRANCH_Y, 0},
		flex = POLE_FLEX,
	}
	local pole = MeshBuilder.New()
	pole:SetChain(0, 0, 0, 0, PUSH_BRANCH_Y * 0.5, 0, 0, PUSH_BRANCH_Y, 0)
	pole:Tube(
		{
			{0, 0, 0, 0.06, 0, 0, 1},
			{0, PUSH_BRANCH_Y, 0, 0.05, 0, 0, 1},
		},
		{sides = 8, cap = true}
	)
	local branch_chain = {
		0,
		PUSH_BRANCH_Y,
		0,
		PUSH_BRANCH_LENGTH * 0.5,
		PUSH_BRANCH_Y,
		0,
		PUSH_BRANCH_LENGTH,
		PUSH_BRANCH_Y,
		0,
	}
	local branch = MeshBuilder.New()
	branch:SetChain(unpack(branch_chain))
	local points = {}

	for k = 0, 16 do
		local t = k / 16
		points[#points + 1] = {
			t * PUSH_BRANCH_LENGTH,
			PUSH_BRANCH_Y,
			0,
			0.04 * (
				1 - t * 0.5
			),
			0,
			0,
			trees.Stiffness(t * PUSH_BRANCH_LENGTH, PUSH_FLEX),
		}
	end

	branch:Tube(points, {sides = 8, cap = true})
	local parts = {
		{
			mesh = pole:Build{bend_height = PUSH_HEIGHT, name = name .. "_pole", root_chain = root},
			material = push_wood,
			collide = true,
		},
		{
			mesh = branch:Build{bend_height = PUSH_HEIGHT, name = name .. "_branch", root_chain = root},
			material = push_wood,
		},
	}

	if leaflets then
		local mesh = MeshBuilder.New()
		mesh:SetChain(unpack(branch_chain))
		local rows, columns, length, width = 5, 3, 0.8, 0.22

		for reach = 0.25, PUSH_BRANCH_LENGTH, 0.25 do
			for _, side in ipairs{-1, 1} do
				local first = mesh:GetVertexCount()

				for row = 0, rows do
					local f = row / rows

					for column = 0, columns do
						mesh:SetColor(
							flutter_gradient and f or 1,
							0,
							trees.Stiffness(reach + f * length, PUSH_FLEX)
						)
						mesh:Vertex(
							reach + (column / columns - 0.5) * width,
							PUSH_BRANCH_Y - f * length * 0.35,
							side * f * length,
							0,
							1,
							0,
							column / columns,
							f
						)
					end
				end

				for row = 0, rows - 1 do
					for column = 0, columns - 1 do
						local a = first + row * (columns + 1) + column
						local b, c, d = a + 1, a + columns + 2, a + columns + 1

						if side > 0 then mesh:Quad(a, b, c, d) else mesh:Quad(d, c, b, a) end
					end
				end
			end
		end

		parts[#parts + 1] = {
			mesh = mesh:Build{bend_height = PUSH_HEIGHT, name = name .. "_leaflets", root_chain = root},
			material = push_leaf,
		}
	end

	return parts
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

		if part.collide then
			child:AddComponent(
				"rigid_body",
				{Shape = MeshShape.New(part.mesh), MotionType = "static", WorldGeometry = true, Friction = 0.8}
			)
		end
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
	polygon:SetName("vegetation_debug_ground")
	spawn(
		"vegetation_debug_ground",
		{
			{
				mesh = polygon,
				material = Material.New{
					ColorMultiplier = Color(0.4, 0.4, 0.42, 1),
					MetallicMultiplier = 0,
					RoughnessMultiplier = 0.9,
				},
				collide = true,
			},
		},
		Vec3(0, 0, 0),
		0,
		1,
		nil
	)
end

local tree_6 = build_tree(6)
spawn("vegetation_debug_tree", tree_6, Vec3(-6, 0, -6), 0, 1, "6 m")
spawn("vegetation_debug_tree_turned", tree_6, Vec3(6, 0, -6), 45, 1, "6 m, turned 45")
spawn(
	"vegetation_debug_tree_scaled",
	tree_6,
	Vec3(-6, 0, 6),
	120,
	1.5,
	"6 m x1.5, turned 120"
)
spawn("vegetation_debug_tree_small", tree_6, Vec3(6, 0, 6), -30, 0.6, "6 m x0.6, turned -30")
spawn("vegetation_debug_tree_short", build_tree(3), Vec3(-15, 0, 0), 0, 1, "3 m")
spawn("vegetation_debug_tree_tall", build_tree(12), Vec3(15, 0, 0), 0, 1, "12 m")
spawn(
	"vegetation_debug_push_stick",
	build_push_stick(),
	PUSH_ROW + Vec3(-9, 0, 0),
	0,
	1,
	"stick, stiffness 1 to 0"
)
spawn(
	"vegetation_debug_push_branch",
	build_push_branch("vegetation_debug_push_branch", false),
	PUSH_ROW + Vec3(-4, 0, 0),
	0,
	1,
	"branch, stiffness falls along it"
)
spawn(
	"vegetation_debug_push_leaves",
	build_push_branch("vegetation_debug_push_leaves", true, true),
	PUSH_ROW + Vec3(2, 0, 0),
	0,
	1,
	"leaflets, flutter 0 at the stem to 1 at the edge"
)
spawn(
	"vegetation_debug_push_uniform",
	build_push_branch("vegetation_debug_push_uniform", true, false),
	PUSH_ROW + Vec3(8, 0, 0),
	0,
	1,
	"leaflets, flutter 1 everywhere"
)
scene.labels[#scene.labels + 1] = {
	position = PUSH_ROW + Vec3(0, 4.5, 0),
	text = "push test, hold Q for the pusher controls",
}
scene.pusher = {shape = 0, size = 0.6, x = 0, y = 2.4, z = 0, sweep = 0.5, time = 0}
local pusher_material = Material.New{
	ColorMultiplier = Color(1, 0.35, 0.25, 0.4),
	Translucent = true,
	MetallicMultiplier = 0,
	RoughnessMultiplier = 0.8,
}
local pusher_ent = NULL

local function build_pusher()
	if pusher_ent:IsValid() then pusher_ent:Remove() end

	local p = scene.pusher
	local config = {
		Name = "vegetation_debug_pusher",
		Parent = scene.root,
		Position = PUSH_ROW + Vec3(p.x, p.y, p.z),
		Material = pusher_material,
		RigidBody = {MotionType = "kinematic"},
	}

	if p.shape == 0 then
		config.Radius = p.size
		pusher_ent = shapes.Sphere(config)
	elseif p.shape == 1 then
		config.Size = Vec3(p.size * 4, p.size * 0.4, p.size * 3)
		pusher_ent = shapes.Box(config)
	else
		config.Radius = p.size * 0.5
		config.Height = p.size * 3.4
		pusher_ent = shapes.Capsule(config)
	end
end

build_pusher()
local ball_position = Vec3(0, 1.5, 20)
shapes.Sphere{
	Name = "vegetation_debug_ball",
	Parent = scene.root,
	Radius = 0.5,
	Position = ball_position,
	Material = pusher_material,
}
scene.labels[#scene.labels + 1] = {position = ball_position + Vec3(0, 1, 0), text = "dynamic sphere, pick it up with the physgun"}
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
			local ent = Entity.New{Name = "vegetation_debug_crysis_" .. i, Parent = scene.root}
			ent:AddComponent("transform"):SetPosition(model[2])
			ent:AddComponent("visual"):SetModelPath(root .. model[1])
			scene.pending[#scene.pending + 1] = ent.visual
			scene.labels[#scene.labels + 1] = {position = model[2], text = model[1]:match("([^/]+)%.cgf$")}
		end
	end
end

local grass_patch = build_grass(1.5, 120, 1)
spawn("vegetation_debug_grass", grass_patch, Vec3(-3, 0, 14), 0, 1, "grass")
spawn("vegetation_debug_grass_turned", grass_patch, Vec3(0, 0, 14), 60, 1, "grass, turned 60")
spawn("vegetation_debug_grass_scaled", grass_patch, Vec3(3, 0, 14), 0, 2, "grass x2")
scene.scatter_set = ScatterSet.New{
	Name = "vegetation_debug",
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
		"vegetation_debug_scatter_ground",
		{
			{
				mesh = mesh:Build{name = "vegetation_debug_scatter_ground"},
				material = Material.New{
					ColorMultiplier = Color(0.35, 0.33, 0.3, 1),
					MetallicMultiplier = 0,
					RoughnessMultiplier = 0.9,
					ScatterSet = scene.scatter_set,
				},
				collide = true,
			},
		},
		SCATTER_CENTER,
		0,
		1,
		"scatter: grass conform, small trees"
	)
end

local spawn_point = Entity.New{Name = "vegetation_debug_spawn", Parent = scene.root}
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

event.AddListener("Update", "vegetation_debug", function(dt)
	local p = scene.pusher

	if p.sweep > 0 then
		p.time = p.time + dt * p.sweep
		p.x = math.sin(p.time) * PUSH_RANGE
	end

	pusher_ent.transform:SetPosition(PUSH_ROW + Vec3(p.x, p.y, p.z))

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
		id = "vegetation_debug_arrow",
		from = from,
		to = to,
		color = color,
		line_width = 3,
		time = 0.1,
	}
	debug_draw.DrawLine{
		id = "vegetation_debug_arrow_l",
		from = to,
		to = to - dir * 0.6 + side,
		color = color,
		line_width = 3,
		time = 0.1,
	}
	debug_draw.DrawLine{
		id = "vegetation_debug_arrow_r",
		from = to,
		to = to - dir * 0.6 - side,
		color = color,
		line_width = 3,
		time = 0.1,
	}

	for i, label in ipairs(scene.labels) do
		if label.text then
			debug_draw.DrawText{
				id = "vegetation_debug_label_" .. i,
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

local function slider(children, label, max, get, set, min)
	children[#children + 1] = Text{Text = label, IgnoreMouseInput = true}
	children[#children + 1] = Slider{
		Min = min or 0,
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

		slider(
			children,
			"pusher shape (0 sphere, 1 slab, 2 capsule)",
			2,
			function()
				return scene.pusher.shape
			end,
			function(value)
				local shape = math.floor(value + 0.5)

				if shape ~= scene.pusher.shape then
					scene.pusher.shape = shape
					build_pusher()
				end
			end
		)

		slider(
			children,
			"pusher size",
			2,
			function()
				return scene.pusher.size
			end,
			function(value)
				scene.pusher.size = value
				build_pusher()
			end,
			0.2
		)

		slider(
			children,
			"pusher sweep speed (0 stops it)",
			3,
			function()
				return scene.pusher.sweep
			end,
			function(value)
				scene.pusher.sweep = value
			end
		)

		slider(
			children,
			"pusher x (when not sweeping)",
			PUSH_RANGE + 2,
			function()
				return scene.pusher.x
			end,
			function(value)
				scene.pusher.x = value
			end,
			-PUSH_RANGE - 2
		)

		slider(
			children,
			"pusher height",
			5,
			function()
				return scene.pusher.y
			end,
			function(value)
				scene.pusher.y = value
			end
		)

		slider(
			children,
			"pusher depth",
			4,
			function()
				return scene.pusher.z
			end,
			function(value)
				scene.pusher.z = value
			end,
			-4
		)

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
				Key = "VegetationDebugWindow",
				Title = "VEGETATION",
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

event.AddListener("Update", "vegetation_debug_controls", function()
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
	event.RemoveListener("Update", "vegetation_debug")
	event.RemoveListener("Update", "vegetation_debug_controls")
	weather.SetWindTimeScale(1)

	for _, entry in ipairs(scene.materials) do
		for _, param in ipairs(PARAMS) do
			entry.material["Set" .. param](entry.material, entry.base[param])
		end
	end

	if panel:IsValid() then panel:Remove() end

	scene.scatter_set:Remove()
	scene.root:Remove()
	_G.vegetation_debug = nil
end

return scene
