local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local Color = import("goluwa/structs/color.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local weapon_effects = {}
local FLASH_LUMEN = 40
local FLASH_TIME = 0.06
local FORCE_SPEED_SCALE = 0.3
local flash_emitter, flash_light, position_emitter, normal_emitter, force_emitter
local flash_end = 0

local function aim_rotation(direction)
	if direction.y < -0.9999 then return Quat(1, 0, 0, 0) end

	local axis = Vec3(0, 1, 0):GetCross(direction)
	return Quat(axis.x, axis.y, axis.z, 1 + direction.y):Normalize()
end

local function create_emitter(name, properties)
	properties.Playing = false
	properties.Rate = 0
	properties.Lit = false
	properties.Collision = "none"
	properties.GravityScale = 0
	return Entity.New{Name = name, transform = {}, particle_emitter_gpu = properties}
end

local function fire_emitter(entity, position, direction, count)
	entity.transform:SetPosition(position)
	entity.transform:SetRotation(aim_rotation(direction))
	entity.particle_emitter_gpu:Burst(count)
end

local function show_muzzle_flash(weapon, direction)
	if not flash_emitter then
		flash_emitter = create_emitter(
			"muzzle_flash",
			{
				MaxParticles = 256,
				Spread = 14,
				SpeedMin = 3,
				SpeedMax = 9,
				LifetimeMin = 0.03,
				LifetimeMax = 0.08,
				SizeStart = 0.035,
				SizeEnd = 0,
				Drag = 2,
				Emissive = 3e5,
				ColorStart = Color(1, 0.8, 0.4, 1),
				ColorEnd = Color(1, 0.35, 0.1, 0),
			}
		)
		flash_light = Entity.New{
			Name = "muzzle_flash_light",
			transform = {},
			light_point = {Range = 3000, OcclusionMap = false, Lumen = 0, Color = Color(1, 0.65, 0.3, 1)},
		}
	end

	local position = Vec3(weapon.weapon:GetMuzzle().transform:GetWorldMatrix():GetTranslation())
	fire_emitter(flash_emitter, position, direction, 18)
	flash_light.transform:SetPosition(position)
	flash_light.light_point:SetLumen(FLASH_LUMEN)
	flash_end = system.GetElapsedTime() + FLASH_TIME
end

local function show_hit(position, normal, force)
	if not position_emitter then
		position_emitter = create_emitter(
			"hit_position",
			{
				MaxParticles = 256,
				Spread = 180,
				SpeedMin = 0.2,
				SpeedMax = 1,
				LifetimeMin = 0.25,
				LifetimeMax = 0.5,
				SizeStart = 0.025,
				SizeEnd = 0,
				Drag = 4,
				Emissive = 2e5,
				ColorStart = Color(1, 1, 0.7, 1),
				ColorEnd = Color(1, 0.8, 0.2, 0),
			}
		)
		normal_emitter = create_emitter(
			"hit_normal",
			{
				MaxParticles = 256,
				Spread = 0,
				SpeedMin = 0.1,
				SpeedMax = 0.9,
				LifetimeMin = 0.9,
				LifetimeMax = 0.9,
				SizeStart = 0.015,
				SizeEnd = 0.015,
				Drag = 0,
				Emissive = 2e5,
				ColorStart = Color(0.2, 0.9, 1, 1),
				ColorEnd = Color(0.2, 0.9, 1, 0),
			}
		)
		force_emitter = create_emitter(
			"hit_force",
			{
				MaxParticles = 256,
				Spread = 0,
				SpeedMin = 0.1,
				SpeedMax = 1,
				LifetimeMin = 0.9,
				LifetimeMax = 0.9,
				SizeStart = 0.015,
				SizeEnd = 0.015,
				Drag = 0,
				Emissive = 2e5,
				ColorStart = Color(1, 0.3, 0.15, 1),
				ColorEnd = Color(1, 0.3, 0.15, 0),
			}
		)
	end

	fire_emitter(position_emitter, position, normal, 24)
	fire_emitter(normal_emitter, position, normal, 16)
	local length = force:GetLength()

	if length > 0 then
		force_emitter.particle_emitter_gpu:SetSpeedMax(length * FORCE_SPEED_SCALE)
		fire_emitter(force_emitter, position, force / length, 16)
	end
end

if RENDER_3D then
	event.AddListener("Update", "weapon_effects", function()
		if flash_end > 0 and system.GetElapsedTime() >= flash_end then
			flash_light.light_point:SetLumen(0)
			flash_end = 0
		end
	end)
end

if CLIENT then
	message.AddListener("weapon_muzzle_flash", function(network_id, x, y, z)
		local component = import("goluwa/entities/components/network.lua").GetByNetworkId(network_id)

		if component then show_muzzle_flash(component.Owner, Vec3(x, y, z)) end
	end)

	message.AddListener("weapon_hit", function(px, py, pz, nx, ny, nz, fx, fy, fz)
		show_hit(Vec3(px, py, pz), Vec3(nx, ny, nz), Vec3(fx, fy, fz))
	end)
end

function weapon_effects.MuzzleFlash(weapon, direction)
	if SERVER and network.IsStarted() then
		message.Broadcast(
			"weapon_muzzle_flash",
			weapon.network:GetNetworkId(),
			direction.x,
			direction.y,
			direction.z
		)
	elseif RENDER_3D then
		show_muzzle_flash(weapon, direction)
	end
end

function weapon_effects.Hit(position, normal, force)
	if SERVER and network.IsStarted() then
		message.Broadcast(
			"weapon_hit",
			position.x,
			position.y,
			position.z,
			normal.x,
			normal.y,
			normal.z,
			force.x,
			force.y,
			force.z
		)
	elseif RENDER_3D then
		show_hit(position, normal, force)
	end
end

return weapon_effects
