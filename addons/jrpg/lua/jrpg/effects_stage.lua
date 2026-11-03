local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Gizmo = import("lua/gizmo.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local actors = import("lua/actors.lua")
local emitters = import("lua/emitters.lua")
local clips = import("goluwa/render3d/clips.lua")
local effects_drive = import("lua/jrpg/effects_drive.lua")
local npcs = import("lua/npcs.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local effects_stage = {}
effects_stage.Kinds = {"player", "npc", "gizmo"}
effects_stage.DefaultNpc = "citizen"
effects_stage.Cameras = {"front", "side", "high"}
effects_stage.Exposures = {day = 15, dusk = 11, night = 7}
effects_stage.ExposureNames = {"day", "dusk", "night"}
local TOKENS = {
	target = function(self)
		return self.Target
	end,
	["target.health"] = function(self)
		return self.Target.health
	end,
	["target.position"] = function(self)
		return self.Target.transform:GetPosition():Copy()
	end,
	chest = function(self)
		return self.Chest:Copy()
	end,
	ground = function(self)
		return self.Ground:Copy()
	end,
	normal = function(self)
		return self.Normal:Copy()
	end,
}
local NORMAL_LENGTH = 0.6
local DRIVE_LINGER = 3

function effects_stage.New(kind, npc_name)
	local rig = assert(_G.PLAYER_RIG, "the effects editor previews on the local player")
	local forward = actors.GetForward(rig):Copy()
	forward.y = 0
	forward = forward:GetNormalized()
	local anchor = rig.transform:GetPosition() + forward * 5
	local self = {
		Kind = kind,
		NpcName = npc_name,
		Target = rig,
		Toward = forward * -1,
		Chest = Vec3(),
		Ground = Vec3(),
		Normal = Vec3(0, 1, 0),
	}

	if kind == "player" then
		self.Toward = forward
	elseif kind == "npc" then
		self.Target = npcs.Spawn(npc_name, anchor, 0)
		self.Target.ai_controller.Wander = false
		self.Spawned = true
	else
		self.Marker = Entity.New{Name = "effects_editor_marker", transform = {Position = anchor + Vec3(0, 1, 0)}}
		self.Marker:SetTransient(true)
		Gizmo.EnableGizmo(self.Marker)
	end

	self.SavedUnkillable = self.Target.health:IsUnkillable()
	self.Target.health:SetUnkillable(true)
	effects_stage.Update(self, anchor)
	return self
end

function effects_stage.ResolveParams(self, params)
	local out = {}

	for key, value in pairs(params) do
		if type(value) == "string" and value:starts_with("$") then
			out[key] = assert(TOKENS[value:sub(2)], "unknown preview token " .. value)(self)
		elseif type(value) == "table" and key:lower():find("color", 1, true) and #value >= 3 then
			out[key] = Color(value[1], value[2], value[3], value[4] or 1)
		elseif type(value) == "table" then
			out[key] = table.copy(value)
		else
			out[key] = value
		end
	end

	return out
end

function effects_stage.GetSubject(self)
	if self.Marker then return self.Marker.transform:GetPosition() end

	return self.Target.transform:GetPosition()
end

function effects_stage.PlayEmitter(self, name, inputs, count, drive)
	effects_stage.StopDrive(self)

	if (emitters.Files.Source[name].RatePerMeter or 0) == 0 then
		emitters.Burst(name, self.Chest, self.Normal, count, inputs)
		return
	end

	local entity = vfx.CreateEmitter("effects_editor_emitter", emitters.Get(name, inputs))

	effects_stage.StartDrive(
		self,
		drive or effects_drive.Defaults.sweep,
		function(state)
			entity.transform:SetPosition(state.Position)
		end,
		function()
			vfx.StopEmitter(entity, DRIVE_LINGER)
		end
	)
end

function effects_stage.PlayContinuousEmitter(self, name, inputs)
	effects_stage.StopDrive(self)
	local entity = vfx.CreateEmitter("effects_editor_emitter", emitters.Get(name, inputs))
	entity.transform:SetPosition(self.Chest)
	return function()
		if entity:IsValid() then vfx.StopEmitter(entity, DRIVE_LINGER) end
	end
end

function effects_stage.PlayClip(self, name, params, drive, release)
	local clip = clips.Play(name, params)

	if drive then
		effects_stage.StartDrive(
			self,
			drive,
			function(state)
				local position = state.Position
				params.position:Set(position.x, position.y, position.z)

				if state.Base then
					params.base:Set(state.Base.x, state.Base.y, state.Base.z)
					params.tip:Set(state.Tip.x, state.Tip.y, state.Tip.z)
				end
			end,
			function()
				clip:End(release or 1)
			end
		)
	end

	return clip
end

function effects_stage.StartDrive(self, spec, on_step, on_stop)
	effects_stage.StopDrive(self)
	self.Drive = {State = effects_drive.Start(spec, self), OnStep = on_step, OnStop = on_stop}
	on_step(self.Drive.State)
end

function effects_stage.StopDrive(self)
	local drive = self.Drive

	if drive then
		self.Drive = nil
		drive.OnStop()
	end
end

function effects_stage.Update(self, eye)
	local drive = self.Drive

	if drive then
		if effects_drive.Step(drive.State) then
			drive.OnStep(drive.State)
		else
			effects_stage.StopDrive(self)
		end
	end

	if self.Marker then
		local transform = self.Marker.transform
		self.Chest = transform:GetPosition():Copy()
		self.Ground = self.Chest
		self.Normal = transform:GetRotation():GetUp()
		debug_draw.DrawLine{
			id = "effects_stage_normal",
			from = self.Chest,
			to = self.Chest + self.Normal * NORMAL_LENGTH,
			width = 3,
			ignore_z = true,
		}
		debug_draw.DrawSphere{
			id = "effects_stage_point",
			position = self.Chest,
			radius = 0.04,
			ignore_z = true,
		}
		return
	end

	self.Chest = actors.GetCenter(self.Target):Copy()
	self.Ground = self.Target.transform:GetPosition():Copy()
	self.Normal = (eye - self.Chest):GetNormalized()
end

function effects_stage.Remove(self)
	effects_stage.StopDrive(self)

	if self.Marker then
		Gizmo.DisableGizmo()
		self.Marker:Remove()
		debug_draw.Remove("effects_stage_normal")
		debug_draw.Remove("effects_stage_point")
	end

	if self.Spawned then
		self.Target:Remove()
	else
		status_effects.Clear(self.Target)
		self.Target.health:SetUnkillable(self.SavedUnkillable)
	end
end

return effects_stage
