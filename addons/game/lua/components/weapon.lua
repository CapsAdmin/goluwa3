local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Entity = import("goluwa/entities/entity.lua")
local visibility = import("lua/visibility.lua")
local META = objects.CreateTemplate("weapon")
local BUTTON = usercmd.BUTTON
META.Network = {
	Slot = {"number", 0.5, "reliable"},
	Active = {"boolean", 0.5, "reliable"},
}
META:GetSet("Slot", 1)
META:GetSet("DisplayName", "")
META:GetSet("ModelPrefab", "")
META:IsSet("HiddenInFirstPerson", false)
META:GetSet("FireRate", 0.1)
META:GetSet("Automatic", false)
META:IsSet("Active", false)

function META:Initialize()
	self.time = 0
	self.next_primary = 0
	self.next_secondary = 0
end

-- the node of the model prefab that is named muzzle, nil while there is no model
function META:GetMuzzle()
	return self.model and self.model.prefab:GetNode("muzzle")
end

function META:UpdateModel(visible)
	local model = self.model

	if not model then
		if not visible or self.ModelPrefab == "" then return end

		model = Entity.New{
			Name = self.Owner:GetName() .. "_model",
			Parent = self.Owner:GetParent(),
			transform = {Attachment = "hand_r"},
			prefab = {Path = self.ModelPrefab},
		}
		self.model = model
		self.model_visible = true

		self.Owner:CallOnRemove(function()
			model:Remove()
		end)
	end

	if visible ~= self.model_visible then
		self.model_visible = visible
		visibility.SetTreeVisible(model, visible)
	end
end

function META:Think(dt, cmd)
	local owner = self.Owner
	self.time = self.time + dt
	owner:CallLocalEvent("WeaponThink", dt, cmd)

	if not usercmd.HasButton(cmd, BUTTON.ACTIVE) then return end

	local automatic = self.Automatic

	if
		self.time >= self.next_primary and
		(
			usercmd.WasPressed(cmd, BUTTON.ATTACK1) or
			automatic and
			usercmd.HasButton(cmd, BUTTON.ATTACK1)
		)
		and
		owner:CallLocalEvent("WeaponPrimary", cmd) ~= false
	then
		self.next_primary = self.time + self.FireRate
	end

	if
		self.time >= self.next_secondary and
		(
			usercmd.WasPressed(cmd, BUTTON.ATTACK2) or
			automatic and
			usercmd.HasButton(cmd, BUTTON.ATTACK2)
		)
		and
		owner:CallLocalEvent("WeaponSecondary", cmd) ~= false
	then
		self.next_secondary = self.time + self.FireRate
	end
end

return META:Register()
