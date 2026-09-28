local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Light = objects.CreateTemplate("light")
Light.instances = {}
Light:StartStorable()
Light:GetSet("Color", Color(1, 1, 1, 1))
Light:GetSet("Lumen", 0, {validate = "number"})
-- A light's intensity (Lumen / GetEmissionSolidAngle) falls off with
-- 1 / (SourceRadius^2 + LinearFalloff * d + QuadraticFalloff * d^2), d in
-- meters. The defaults are the physical inverse square law, with the source
-- radius flattening it near the light. LinearFalloff is in meters: with
-- QuadraticFalloff 0, a light falls off linearly and is as bright as an
-- inverse square one LinearFalloff meters away.
Light:GetSet("SourceRadius", 0, {validate = "number"})
Light:GetSet("LinearFalloff", 0, {validate = "number"})
Light:GetSet("QuadraticFalloff", 1, {validate = "number"})
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
-- 0.0005 lux only goes unseen when everything around it is that dark. A light
-- also lights the surfaces near it, and next to its illuminance 1 m away
-- something 10 stops dimmer doesn't show either: that's past what the display
-- shows at once and what local exposure (render3d.local_exposure.max_stops)
-- brings back. For an inverse square light this ends it at about 32 m however
-- bright it is.
local CUTOFF_CONTRAST = 0.001
-- lights that barely fall off (linear or constant falloff) would otherwise
-- reach every light grid cell and trace occlusion rays that long
local MAX_EFFECTIVE_RANGE = 200

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

	local r_sq = self.SourceRadius ^ 2
	local l = self.LinearFalloff
	local q = self.QuadraticFalloff
	-- where the falloff's denominator reaches intensity / cutoff, the larger
	-- cutoff giving the smaller denominator
	local c = r_sq - math.min(
			self.Lumen / (self:GetEmissionSolidAngle() * CUTOFF_ILLUMINANCE),
			(r_sq + l + q) / CUTOFF_CONTRAST
		)

	if c >= 0 then return 0 end

	if q == 0 then return math.min(-c / l, MAX_EFFECTIVE_RANGE) end

	return math.min((math.sqrt(l * l - 4 * q * c) - l) / (2 * q), MAX_EFFECTIVE_RANGE)
end

return Light:Register()
