local objects = import("goluwa/objects/objects.lua")
local decal_geometry = import("goluwa/source_engine/decal_geometry.lua")
local units = import("goluwa/source_engine/units.lua")
local system = import("goluwa/system.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local META = objects.CreateTemplate("decal")
META:StartStorable()
META:GetSet("Mode", "overlay")
META:GetSet("Texname", "")
META:GetSet("Origin", nil)
META:GetSet("Normal", nil)
META:GetSet("UVPoints", nil)
META:GetSet("URange", nil)
META:GetSet("VRange", nil)
META:GetSet("Size", nil)
META:GetSet("Targets", nil)
META:EndStorable()
local REBUILD_SETTLE_TIME = 0.2

function META:OnDeserialized()
	local world = static_world.GetActive()

	if world then self:Attach(world) else static_world.WaitForDecals(self) end
end

function META:Attach(world)
	self.world = world
	self:Rebuild()
end

function META:Rebuild()
	self.world:SetDecalFragments(
		self,
		decal_geometry.Project(self, self.world.brush_records, self.world.displacement_records)
	)
end

function META:Activate()
	if self.active then return end

	self.active = true
	self.last_position = self.Owner.transform:GetWorldPosition()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local position = self.Owner.transform:GetWorldPosition()

	if position ~= self.last_position then
		self.last_position = position
		self.Origin = units.PositionFromEngine(position)
		self.rebuild_time = system.GetElapsedTime()
	elseif
		self.rebuild_time and
		system.GetElapsedTime() - self.rebuild_time > REBUILD_SETTLE_TIME
	then
		self.rebuild_time = nil
		self:Rebuild()
	end
end

function META:OnRemove()
	if self.world and self.world:IsValid() then
		self.world:SetDecalFragments(self, {})
	end
end

return META:Register()
