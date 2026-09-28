--[[
	Exposure and night vision test scene.

	A sealed 16 x 10 x 16 m room lit only by a point light under the ceiling,
	with the weather off, so the room floats in a black void: no sun, moon, sky
	or air. The lamp is the only light, with or without DDGI. The room is large
	next to the blocks so most of what reaches them is bounce light, which is
	DDGI's job.

	In a closed room the average illuminance is about lumen / (area * (1 -
	reflectance)), 1152 m2 of walls here, and a wall's luminance is reflectance
	* illuminance / pi. Night vision starts below 5 cd/m2 (adapted EV 5.3) and
	is complete at 0.005 cd/m2 (adapted EV -4.6):
	  * 100 lumen: ~0.03 cd/m2, adapted EV ~-2.2, mostly rods
	  * 1000 lumen: ~0.3 cd/m2, EV ~1.8, about a quarter rod vision
	  * 10000 lumen: ~3 cd/m2, EV ~4.5, cones only

	Console commands:
	  exposure_lumen <n>          set the lamp's lumen
	  exposure_lamp_height <m>    the lamp's height above the floor, 9.8 by default
	  exposure_emissive <bool>    the same lumen from a glowing sphere instead of a point light
	  weather_enabled <bool>      the sun, sky and air
	  ddgi_enabled <bool>         bounce light; off, only the lamp's direct light is left
	  r_exposure_info             metered and adapted EV
	  r_night_vision <bool>       rod vision in mode "eye"
	  r_night_vision_threshold <cd/m2>  where half the colour is gone, 0.16 by default
	  r_night_vision_tint <0-1>   how blue rod vision is shown, 0 neutral grey
	  r_exposure_rod_adaptation <0-1>  how bright a night is in mode "eye"
	  r_exposure_mode eye|camera

	Run: luajit glw --3d lua addons/examples/lua/examples/render3d/exposure.lua
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local commands = import("goluwa/cli/commands.lua")
local shapes = import("lua/shapes.lua")
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

-- interior x and z -8..8, y 0..10
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

-- something with colour to watch lose its saturation
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
-- The lamp is a point light, or with exposure_emissive the same lumen given
-- off by a glowing sphere, which only DDGI carries into the room. A diffuse
-- sphere of radius r and luminance L gives off pi * L * 4 * pi * r^2 lumen.
-- The gbuffer's emissive target holds at most render3d.EMISSIVE_MAX_LUMINANCE,
-- which at 10000 lumen needs r > 6.3 cm.
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
		-- emission is albedo * multiplier * EMISSIVE_REFERENCE_LUMINANCE
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
weather.SetEnabled(false)

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
