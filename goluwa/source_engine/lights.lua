local pvars = import("goluwa/cli/pvars.lua")
local Color = import("goluwa/structs/color.lua")
local units = import("goluwa/source_engine/units.lua")
local lights = {}
local instances = table.weak("k")

function lights.Register(component)
	instances[component] = true
end

function lights.GetInstances()
	return instances
end

local function update_lights(_, is_init)
	if is_init then return end

	for component in pairs(instances) do
		if component:IsValid() then component:Apply() end
	end
end

pvars.StartGroup("bsp_lights", {store = false})
local intensity_pvar = pvars.Setup2{
	key = "bsp_light_intensity",
	default = 0.55,
	min = 0,
	help = "scales every light a bsp map spawns",
	callback = update_lights,
}
local distance_pvar = pvars.Setup2{
	key = "bsp_light_distance",
	default = 4,
	min = 0.05,
	help = "scales the fifty and zero percent distances of bsp lights, their brightness near the light stays",
	callback = update_lights,
}
local core_pvar = pvars.Setup2{
	key = "bsp_light_core",
	default = 0,
	min = 0,
	help = "scales the flat core of a bsp light's falloff, 0 is a point that gets very bright up close",
	callback = update_lights,
}
local warm_pvar = pvars.Setup2{
	key = "bsp_light_warm",
	default = 1,
	min = 0,
	help = "scales bsp lights that are redder than they are blue, candles and fires",
	callback = update_lights,
}
local glow_pvar = pvars.Setup2{
	key = "bsp_light_glow",
	default = 0.3,
	min = 0,
	help = "apparent radius of bsp lights as a fraction of their fifty percent distance, it softens their glow in fog and widens their specular highlights, 0 is a hot point",
	callback = update_lights,
}
pvars.EndGroup()
-- the fog is lit by the scene and tinted by the controller's colour, its brightest channel scaled to this
-- the visibility distance is scaled because source's fog is linear and ours exponential

local convert_source_light_to_engine

do
	local MAX_SOURCE_RADIUS = 0.25

	local function solve_quadratic(x1, y1, x2, y2, x3, y3)
		local det = (x1 - x2) * (x1 - x3) * (x2 - x3)
		local a = (x3 * (y2 - y1) + x2 * (y1 - y3) + x1 * (y3 - y2)) / det
		local b = (x3 * x3 * (y1 - y2) + x1 * x1 * (y2 - y3) + x2 * x2 * (y3 - y1)) / det
		local c = (
				x1 * x3 * (
					x3 - x1
				) * y2 + x2 * x2 * (
					x3 * y1 - x1 * y3
				) + x2 * (
					x1 * x1 * y3 - x3 * x3 * y1
				)
			) / det
		return a, b, c
	end

	local function solve_fifty_percent(d50, d0)
		local a, b, c

		for i = 0, 20 do
			local t = i / 20
			a, b, c = solve_quadratic(0, 1, d50, (1 - t) * 2 + t * (1 + 255 * d50 / d0), d0, 256)

			if 2 * a + b >= 0 then break end
		end

		local scale = 2 / (c + d50 * (b + d50 * a))
		return c * scale, b * scale, a * scale
	end

	function convert_source_light_to_engine(info)
		local light = info._lightHDR or info._light
		local brightness = light.brightness * (info._lightscaleHDR or 1)
		local d50 = tonumber(info._fifty_percent_distance) or 0
		local d0 = tonumber(info._zero_percent_distance) or 0
		local c, l, q
		local intensity_scale = intensity_pvar:Get()

		if light.r > light.b then intensity_scale = intensity_scale * warm_pvar:Get() end

		if d50 > 0 then
			local scale = distance_pvar:Get()
			d50, d0 = d50 * scale, d0 * scale
			intensity_scale = intensity_scale / scale ^ 2

			if d0 < d50 then d0 = 2 * d50 end

			c, l, q = solve_fifty_percent(d50, d0)
			q = math.max(q, 0)
		else
			c = math.max(tonumber(info._constant_attn) or 0, 0)
			l = math.max(tonumber(info._linear_attn) or 0, 0)
			q = math.max(tonumber(info._quadratic_attn) or 0, 0)

			if c + l + q == 0 then c = 1 end

			brightness = brightness * (c + 100 * l + 100 ^ 2 * q)
		end

		if q > 0 then
			brightness = brightness / q
			c = c / q
			l = l / q
			q = 1
		end

		local s = units.meters
		local source_radius = math.sqrt(c) * s
		local core = 0

		if l + q > 0 then
			-- the light's flat core is part of its falloff, but only a small part is a sphere
			source_radius = math.min(source_radius, MAX_SOURCE_RADIUS)
			core = math.max(c * s ^ 2 - source_radius ^ 2, 0) * core_pvar:Get()
		end

		return {
			color = Color(light.r, light.g, light.b, 1),
			intensity = brightness * s ^ 2 * intensity_scale,
			range = d50 > 0 and d0 * s or 0,
			source_radius = source_radius,
			constant_falloff = core,
			linear_falloff = l * s,
			quadratic_falloff = q,
			glow_radius = (d50 > 0 and d50 * s or 10) * glow_pvar:Get(),
		}
	end
end


lights.Convert = convert_source_light_to_engine

function lights.Apply(light, info)
	local params = convert_source_light_to_engine(info)
	light:SetRange(params.range)
	light:SetSourceRadius(params.source_radius)
	light:SetConstantFalloff(params.constant_falloff)
	light:SetLinearFalloff(params.linear_falloff)
	light:SetQuadraticFalloff(params.quadratic_falloff)
	light:SetGlowRadius(params.glow_radius)
	light:SetLumen(params.intensity * params.color:GetLuminance() * light:GetEmissionSolidAngle())
end


return lights
