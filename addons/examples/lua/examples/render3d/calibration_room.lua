local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local root = Entity.New{Name = "calibration_room"}
local ROOM_WIDTH = 4
local ROOM_DEPTH = 3.6
local ROOM_HEIGHT = 2.6
local WALL = 0.1
local TABLE_HEIGHT = 0.75
local CANDLE_HEIGHT = 0.12
local FLAME_RADIUS = 0.008
local CANDLE_COLOR = Color(1, 0.52, 0.14, 1)
local CANDLE_LUMEN = 4 * math.pi
local wall_albedo = 0.7

local function box(name, position, size, material)
	return shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Material = material,
		RigidBody = {MotionType = "static", Friction = 0.85},
	}
end

local function matte(color)
	return shapes.Material{Color = color, Roughness = 0.9, Metallic = 0}
end

local walls = matte(Color(wall_albedo, wall_albedo, wall_albedo, 1))
local floor = matte(Color(0.42, 0.27, 0.13, 1))
local wood = matte(Color(0.3, 0.18, 0.09, 1))
local wax = matte(Color(0.85, 0.82, 0.7, 1))
local grey_card = matte(Color(0.18, 0.18, 0.18, 1))
local white_card = matte(Color(0.9, 0.9, 0.9, 1))
local black_card = matte(Color(0.03, 0.03, 0.03, 1))
local w, d, h, t = ROOM_WIDTH, ROOM_DEPTH, ROOM_HEIGHT, WALL
box("floor", Vec3(0, -t / 2, 0), Vec3(w + 2 * t, t, d + 2 * t), floor)
box("ceiling", Vec3(0, h + t / 2, 0), Vec3(w + 2 * t, t, d + 2 * t), walls)
box("wall_back", Vec3(0, h / 2, -d / 2 - t / 2), Vec3(w + 2 * t, h, t), walls)
box("wall_front", Vec3(0, h / 2, d / 2 + t / 2), Vec3(w + 2 * t, h, t), walls)
box("wall_left", Vec3(-w / 2 - t / 2, h / 2, 0), Vec3(t, h, d), walls)
box("wall_right", Vec3(w / 2 + t / 2, h / 2, 0), Vec3(t, h, d), walls)
box("table_top", Vec3(0, TABLE_HEIGHT - 0.02, 0), Vec3(1.3, 0.04, 0.75), wood)

for _, x in ipairs{-0.6, 0.6} do
	for _, z in ipairs{-0.32, 0.32} do
		box(
			"table_leg",
			Vec3(x, (TABLE_HEIGHT - 0.04) / 2, z),
			Vec3(0.05, TABLE_HEIGHT - 0.04, 0.05),
			wood
		)
	end
end

box(
	"candle",
	Vec3(0, TABLE_HEIGHT + CANDLE_HEIGHT / 2, 0),
	Vec3(0.03, CANDLE_HEIGHT, 0.03),
	wax
)
box(
	"black_card",
	Vec3(-0.45, TABLE_HEIGHT + 0.002, 0.18),
	Vec3(0.16, 0.004, 0.22),
	black_card
)
box(
	"grey_card",
	Vec3(-0.25, TABLE_HEIGHT + 0.002, 0.18),
	Vec3(0.16, 0.004, 0.22),
	grey_card
)
box(
	"white_card",
	Vec3(-0.05, TABLE_HEIGHT + 0.002, 0.18),
	Vec3(0.16, 0.004, 0.22),
	white_card
)
local flame_position = Vec3(0, TABLE_HEIGHT + CANDLE_HEIGHT + FLAME_RADIUS * 1.5, 0)
local flame_material = shapes.Material{
	Color = CANDLE_COLOR,
	Roughness = 0.9,
	Metallic = 0,
	AlbedoAlphaIsEmissive = true,
}
local flame = shapes.Sphere{
	Name = "flame",
	Parent = root,
	Position = flame_position,
	Radius = FLAME_RADIUS,
	Material = flame_material,
	Collision = false,
	RigidBody = false,
}
local light_entity = Entity.New{Name = "candle_light", Parent = root}
light_entity:AddComponent("transform")
local light = light_entity:AddComponent("light_point")
light:SetColor(CANDLE_COLOR)
local lumen = CANDLE_LUMEN
local emissive_lights_room = false

local function update_candle()
	light.Owner.transform:SetPosition(flame_position)
	light:SetLumen(emissive_lights_room and 0 or lumen)
	local luminance = lumen / (4 * math.pi ^ 2 * FLAME_RADIUS ^ 2)
	flame_material:SetEmissiveMultiplier(
		Color(
			1,
			1,
			1,
			luminance / (CANDLE_COLOR:GetLuminance() * render3d.EMISSIVE_REFERENCE_LUMINANCE)
		)
	)
end

update_candle()
pvars.SetSession("weather_enabled", false)
exposure.Set("eye.enabled", true)

commands.Add("calibration_lumen=number", function(value)
	lumen = value
	update_candle()
end)

commands.Add("calibration_emissive_lights=boolean", function(enabled)
	emissive_lights_room = enabled
	update_candle()
end)

commands.Add("calibration_eye=boolean", function(enabled)
	exposure.Set("eye.enabled", enabled)
end)

commands.Add("calibration_report", function()
	local previous = post_source.GetExposureTexture(true):Download()
	local current = post_source.GetExposureTexture():Download()
	local previous_exposure = previous:GetPixelFloat(0, 0)
	local _, _, previous_adapted = current:GetPixelFloat(0, 0)
	local exposure_value, metered_ev = current:GetPixelFloat(0, 0)
	local paper_white = pvars.Get("r_hdr_paper_white")
	local display_scale = exposure.IsEye() and
		math.min(2 ^ (previous_adapted - 3) / 64, 1) ^ exposure.Get("eye.viewer_adaptation")
		or
		1
	local scene = post_source.GetRawSceneSourceTexture():Download()
	local camera = render3d.GetCamera()
	local intensity = lumen / (4 * math.pi)
	print(
		(
			"candle: %.2f lm, %.2f cd, flame %.0f cd/m2"
		):format(lumen, intensity, lumen / (4 * math.pi ^ 2 * FLAME_RADIUS ^ 2))
	)
	print(
		(
			"metered EV %.2f, exposure %.4g per cd/m2, paper white %d nits x viewer scale %.3f"
		):format(metered_ev, exposure_value, paper_white, display_scale)
	)
	local spots = {
		{"white card (90%)", 0.9, Vec3(-0.05, TABLE_HEIGHT, 0.18)},
		{"grey card (18%)", 0.18, Vec3(-0.25, TABLE_HEIGHT, 0.18)},
		{"black card (3%)", 0.03, Vec3(-0.45, TABLE_HEIGHT, 0.18)},
		{
			(
				"back wall (%.0f%%)"
			):format(wall_albedo * 100),
			wall_albedo,
			Vec3(0, 1.3, -ROOM_DEPTH / 2),
		},
	}

	for _, spot in ipairs(spots) do
		local offset = spot[3] - flame_position
		local distance = offset:GetLength()
		local normal_component = spot[1]:find("wall") and math.abs(offset.z) or math.abs(offset.y)
		local direct = intensity * normal_component / distance ^ 3 * spot[2] / math.pi
		local screen = camera:WorldPositionToScreen(spot[3], scene.width, scene.height, true)
		local r, g, b = scene:GetPixelFloat(math.floor(screen.x), math.floor(screen.y))
		local rendered = (0.2126 * r + 0.7152 * g + 0.0722 * b) * 32 / previous_exposure
		print(
			(
				"%-18s direct-light estimate %.4f cd/m2, rendered %.4f cd/m2 (with bounce), shown at %.3f nits"
			):format(spot[1], direct, rendered, rendered * exposure_value * paper_white * display_scale)
		)
	end
end)

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 1.55, 1.6))
	cam:SetAngles(Deg3(-22, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.character_movement:SetEyePosition(cam:GetPosition())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
