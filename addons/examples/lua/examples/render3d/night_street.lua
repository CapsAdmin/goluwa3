local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local weather = import("goluwa/render3d/weather.lua")
local foliage = import("lua/foliage/foliage.lua")

if _G.night_street then _G.night_street:Remove() end

local root = Entity.New{Name = "night_street", Parent = Entity.World}
root:AddComponent("transform")
_G.night_street = root
local ROAD_WIDTH = 7
local SIDEWALK_WIDTH = 2.5
local STREET_LENGTH = 200
local STREET_CENTER = 40
local FACADE_Z = ROAD_WIDTH / 2 + SIDEWALK_WIDTH
local LAMP_COLOR = Color(1, 0.82, 0.6, 1)

local function box(name, position, size, material, rotation)
	return shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Rotation = rotation,
		Material = material,
		RigidBody = {MotionType = "static", Friction = 0.85},
	}
end

local function matte(color, roughness)
	return shapes.Material{Color = color, Roughness = roughness or 0.9, Metallic = 0}
end

local function emissive(color, luminance)
	local material = shapes.Material{Color = color, Roughness = 0.9, Metallic = 0, AlbedoAlphaIsEmissive = true}
	material:SetEmissiveMultiplier(
		Color(
			1,
			1,
			1,
			luminance / (color:GetLuminance() * render3d.EMISSIVE_REFERENCE_LUMINANCE)
		)
	)
	return material
end

local function light(kind, position, rotation, color, lumen)
	local ent = Entity.New{Name = kind, Parent = root}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)

	if rotation then ent.transform:SetRotation(rotation) end

	local component = ent:AddComponent(kind)
	component:SetColor(color)
	component:SetLumen(lumen)
	return component
end

local function point(position, color, lumen)
	return light("light_point", position, nil, color, lumen)
end

local function spot(position, pitch, yaw, color, lumen, inner, outer)
	local component = light("light_spot", position, QuatDeg3(pitch, yaw, 0), color, lumen)
	component:SetInnerCone(inner)
	component:SetOuterCone(outer)
	return component
end

local asphalt = matte(Color(0.05, 0.05, 0.055, 1), 0.5)
local concrete = matte(Color(0.22, 0.21, 0.2, 1), 0.85)
local soil = matte(Color(0.05, 0.04, 0.03, 1), 1)
local metal = matte(Color(0.12, 0.12, 0.13, 1), 0.5)
local awning = matte(Color(0.35, 0.08, 0.06, 1), 0.9)
local facades = {
	matte(Color(0.55, 0.5, 0.38, 1)),
	matte(Color(0.4, 0.5, 0.52, 1)),
	matte(Color(0.6, 0.38, 0.32, 1)),
	matte(Color(0.5, 0.52, 0.45, 1)),
	matte(Color(0.45, 0.4, 0.5, 1)),
	matte(Color(0.58, 0.55, 0.5, 1)),
	matte(Color(0.38, 0.45, 0.4, 1)),
}
box("ground", Vec3(STREET_CENTER, -0.06, 0), Vec3(400, 0.1, 300), soil)
box(
	"road",
	Vec3(STREET_CENTER, -0.04, 0),
	Vec3(STREET_LENGTH, 0.08, ROAD_WIDTH),
	asphalt
)

for _, side in ipairs{-1, 1} do
	box(
		"sidewalk",
		Vec3(STREET_CENTER, 0.06, side * (ROAD_WIDTH + SIDEWALK_WIDTH) / 2),
		Vec3(STREET_LENGTH, 0.12, SIDEWALK_WIDTH),
		concrete
	)
end

local heights = {11, 9, 13.5, 8.5, 12, 10, 14}

for i = 1, 42 do
	local width = 3.6 + (i * 7 % 3) * 0.35
	local x = -34 + (i - 1) * 4.1
	local height = heights[(i - 1) % #heights + 1]
	local material = facades[(i * 3 - 1) % #facades + 1]
	box("shophouse", Vec3(x, height / 2, FACADE_Z + 4), Vec3(width, height, 8), material)
	box(
		"awning",
		Vec3(x, 3.1, FACADE_Z - 0.7),
		Vec3(width - 0.1, 0.06, 1.4),
		awning,
		QuatDeg3(0, 0, -6)
	)
end

local function lamp_post(x)
	local pole_z = ROAD_WIDTH / 2 + 0.5
	local top = 8.5
	box("lamp_pole", Vec3(x, top / 2, pole_z), Vec3(0.16, top, 0.16), metal)
	box("lamp_arm", Vec3(x, top, pole_z - 1.2), Vec3(0.1, 0.1, 2.4), metal)
	box("lamp_head", Vec3(x, top - 0.05, pole_z - 2.2), Vec3(0.45, 0.1, 0.9), metal)
	box(
		"lamp_lens",
		Vec3(x, top - 0.13, pole_z - 2.2),
		Vec3(0.4, 0.04, 0.8),
		emissive(LAMP_COLOR, 20000)
	)
	spot(Vec3(x, top - 0.2, pole_z - 2.2), -90, 0, LAMP_COLOR, 16000, 30, 72)
end

lamp_post(6)
lamp_post(30)
local uplights = {
	{x = 4, color = Color(0.1, 1, 0.2, 1), palm = "palm_a"},
	{x = 14, color = Color(1, 0.05, 0.05, 1), palm = "palm_b"},
	{x = 24, color = Color(0.1, 0.25, 1, 1), palm = "palm_c"},
}

for _, entry in ipairs(uplights) do
	local tree = Entity.New{Name = entry.palm, Parent = root}
	tree:AddComponent("transform"):SetPosition(Vec3(entry.x, 0.12, -(ROAD_WIDTH / 2 + SIDEWALK_WIDTH - 0.8)))
	tree:AddComponent("visual"):SetModelPath(foliage.GetModelPath("trees", entry.palm))
	local base = Vec3(entry.x, 0.12, ROAD_WIDTH / 2 + 0.6)
	box("uplight_housing", base + Vec3(0, 0.05, 0), Vec3(0.3, 0.1, 0.3), metal)
	box(
		"uplight_lens",
		base + Vec3(0, 0.11, 0),
		Vec3(0.2, 0.02, 0.2),
		emissive(entry.color, 10000)
	)
	spot(base + Vec3(0, 0.2, 0), 45, 0, entry.color, 9000, 8, 22)
end

local function sign(position, size, color, luminance, light_lumen)
	box("sign", position, size, emissive(color, luminance))

	if light_lumen then point(position + Vec3(0, 0, -0.8), color, light_lumen) end
end

local function neon_frame(center, width, height, color)
	local thickness = 0.06
	local material = emissive(color, 4000)
	box(
		"neon_top",
		center + Vec3(0, height / 2, 0),
		Vec3(width, thickness, thickness),
		material
	)
	box(
		"neon_bottom",
		center - Vec3(0, height / 2, 0),
		Vec3(width, thickness, thickness),
		material
	)
	box(
		"neon_left",
		center - Vec3(width / 2, 0, 0),
		Vec3(thickness, height, thickness),
		material
	)
	box(
		"neon_right",
		center + Vec3(width / 2, 0, 0),
		Vec3(thickness, height, thickness),
		material
	)
	box(
		"neon_slash",
		center,
		Vec3(width * 0.8, thickness, thickness),
		material,
		QuatDeg3(0, 0, 25)
	)
	point(center + Vec3(0, 0, -0.6), color, 120)
end

local front = FACADE_Z - 0.15
neon_frame(Vec3(-1.5, 4.4, front), 2.2, 0.9, Color(1, 0.1, 0.55, 1))
sign(
	Vec3(0.2, 6.2, FACADE_Z - 0.45),
	Vec3(0.18, 2.6, 0.6),
	Color(1, 0.12, 0.08, 1),
	1500,
	110
)
sign(Vec3(2.9, 5.2, front), Vec3(2.6, 0.7, 0.1), Color(0.1, 0.55, 1, 1), 1200, 120)
sign(
	Vec3(6.2, 6, FACADE_Z - 0.45),
	Vec3(0.18, 2.2, 0.6),
	Color(0.2, 1, 0.3, 1),
	1500,
	100
)
box(
	"pharmacy_cross_v",
	Vec3(10.5, 5.2, front),
	Vec3(0.5, 1.7, 0.1),
	emissive(Color(0.1, 1, 0.25, 1), 1800)
)
box(
	"pharmacy_cross_h",
	Vec3(10.5, 5.2, front),
	Vec3(1.7, 0.5, 0.1),
	emissive(Color(0.1, 1, 0.25, 1), 1800)
)
point(Vec3(10.5, 5.2, front - 0.8), Color(0.1, 1, 0.25, 1), 130)
sign(Vec3(14.8, 4.6, front), Vec3(3, 0.9, 0.1), Color(1, 0.65, 0.1, 1), 1350, 120)
neon_frame(Vec3(18.6, 5.4, front), 2.4, 1.1, Color(0.2, 0.6, 1, 1))
sign(
	Vec3(22, 6.5, FACADE_Z - 0.45),
	Vec3(0.18, 2.8, 0.6),
	Color(1, 0.9, 0.3, 1),
	1500,
	110
)
sign(Vec3(25.5, 4.4, front), Vec3(2.8, 0.8, 0.1), Color(1, 0.15, 0.1, 1), 1200, 120)
neon_frame(Vec3(29.8, 4.8, front), 2.2, 0.9, Color(0.7, 0.2, 1, 1))
sign(
	Vec3(33.4, 5.8, FACADE_Z - 0.45),
	Vec3(0.18, 2.4, 0.6),
	Color(0.1, 0.9, 0.9, 1),
	1500,
	100
)
local strip_colors = {
	Color(1, 0.1, 0.6, 1),
	Color(0.1, 0.8, 1, 1),
	Color(1, 0.8, 0.2, 1),
}

for strip, x0 in ipairs{-6, 8.6, 20.4} do
	for i = 0, 11 do
		local color = strip_colors[(i + strip) % #strip_colors + 1]
		local position = Vec3(x0 + i * 0.3, 2.95, FACADE_Z - 1.3)
		box("strip_led", position, Vec3(0.1, 0.05, 0.1), emissive(color, 8000))
		point(position - Vec3(0, 0.15, 0), color, 6)
	end
end

for i = 0, 9 do
	local position = Vec3(11.8 + (i % 2) * 0.1, 0.6 + i * 0.7, FACADE_Z - 0.2)
	box(
		"edge_led",
		position,
		Vec3(0.08, 0.08, 0.08),
		emissive(Color(1, 0.85, 0.6, 1), 20000)
	)
	point(position + Vec3(0, 0, -0.2), Color(1, 0.85, 0.6, 1), 30)
end

for i = 0, 5 do
	local position = Vec3(0 + i * 2.2, 3.6 + (i % 2) * 0.25, FACADE_Z - 1.7)
	local color = Color(1, 0.12, 0.04, 1)
	shapes.Sphere{
		Name = "lantern",
		Parent = root,
		Position = position,
		Radius = 0.18,
		Material = emissive(color, 1500),
		Collision = false,
		RigidBody = false,
	}
	point(position, color, 15)
end

local function pole_light(x, z, height, color, lumen, luminance)
	box("pole", Vec3(x, height / 2, z), Vec3(0.12, height, 0.12), metal)
	shapes.Sphere{
		Name = "bulb",
		Parent = root,
		Position = Vec3(x, height + 0.12, z),
		Radius = 0.12,
		Material = emissive(color, luminance),
		Collision = false,
		RigidBody = false,
	}
	point(Vec3(x, height + 0.12, z), color, lumen)
end

local function lone_sign(x, width, height, y, color, luminance, lumen)
	box(
		"lone_sign",
		Vec3(x, y, front),
		Vec3(width, height, 0.1),
		emissive(color, luminance)
	)
	point(Vec3(x, y, front - 0.8), color, lumen)
end

lamp_post(58)
lamp_post(-30)
lone_sign(74, 2.6, 0.8, 5, Color(1, 0.08, 0.06, 1), 2500, 120)
lone_sign(106, 2.2, 0.7, 4.6, Color(0.15, 1, 0.3, 1), 2500, 120)
lone_sign(-22, 2.4, 0.8, 4.8, Color(0.9, 0.15, 1, 1), 2500, 120)
pole_light(48, -11, 2.4, Color(0.8, 0.95, 1, 1), 700, 15000)
box("food_cart", Vec3(48, 0.55, -11.8), Vec3(1.6, 1.1, 0.9), awning)
pole_light(66, -10, 5, Color(1, 0.55, 0.12, 1), 1400, 15000)
pole_light(86, -12, 3.2, Color(0.2, 0.4, 1, 1), 1000, 15000)
pole_light(-38, -10, 4, Color(0.2, 1, 0.7, 1), 1100, 15000)
pole_light(120, -9, 4.5, Color(1, 0.25, 0.1, 1), 1300, 15000)
box("scooter_body", Vec3(92, 0.45, 1.6), Vec3(1.7, 0.7, 0.5), metal)
box(
	"scooter_headlight",
	Vec3(91.1, 0.65, 1.6),
	Vec3(0.06, 0.14, 0.2),
	emissive(Color(1, 0.97, 0.9, 1), 40000)
)
spot(Vec3(91, 0.65, 1.6), 0, 90, Color(1, 0.97, 0.9, 1), 900, 8, 20)
weather.SetLocation(10.78, 106.7)
weather.SetTime(1791640800)
weather.SetTimeScale(0)
exposure.Set("eye.enabled", true)
local cam = render3d.GetCamera()
cam:SetPosition(Vec3(-9, 1.7, 0.8))
cam:SetAngles(Deg3(-2, -78, 0))
local rig = Entity.World:GetKeyed("player_camera_rig")

if rig and rig:IsValid() then
	rig.character_movement:SetEyePosition(cam:GetPosition())

	if rig.player_input and rig.player_input.SyncFromCamera then
		rig.player_input:SyncFromCamera(cam)
	end
end
