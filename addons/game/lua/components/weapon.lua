local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Entity = import("goluwa/entities/entity.lua")
local META = objects.CreateTemplate("weapon")
local BUTTON = usercmd.BUTTON
META.Network = {
	Slot = {"number", 0.5, "reliable"},
	Active = {"boolean", 0.5, "reliable"},
}
META:GetSet("Slot", 1)
META:GetSet("DisplayName", "")
META:GetSet("MuzzleDistance", 0.5)
META:IsSet("HiddenInFirstPerson", false)
META:GetSet("FireRate", 0.1)
META:GetSet("Automatic", false)
META:IsSet("Active", false)

function META:Initialize()
	self.time = 0
	self.next_primary = 0
	self.next_secondary = 0
end

function META:AddModelBox(size, position, material)
	local shapes = import("goluwa/render3d/shapes.lua")
	local box = shapes.Box{
		Name = "weapon_part",
		Size = size,
		Position = position,
		Material = material,
		Collision = false,
		RigidBody = false,
		PhysicsNoCollision = true,
	}
	box:SetParent(self.model)
	return box
end

function META:UpdateModel(visible, position, rotation)
	local model = self.model

	if not model then
		if not visible then return end

		model = Entity.New{Name = self.Owner:GetName() .. "_model", transform = {}}
		self.model = model
		self.model_visible = true
		self.Owner:CallLocalEvent("WeaponCreateModel")

		self.Owner:CallOnRemove(function()
			model:Remove()
		end)
	end

	if visible ~= self.model_visible then
		self.model_visible = visible

		for _, part in ipairs(model:GetChildren()) do
			part.visual:SetVisible(visible)
		end
	end

	if visible then
		model.transform:SetPosition(position)
		model.transform:SetRotation(rotation)
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
