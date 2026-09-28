local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Light = objects.CreateTemplate("light")
Light.instances = {}
Light:StartStorable()
Light:GetSet("Color", Color(1, 1, 1, 1))
Light:GetSet("Lumen", 0, {validate = "number"})
-- flattens the falloff near the light to 1 / (d^2 + r^2), in meters
Light:GetSet("SourceRadius", 0, {validate = "number"})
Light:GetSet("OcclusionMap", true)
Light:EndStorable()

-- all light components share this list so the render passes can iterate the
-- whole light set in a single pass
function Light:OnCreate()
	list.insert(Light.instances, self)
end

function Light:OnRemove()
	local instances = Light.instances

	for i, other in ipairs(instances) do
		if other == self then
			list.remove(instances, i)

			break
		end
	end
end

function Light.GetInstances()
	return Light.instances
end

-- Without a Range, a light reaches as far as it lights a surface with more
-- than this many lux. The eye adapts down to EV -4 at most
-- (render3d.exposure.min_ev), an average of 0.0078 cd/m2; a mid grey surface
-- (reflectance 0.5) lit by 0.0005 lux is 1% of that, which even fully dark
-- adapted doesn't show. The old 0.0125 lux cut a 10 lumen light off at 8 m,
-- and its falloff window (scene_lights, get_light_distance_attenuation)
-- already took 12% at half of that.
local CUTOFF_ILLUMINANCE = 0.0005

function Light:GetPhotometricAmount()
	return self.Lumen
end

-- what Color is multiplied by so it's a tint of luminance 1 and the light gives
-- off exactly Lumen, whatever its colour
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

	return math.sqrt(
		math.max(
			self.Lumen / (
					self:GetEmissionSolidAngle() * CUTOFF_ILLUMINANCE
				) - self.SourceRadius ^ 2,
			0
		)
	)
end

return Light:Register()
