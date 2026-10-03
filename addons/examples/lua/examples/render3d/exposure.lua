local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local root = Entity.New{Name = "exposure_example"}

local function box(name, position, size, material)
	shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Material = material,
		RigidBody = false,
	}
end

local wall = shapes.Material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.9, Metallic = 0}
local ROOM_SIZE = 16
local ROOM_HEIGHT = 10

do
	local t = 0.3
	local w = ROOM_SIZE
	local h = ROOM_HEIGHT
	box("room_floor", Vec3(0, -t / 2, 0), Vec3(w + t * 2, t, w + t * 2), wall)
	box("room_ceiling", Vec3(0, h + t / 2, 0), Vec3(w + t * 2, t, w + t * 2), wall)
	box("room_back", Vec3(0, h / 2, -w / 2 - t / 2), Vec3(w + t * 2, h, t), wall)
	box("room_front", Vec3(0, h / 2, w / 2 + t / 2), Vec3(w + t * 2, h, t), wall)
	box("room_left", Vec3(-w / 2 - t / 2, h / 2, 0), Vec3(t, h, w), wall)
	box("room_right", Vec3(w / 2 + t / 2, h / 2, 0), Vec3(t, h, w), wall)
end

box(
	"red_block",
	Vec3(-1, 0.4, -1.2),
	Vec3(0.8, 0.8, 0.8),
	shapes.Material{Color = Color(0.8, 0.1, 0.08, 1), Roughness = 0.6, Metallic = 0}
)
box(
	"green_block",
	Vec3(0, 0.3, -1.4),
	Vec3(0.6, 0.6, 0.6),
	shapes.Material{Color = Color(0.1, 0.7, 0.15, 1), Roughness = 0.6, Metallic = 0}
)
box(
	"blue_block",
	Vec3(1, 0.5, -1.2),
	Vec3(0.7, 1, 0.7),
	shapes.Material{Color = Color(0.08, 0.15, 0.8, 1), Roughness = 0.6, Metallic = 0}
)
local LAMP_COLOR = Color(1, 0.22, 0, 1)
local SPHERE_RADIUS = 0.15
local lumen = 12
local lamp_position = Vec3(0, ROOM_HEIGHT - 0.2, 0)
local light
local sphere
local sphere_material = shapes.Material{
	Color = LAMP_COLOR,
	Roughness = 0.9,
	Metallic = 0,
	AlbedoAlphaIsEmissive = true,
}

do
	local ent = Entity.New{Name = "room_lamp", Parent = root}
	ent:AddComponent("transform")
	light = ent:AddComponent("light_point")
	light:SetColor(LAMP_COLOR)
end

local function update_lamp()
	light.Owner.transform:SetPosition(lamp_position)
	light:SetLumen(sphere and 0 or lumen)

	if sphere then
		sphere.transform:SetPosition(lamp_position)
		local luminance = lumen / (4 * math.pi ^ 2 * SPHERE_RADIUS ^ 2)
		sphere_material:SetEmissiveMultiplier(
			Color(
				1,
				1,
				1,
				luminance / (LAMP_COLOR:GetLuminance() * render3d.EMISSIVE_REFERENCE_LUMINANCE)
			)
		)
	end
end

update_lamp()
pvars.SetSession("weather_enabled", false)

commands.Add("exposure_lumen=number", function(value)
	lumen = value
	update_lamp()
end)

commands.Add("exposure_lamp_height=number", function(y)
	lamp_position = Vec3(0, y, 0)
	update_lamp()
end)

commands.Add("exposure_emissive=boolean", function(enabled)
	if enabled and not sphere then
		sphere = shapes.Sphere{
			Name = "room_lamp_sphere",
			Parent = root,
			Position = lamp_position,
			Radius = SPHERE_RADIUS,
			Material = sphere_material,
			Collision = false,
			RigidBody = false,
		}
	elseif not enabled and sphere then
		sphere:Remove()
		sphere = nil
	end

	update_lamp()
end)

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 1.6, 4))
	cam:SetAngles(Deg3(-10, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.transform:SetPosition(cam:GetPosition():Copy())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
