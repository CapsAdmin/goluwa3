local new_event = import("goluwa/network/replicated_event.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local damage = import("lua/damage.lua")
local explosions = import("lua/explosions.lua")
local grenade_effects = import("lua/grenade_effects.lua")
local model_replacements = import("lua/model_replacements.lua")
local bullets = import("lua/bullets.lua")
local hl2 = {}
hl2.GAMES = {220, "gmod"}
hl2.FORWARD_X = Quat(0, 0.70710678, 0, 0.70710678)
hl2.BACKWARD_X = Quat(0, -0.70710678, 0, 0.70710678)
hl2.FORWARD_Z = Quat(0, 1, 0, 0)
hl2.GetEye = bullets.GetEye

function hl2.Model(key, path, position, rotation, scale)
	model_replacements.Register(
		key,
		{
			Game = hl2.GAMES,
			Path = path,
			Position = position,
			Rotation = rotation,
			Scale = Vec3(scale or 1, scale or 1, scale or 1),
		}
	)
end

function hl2.AttachModel(owner, key, fallback)
	if not RENDER_3D then return end

	local entry = model_replacements.Get(key)
	local child = Entity.New{Name = key, Parent = owner, transform = {}}
	child:SetTransient(true)

	if entry then
		child.transform:SetPosition(entry.Position)
		child.transform:SetRotation(entry.Rotation)
		child.transform:SetScale(entry.Scale)
		child:AddComponent("model", {ModelPath = entry.Path})
	else
		child:AddComponent("model", fallback)
	end

	return child
end

local function audio_enabled()
	return AUDIO and CLIENT
end

local function play(position, path, spl, pitch, keep)
	local sounds = import("lua/sounds.lua")
	sounds.Play(path, position, sounds.SPLToVolume(spl), pitch, nil, nil, nil, keep)
end

hl2.Sound = new_event(
	"hl2_sound",
	function(entity, path, spl, pitch, keep)
		if entity:IsValid() then
			play(entity.transform:GetWorldPosition(), path, spl, pitch, keep)
		end
	end,
	audio_enabled
)
hl2.SoundAt = new_event(
	"hl2_sound_at",
	function(position, path, spl, pitch, keep)
		play(position, path, spl, pitch, keep)
	end,
	audio_enabled
)

function hl2.RandomSound(entity, paths, spl, keep)
	hl2.Sound(entity, paths[math.random(#paths)], spl, math.randomf(0.95, 1.05), keep)
end

function hl2.Explode(info)
	local position, normal = explosions.FindGround(info.Position, info.Inflictor)

	if info.Normal then position, normal = info.Position, info.Normal end

	explosions.Blast{
		Position = position,
		Attacker = info.Attacker,
		Inflictor = info.Inflictor,
		Damage = info.Damage,
		Radius = info.Radius,
		Impulse = info.Impulse or 8,
	}
	grenade_effects.ExplodeSmall(position, normal, info.Size or 2.2)
end

do
	local Color = import("goluwa/structs/color.lua")
	local BALL_COLOR = Color(0.55, 0.75, 1, 1)
	local clips

	local function visual_enabled()
		return RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
	end

	local function init()
		if clips then return end

		clips = import("goluwa/render3d/clips.lua")
		clips.Define(
			"hl2_ball_explode",
			{
				Duration = 0.6,
				Tracks = {
					flash = {{0, 1, "outQuart"}, {0.5, 0}},
					shock = {{0, 0.1, "outQuart"}, {0.6, 1.6}},
					shock_fade = {{0, 1, "outQuad"}, {0.6, 0}},
				},
				Bursts = {
					hl2_ball_sparks = {
						Spread = 180,
						Speed = {3, 12},
						Lifetime = {0.2, 0.6},
						Size = {Keys = {{0, 0.02}, {1, 0}}},
						Drag = 1,
						GravityScale = 0.3,
						Sparkle = 1,
						Lit = false,
						Collision = "none",
						MaxParticles = 256,
						Emissive = 4e5,
						Color = {Keys = {{0, Color(0.8, 0.9, 1, 1)}, {1, Color(0.3, 0.5, 1, 0)}}},
					},
				},
				Events = {
					{0, Burst = "hl2_ball_sparks", Count = 80, Direction = "normal"},
					{
						0,
						function(p)
							import("goluwa/render3d/vfx.lua").Flash(p.position, BALL_COLOR, 30000, 0.5, {Range = 10})
							import("goluwa/render3d/screen_fields.lua").Add{
								Position = p.position,
								Duration = 0.5,
								Radius = 3,
								Thickness = 0.3,
								Blur = 20,
								Ring = 0.03,
								Aberration = 6,
							}
						end,
					},
				},
				Layers = {
					{
						Type = "sprite",
						Texture = "flare",
						Radius = 1.2,
						Brightness = 30,
						Alpha = "flash",
					},
					{
						Type = "sprite",
						Texture = "ring",
						Radius = "shock",
						Brightness = 8,
						Alpha = "shock_fade",
					},
				},
			}
		)
	end

	hl2.BallExplode = new_event(
		"hl2_ball_explode",
		function(position)
			init()
			clips.Play(
				"hl2_ball_explode",
				{position = position:Copy(), normal = Vec3(0, 1, 0), color = BALL_COLOR}
			)
		end,
		visual_enabled
	)
end

function hl2.Launch(caster, weapon, origin, velocity, values)
	local entity = Entity.New{
		Name = "hl2_" .. values.Kind,
		transform = {Position = origin, Rotation = Quat():SetLookDirection(velocity:GetNormalized())},
		hl2_projectile = values,
		network = SERVER and {} or nil,
	}
	entity.hl2_projectile:Launch(caster, weapon, velocity)
	return entity
end

function hl2.GetLaunchOrigin(character, aim, forward_offset)
	return hl2.GetEye(character) + aim:GetForward() * (
			forward_offset or
			0.6
		) + aim:GetRight() * 0.15 - aim:GetUp() * 0.12
end

function hl2.DealHit(hit, info)
	if not network.HasAuthority() then return end

	local victim, multiplier

	if hit.entity then victim, multiplier = damage.GetVictim(hit.entity) end

	if victim and victim.health then
		info.Damage = info.Damage * multiplier
		info.Position = hit.point
		info.Normal = hit.normal
		info.Part = hit.entity.ragdoll_part and hit.entity.ragdoll_part.Group
		damage.Deal(victim, info)
		return victim
	end
end

function hl2.GetDynamicBody(hit)
	local body = hit.rigid_body or (hit.entity and hit.entity.rigid_body)
	return body and body:IsDynamic() and body or nil
end

return hl2
