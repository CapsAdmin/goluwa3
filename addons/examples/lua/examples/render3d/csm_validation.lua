--[[
	Cascaded shadow map validation scene.

	Each station is a caster box in front of a receiver wall that faces the
	camera, so the shadow patch stays readable at every distance instead of
	collapsing into a one pixel strip on the ground. The sun points along
	(1, 1, -1)/sqrt(3) toward the sun, so light travels -x, -y, +z and a caster
	at z = d shadows the receiver at z = d + L shifted -L in x and lowered by L.

	Layouts (set _G.CSM_VALIDATION_LAYOUT before importing):
		"float"  stations from 8 to 2200 units floating at distinct elevations and
		         alternating sides so no receiver hides another
		"ground" four ground level stations at distinct azimuths

	Returns the station list with probe positions so a script can sample the
	screenshot numerically. tmp/csm_test.lua does that.
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("lua/shapes.lua")
local ROOT_KEY = "csm_validation_scene"
local LAYOUT = rawget(_G, "CSM_VALIDATION_LAYOUT") or "float"
local CAMERA_POSITION = Vec3(0, 30, -40)
local root = Entity.World:Ensure{
	Key = ROOT_KEY,
	Name = ROOT_KEY,
}
root:RemoveChildren()

for _, light in ipairs(render3d.GetLights()) do
	if light.Type == "light_sun" then
		light.Owner.transform:SetRotation(Quat():SetAngles(Deg3(-35.264, 135, 0)))
	end
end

local ground_material = shapes.Material{Color = Color(0.7, 0.7, 0.7, 1), Roughness = 1, Metallic = 0}
local caster_material = shapes.Material{Color = Color(0.8, 0.3, 0.2, 1), Roughness = 0.9, Metallic = 0}
local receiver_material = shapes.Material{Color = Color(0.75, 0.75, 0.75, 1), Roughness = 1, Metallic = 0}

local function box(config)
	local ent = shapes.Box(config)
	ent:SetParent(root)
	ent.visual:SetCullDistance(1e8)
	return ent
end

box{
	Name = "csm_ground",
	Position = Vec3(0, -1, 1500),
	Size = Vec3(8000, 2, 8000),
	Material = ground_material,
	Collision = false,
}
local placements = {}

if LAYOUT == "float" then
	for i, d in ipairs{8, 20, 45, 100, 180, 300, 480, 700, 1000, 1500, 2200} do
		local h = math.max(6, d * 0.13)
		local side = (i % 2 == 1) and 1 or -1
		-- elevation slot from -20 to +40 degrees seen from the camera
		local elevation = math.rad(-20 + (i - 1) * 6)
		placements[#placements + 1] = {
			distance = d,
			x = side * d * 0.3,
			base_y = CAMERA_POSITION.y + (d - CAMERA_POSITION.z) * math.tan(elevation) - h * 0.5,
		}
	end
else
	-- four azimuth slots so no receiver hides another and the caster's
	-- perspective shift stays clear of the probes
	for i, d in ipairs{330, 700, 1200, 2200} do
		placements[#placements + 1] = {
			distance = d,
			x = d * math.tan(math.rad(({-25, 8, -8, 25})[i])),
			base_y = 0,
		}
	end
end

local stations = {}

for _, placement in ipairs(placements) do
	local d = placement.distance
	local h = math.max(6, d * 0.13)
	local w = h * 0.6
	local l = h * 0.5
	local x = placement.x
	local base_y = placement.base_y
	local receiver_z = d + l
	box{
		Name = "csm_caster_" .. d,
		Position = Vec3(x, base_y + h * 0.5, d),
		Size = Vec3(w, h, 2),
		Material = caster_material,
		Collision = false,
	}
	box{
		Name = "csm_receiver_" .. d,
		Position = Vec3(x - h * 0.25, base_y + h * 0.5, receiver_z + 1),
		Size = Vec3(h * 2.5, h, 2),
		Material = receiver_material,
		Collision = false,
	}
	stations[#stations + 1] = {
		distance = d,
		height = h,
		caster_top = Vec3(x, base_y + h, d),
		-- shadow on the receiver spans x in [x - w/2 - l, x + w/2 - l], y in [base_y, base_y + h - l]
		shadow_probe = Vec3(x - h * 0.62, base_y + (h - l) * 0.5, receiver_z),
		lit_probe = Vec3(x + h * 0.75, base_y + (h - l) * 0.5, receiver_z),
		-- ground patch away from every station, used to detect shadow acne
		acne_probe = Vec3(d * 1.2, 0, d),
	}
end

local camera = render3d.GetCamera()
camera:SetPosition(CAMERA_POSITION)
camera:SetAngles(Deg3(0, 180, 0))
camera:SetFarZ(3200)
return {
	stations = stations,
	camera_position = CAMERA_POSITION,
}
