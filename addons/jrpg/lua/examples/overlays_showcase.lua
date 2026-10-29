local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weapons = import("lua/weapons.lua")
local vfs = import("goluwa/vfs.lua")
local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/entities/entity.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
steam.MountSourceGame("gmod")
local MODEL = "models/player/kleiner.mdl"
local MODEL_SPACING = 1.5
local MODEL_YAW = test_scene.GetNumber("JRPG_OVERLAYS_YAW", -90)
local COLUMNS = 4
local SPACING = 1.7
local CYCLE = 10
local SHOWN = 7
local STAGGER = 0.4
local hold = test_scene.GetNumber("JRPG_OVERLAYS_HOLD", 0) == 1
local ITEMS = {
	{kind = "status_fire", status = "fire"},
	{kind = "status_frozen", status = "frozen"},
	{kind = "status_poison", status = "poison"},
	{kind = "status_lightning", status = "lightning"},
	{kind = "status_decay", status = "decay"},
	{kind = "status_confused", status = "confused"},
	{kind = "item_highlight"},
	{kind = "magic_generic"},
}
test_scene.Reset{
	sun = {elevation = test_scene.GetNumber("JRPG_OVERLAYS_SUN", -6), azimuth = 200},
}
shapes.Box{
	Name = "overlays_floor",
	Parent = test_scene.GetRoot(),
	Position = Vec3(0, -0.5, 0),
	Size = Vec3(60, 1, 60),
	Material = shapes.Material{Color = Color(0.16, 0.16, 0.18, 1), Roughness = 0.85},
	RigidBody = {MotionType = "static"},
}
local key = Entity.New{Name = "overlays_key_light", Parent = test_scene.GetRoot()}
key:AddComponent("transform")
key.transform:SetPosition(Vec3(0, 3.5, 2.5))
local key_light = key:AddComponent("light_point")
key_light:SetColor(Color(0.75, 0.82, 1, 1))
key_light:SetLumen(900)
local base = shapes.Material{Color = Color(0.55, 0.56, 0.6, 1), Roughness = 0.5, Metallic = 0}
local targets = {}

local function add_target(entity, item, index)
	targets[#targets + 1] = {
		entity = entity,
		kind = item.kind,
		color = item.status and status_effects.Registered[item.status].Color,
		handles = {},
		index = index,
	}
end

for i, item in ipairs(ITEMS) do
	local column = (i - 1) % COLUMNS
	local row = math.floor((i - 1) / COLUMNS)
	add_target(
		shapes.Sphere{
			Name = "overlay_" .. item.kind,
			Parent = test_scene.GetRoot(),
			Position = Vec3(-4.2 + (column - (COLUMNS - 1) / 2) * SPACING, 0.8, -row * SPACING),
			Radius = 0.7,
			Material = base,
			RigidBody = false,
			Collision = false,
		},
		item,
		i
	)
end

if vfs.IsFile(MODEL) then
	for i, item in ipairs(ITEMS) do
		local entity = Entity.New{Name = "overlay_model_" .. item.kind, Parent = test_scene.GetRoot()}
		entity:AddComponent("transform")
		local column = (i - 1) % COLUMNS
		local row = math.floor((i - 1) / COLUMNS)
		entity.transform:SetPosition(Vec3(4.2 + (column - (COLUMNS - 1) / 2) * MODEL_SPACING, 0, -row * MODEL_SPACING))
		entity.transform:SetRotation(QuatDeg3(0, MODEL_YAW, 0))
		entity:AddComponent("visual")
		entity.visual:SetModelPath(MODEL)
		add_target(entity, item, i)
	end
else
	print(MODEL .. " not found, is gmod mounted?")
end

local function collect_visuals(entity, out)
	if entity.visual then out[#out + 1] = entity.visual end

	for _, child in ipairs(entity:GetChildren()) do
		collect_visuals(child, out)
	end
end

local function release(target)
	for _, handle in ipairs(target.handles) do
		handle:Remove()
	end

	table.clear(target.handles)
end

local weapon_names = {"weapon_sword", "weapon_shield", "weapon_potion_health"}

for i, name in ipairs(weapon_names) do
	weapons.Spawn(name, Vec3((i - 2) * 1.2, 0.5, 2.8))
end

local start = system.GetElapsedTime()

event.AddListener("Update", "jrpg_overlays_showcase", function()
	local time = system.GetElapsedTime() - start

	for _, target in ipairs(targets) do
		local phase = hold and 0 or (time - (target.index - 1) * STAGGER) % CYCLE

		if phase < SHOWN then
			local children = target.entity:GetChildrenList()

			if target.source ~= children or not target.handles[1] then
				release(target)
				target.source = children
				local visuals = {}
				collect_visuals(target.entity, visuals)

				for _, visual in ipairs(visuals) do
					target.handles[#target.handles + 1] = surface_overlays.Add(visual, target.kind, {ColorA = target.color, Intensity = 0.5})
				end
			end

			local intensity = hold and 1 or 0.55 + 0.45 * math.sin(time * 0.9 + target.index)

			for _, handle in ipairs(target.handles) do
				handle:SetIntensity(intensity)
			end
		elseif target.handles[1] then
			release(target)
			target.source = nil
		end
	end
end)
