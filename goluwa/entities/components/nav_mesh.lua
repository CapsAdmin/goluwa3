local objects = import("goluwa/objects/objects.lua")
local nav_mesh = import("goluwa/source_engine/nav_mesh.lua")
local fluid = import("goluwa/physics/fluid.lua")
local META = objects.CreateTemplate("nav_mesh")
META:StartStorable()
META:GetSet("Path", "", {callback = "Load"})
META:EndStorable()

function META.GetActive()
	return META.active
end

local WADE_DEPTH = 0.6

function META:BlockFlooded()
	local mesh = self.mesh
	local volumes = fluid.volumes
	local ocean = fluid.GetOceanLevel()
	self.flooded_volumes = #volumes

	for _, volume in ipairs(volumes) do
		local inverse = volume.Owner.transform:GetWorldMatrixInverse()
		local size = volume:GetSize()

		for _, area in ipairs(mesh:GetAreas()) do
			local x, y, z = area.center_x, area.center_y, area.center_z
			local local_x = x * inverse.m00 + y * inverse.m10 + z * inverse.m20 + inverse.m30
			local local_y = x * inverse.m01 + y * inverse.m11 + z * inverse.m21 + inverse.m31
			local local_z = x * inverse.m02 + y * inverse.m12 + z * inverse.m22 + inverse.m32

			if
				math.abs(local_x) < size.x / 2 and
				math.abs(local_z) < size.z / 2 and
				local_y < -WADE_DEPTH and
				local_y > -size.y
			then
				area.Blocked = true
			end
		end
	end

	if ocean then
		for _, area in ipairs(mesh:GetAreas()) do
			if area.center_y < ocean - WADE_DEPTH then area.Blocked = true end
		end
	end
end

function META.GetMesh()
	local active = META.active

	if not active then return nil end

	if active.flooded_volumes ~= #fluid.volumes then active:BlockFlooded() end

	return active.mesh
end

function META:Initialize()
	self.initialized = true
	self:Load()
end

function META:Load()
	if not self.initialized then return end

	self.mesh = nil
	self.flooded_volumes = nil

	if META.active == self then META.active = nil end

	if self.Path == "" then return end

	self.mesh = nav_mesh.Load(self.Path)
	META.active = self
	logn("loaded navigation mesh ", self.Path, " with ", #self.mesh:GetAreas(), " areas")
end

function META:SetMesh(mesh)
	self.mesh = mesh
	self.flooded_volumes = nil
	META.active = self
end

function META:OnRemove()
	if META.active == self then META.active = nil end
end

return META:Register()
