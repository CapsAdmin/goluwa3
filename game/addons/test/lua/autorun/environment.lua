local Light = require("components.light")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local skybox = require("render3d.skybox")
local Texture = require("render.texture")
local event = require("event")
local input = require("input")
local sun = Light.CreateDirectional(
	{
		rotation = Quat(-0.2, 0.8, 0.4, 0.4), --:SetAngles(Deg3(50, -30, 0)),
		color = {1.0, 0.98, 0.95},
		intensity = 3.0,
		name = "Sun",
		cast_shadows = true,
		shadow_config = {
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		},
	}
)
sun:SetIsSun(true)
--sun:SetRotation(Quat(0.4, -0.1, -0.1, -0.9):Normalize())
sun:SetRotation(Quat(0.4, -0.1, -0.1, -0.9):Normalize())
render3d.SetLights({sun})

--[[
skybox.SetStarsTexture(Texture.New({
	path = "/home/caps/projects/hdr.jpg",
	mip_map_levels = "auto",
}))
	]]
event.AddListener("Update", "sun_oientation", function(dt)
	if input.IsKeyDown("k") then
		local angles = sun:GetRotation():GetAngles()
		angles.x = angles.x + dt
		sun:SetRotation(Quat():SetAngles(angles))
	elseif input.IsKeyDown("l") then
		local angles = sun:GetRotation():GetAngles()
		angles.x = angles.x - dt
		sun:SetRotation(Quat():SetAngles(angles))
	end
end)

do
	local ecs = require("ecs")
	local ffi = require("ffi")
	local Polygon3D = require("render3d.polygon_3d")
	local Material = require("render3d.material")

	local function debug_ent(pos, rot, cb)
		local sphere = ecs.CreateEntity("debug_ent", ecs.GetWorld())
		sphere:AddComponent("transform", {
			position = pos,
			rotation = rot,
		})
		local poly = Polygon3D.New()
		poly.material = Material.New()
		cb(poly, poly.material)
		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		sphere:AddComponent("model", {
			mesh = poly,
		})
	end

	for x = 0, 6 do
		for y = 0, 6 do
			debug_ent(Vec3(x, y, 0), nil, function(poly, mat)
				-- gold
				mat:SetColorMultiplier(Color(1.0, 1, 1, 1))
				local roughness = x / 8
				local metallic = y / 8
				mat:SetRoughnessMultiplier(roughness)
				mat:SetMetallicMultiplier(metallic)
				poly:CreateSphere(0.5)
			end)
		end
	end

	for y = 1, 10 do
		debug_ent(Vec3(0, y, 40), nil, function(poly, mat)
			-- gold
			mat:SetTranslucent(true)
			mat:SetColorMultiplier(Color(1, 1, 1.0, y / 10))
			poly:CreateSphere(0.5)
		end)
	end

	debug_ent(Vec3(4, 4, 10), nil, function(poly, mat)
		mat:SetColorMultiplier(Color(1, 0, 0, 1))
		mat:SetRoughnessMultiplier(1)
		mat:SetMetallicMultiplier(0)
		poly:CreateCube()
	end)

	debug_ent(Vec3(2, 2, 10), nil, function(poly, mat)
		mat:SetColorMultiplier(Color(0, 1, 0, 1))
		mat:SetRoughnessMultiplier(0)
		mat:SetMetallicMultiplier(1)
		poly:CreateCube()
	end)

	debug_ent(Vec3(4, 2, 10), nil, function(poly, mat)
		mat:SetColorMultiplier(Color(0, 0, 1, 1))
		mat:SetRoughnessMultiplier(0)
		mat:SetMetallicMultiplier(1)
		poly:CreateCube()
	end)
end
