local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Light = objects.CreateTemplate("light")
Light.instances = {}
Light.Network = {
	Color = {"color", 0.5, "reliable"},
	Lumen = {"number", 0.5, "reliable"},
	SourceRadius = {"number", 0.5, "reliable"},
	ConstantFalloff = {"number", 0.5, "reliable"},
	LinearFalloff = {"number", 0.5, "reliable"},
	QuadraticFalloff = {"number", 0.5, "reliable"},
	OcclusionMap = {"boolean", 0.5, "reliable"},
	Visible = {"boolean", 0.5, "reliable"},
}
Light:StartStorable()
Light:GetSet("Color", Color(1, 1, 1, 1))
Light:GetSet("Lumen", 0, {validate = "number"})
Light:GetSet("SourceRadius", 0, {validate = "number"})
Light:GetSet("ConstantFalloff", 0, {validate = "number"})
Light:GetSet("LinearFalloff", 0, {validate = "number"})
Light:GetSet("QuadraticFalloff", 1, {validate = "number"})
Light:GetSet("OcclusionMap", true)
Light:GetSet("Visible", true)
Light:EndStorable()

function Light:OnCreate()
	if self.Visible then list.insert(Light.instances, self) end
end

local function remove_instance(self)
	local instances = Light.instances

	for i, other in ipairs(instances) do
		if other == self then
			list.remove(instances, i)

			break
		end
	end
end

function Light:OnRemove()
	remove_instance(self)
end

function Light:SetVisible(visible)
	if self.Visible == visible then return end

	objects.CommitProperty(self, "Visible", visible)

	if visible then
		list.insert(Light.instances, self)
	else
		remove_instance(self)
	end
end

function Light.GetInstances()
	return Light.instances
end

local CUTOFF_ILLUMINANCE = 0.0005
local CUTOFF_CONTRAST = 0.001
local MAX_EFFECTIVE_RANGE = 200

function Light:GetPhotometricAmount()
	return self.Lumen
end

function Light:GetColorScale()
	local luminance = self.Color:GetLuminance()

	if luminance <= 0 then return 0 end

	return 1 / luminance
end

function Light:SetPhotometricAmount(amount)
	return self:SetLumen(amount)
end

function Light:GetEmissionSolidAngle()
	return 4 * math.pi
end

function Light:GetInverseEmissionSolidAngle()
	return 1 / self:GetEmissionSolidAngle()
end

function Light:GetEffectiveRange()
	if self.Range > 0 then return self.Range end

	if self.Lumen <= 0 then return 0 end

	local r_sq = self.SourceRadius ^ 2 + self.ConstantFalloff
	local l = self.LinearFalloff
	local q = self.QuadraticFalloff
	local c = r_sq - math.min(
			self.Lumen / (self:GetEmissionSolidAngle() * CUTOFF_ILLUMINANCE),
			(r_sq + l + q) / CUTOFF_CONTRAST
		)

	if c >= 0 then return 0 end

	if q == 0 then return math.min(-c / l, MAX_EFFECTIVE_RANGE) end

	return math.min((math.sqrt(l * l - 4 * q * c) - l) / (2 * q), MAX_EFFECTIVE_RANGE)
end

return Light:Register()
