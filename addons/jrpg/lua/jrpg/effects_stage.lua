local Vec3 = import("goluwa/structs/vec3.lua")
local Entity = import("goluwa/entities/entity.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Gizmo = import("lua/gizmo.lua")
local actors = import("lua/actors.lua")
local npcs = import("lua/npcs.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local effects_stage = {}
effects_stage.Kinds = {"player", "npc", "gizmo"}
effects_stage.DefaultNpc = "citizen"
local NORMAL_LENGTH = 0.6

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

function effects_stage.GetSubject(self)
	if self.Marker then return self.Marker.transform:GetPosition() end

	return self.Target.transform:GetPosition()
end

function effects_stage.Update(self, eye)
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
