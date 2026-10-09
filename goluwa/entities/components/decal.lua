local objects = import("goluwa/objects/objects.lua")
local decal_geometry = import("goluwa/source_engine/decal_geometry.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local units = import("goluwa/source_engine/units.lua")
local system = import("goluwa/system.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local META = objects.CreateTemplate("decal")
META:StartStorable()
META:GetSet("Material", "", {asset = "materials", callback = "OnMaterialChanged"})
META:GetSet("Frame", Vec4(-16, -16, 16, 16), {callback = "OnFrameChanged"})
META:GetSet("URange", Vec2(0, 1), {callback = "OnFrameChanged"})
META:GetSet("VRange", Vec2(0, 1), {callback = "OnFrameChanged"})
META:EndStorable()
local REBUILD_SETTLE_TIME = 0.2

function META:ReadTransform()
	local transform = self.Owner.transform
	self.Origin = units.PositionFromEngine(transform:GetWorldPosition())
	self.Normal, self.UAxis = decal_geometry.RotationToAxes(transform:GetRotation())
end

function META:OnDeserialized()
	local world = static_world.GetActive()

	if world then self:Attach(world) else static_world.WaitForDecals(self) end
end

function META:Attach(world)
	self.world = world
	self:ReadTransform()
	self:FindTargets()
	self:Rebuild()
end

function META:Rebuild()
	self.world:SetDecalFragments(
		self,
		decal_geometry.Project(self, self.world.brush_records, self.world.displacement_records)
	)
end

function META:OnMaterialChanged()
	if self.world then self:Rebuild() end
end

function META:FindTargets()
	self.Targets = decal_geometry.FindTargets(self, self.world.brush_records, self.world.displacement_records)
end

function META:OnFrameChanged()
	if not self.world then return end

	self:FindTargets()
	self:Rebuild()
end

function META:Activate()
	if self.active then return end

	self.active = true
	self.last_position = self.Owner.transform:GetWorldPosition()
	self.last_rotation = self.Owner.transform:GetRotation():Copy()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local transform = self.Owner.transform
	local position, rotation = transform:GetWorldPosition(), transform:GetRotation()

	if position ~= self.last_position or rotation ~= self.last_rotation then
		self.last_position = position
		self.last_rotation = rotation:Copy()
		self.rebuild_time = system.GetElapsedTime()
	elseif
		self.rebuild_time and
		system.GetElapsedTime() - self.rebuild_time > REBUILD_SETTLE_TIME
	then
		self.rebuild_time = nil
		self:ReadTransform()
		self:FindTargets()
		self:Rebuild()
	end
end

function META:OnRemove()
	if self.world and self.world:IsValid() then
		self.world:SetDecalFragments(self, {})
	end
end

return META:Register()
