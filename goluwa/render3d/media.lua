local Vec3 = import("goluwa/structs/vec3.lua")
local media = {}
media.MOLECULAR_SCATTERING = Vec3(0.00114, 0.00191, 0.00454)
media.PARTICLE_PHASE_G = 0.92

local function water(absorption, scattering)
	return {
		Absorption = absorption,
		Scattering = scattering,
		PorousScattering = Vec3(0, 0, 0),
		PhaseG = media.PARTICLE_PHASE_G,
		IOR = 1.333,
		AbbeNumber = 55.8,
	}
end

media.presets = {
	ice = {
		Absorption = Vec3(0.19, 0.058, 0.012),
		Scattering = Vec3(1, 1, 1),
		PorousScattering = Vec3(150, 150, 150),
		PhaseG = 0.8,
		IOR = 1.31,
		AbbeNumber = 55.8,
		Skin = {
			tint_ratio = {1.0, 0.7, 0.55},
			deep_color = {0.02, 0.21, 0.71},
			porous_color = {0.92, 0.96, 1.0},
		},
	},
	fog = {
		Absorption = Vec3(0, 0, 0),
		Scattering = Vec3(1, 1, 1),
		PorousScattering = Vec3(0, 0, 0),
		PhaseG = 0.6,
		IOR = 1.0003,
		AbbeNumber = 0,
	},
	ocean = water(Vec3(0.45, 0.065, 0.021), Vec3(0.030, 0.034, 0.042)),
	open_ocean = water(Vec3(0.46, 0.072, 0.051), Vec3(0.126, 0.142, 0.174)),
	temperate_sea = water(Vec3(0.47, 0.089, 0.137), Vec3(0.342, 0.386, 0.472)),
	tropical = water(Vec3(0.42, 0.058, 0.024), Vec3(0.064, 0.072, 0.088)),
	coastal = water(Vec3(0.5, 0.1, 0.13), Vec3(0.09, 0.13, 0.11)),
	lake = water(Vec3(0.5, 0.11, 0.19), Vec3(0.025, 0.035, 0.03)),
	pond = water(Vec3(0.95, 0.42, 0.85), Vec3(0.3, 0.42, 0.24)),
	swamp = water(Vec3(0.9, 1.4, 2.6), Vec3(0.32, 0.22, 0.08)),
	glacial = water(Vec3(0.48, 0.075, 0.07), Vec3(0.55, 0.7, 0.78)),
	pool = water(Vec3(0.34, 0.052, 0.016), Vec3(0.003, 0.003, 0.003)),
}
local EMPTY_SKIN = {tint_ratio = {0, 0, 0}, deep_color = {0, 0, 0}, porous_color = {0, 0, 0}}
media.MAX_SLOTS = 15
media.SLOT_STRIDE = 6
media.TERRAIN_MEDIUM = "ice"
media.slots = {}
media.generation = 0
local slot_ids = {}

function media.Acquire(name, density)
	assert(media.presets[name], "unknown medium " .. tostring(name))
	assert(density > 0, "medium density must be above 0")
	local key = name .. "@" .. density
	local id = slot_ids[key]

	if id then return id end

	id = #media.slots + 1
	assert(id <= media.MAX_SLOTS, "too many media in use")
	media.slots[id] = {name = name, density = density, key = key}
	slot_ids[key] = id
	media.generation = media.generation + 1
	return id
end

function media.SetDensity(id, density)
	local slot = media.slots[id]
	assert(density > 0, "medium density must be above 0")
	slot_ids[slot.key] = nil
	slot.density = density
	slot.key = slot.name .. "@" .. density
	slot_ids[slot.key] = id
	media.generation = media.generation + 1
end

function media.WriteSlots(out)
	for id, slot in ipairs(media.slots) do
		local preset = media.presets[slot.name]
		local skin = preset.Skin or EMPTY_SKIN
		local density = slot.density
		local base = id * media.SLOT_STRIDE
		local extinction = out[base]
		extinction[0] = preset.Absorption.x * density
		extinction[1] = preset.Absorption.y * density
		extinction[2] = preset.Absorption.z * density
		extinction[3] = density
		local scattering = out[base + 1]
		scattering[0] = preset.Scattering.x * density
		scattering[1] = preset.Scattering.y * density
		scattering[2] = preset.Scattering.z * density
		scattering[3] = preset.PhaseG
		local porous_scattering = out[base + 2]
		porous_scattering[0] = preset.PorousScattering.x * density
		porous_scattering[1] = preset.PorousScattering.y * density
		porous_scattering[2] = preset.PorousScattering.z * density
		local tint = out[base + 3]
		tint[0], tint[1], tint[2] = skin.tint_ratio[1], skin.tint_ratio[2], skin.tint_ratio[3]
		local deep = out[base + 4]
		deep[0], deep[1], deep[2] = skin.deep_color[1], skin.deep_color[2], skin.deep_color[3]
		local porous = out[base + 5]
		porous[0], porous[1], porous[2] = skin.porous_color[1], skin.porous_color[2], skin.porous_color[3]
	end
end

function media.Define(absorption, scattering)
	local name = string.format(
		"custom:%.5f,%.5f,%.5f:%.5f,%.5f,%.5f",
		absorption.x,
		absorption.y,
		absorption.z,
		scattering.x,
		scattering.y,
		scattering.z
	)
	media.presets[name] = water(absorption, scattering)
	return name
end

setmetatable(
	media.presets,
	{
		__index = function(presets, name)
			if type(name) ~= "string" or name:sub(1, 7) ~= "custom:" then return nil end

			local numbers = {}

			for number in name:gmatch("[-%d.e]+") do
				numbers[#numbers + 1] = tonumber(number)
			end

			assert(#numbers == 6, "malformed custom medium " .. name)
			local preset = water(
				Vec3(numbers[1], numbers[2], numbers[3]),
				Vec3(numbers[4], numbers[5], numbers[6])
			)
			rawset(presets, name, preset)
			return preset
		end,
	}
)

function media.GetExtinction(name)
	local preset = media.presets[name]
	return preset.Absorption + media.MOLECULAR_SCATTERING + preset.Scattering
end

function media.MediumFromFog(color, extinction, albedo_scale)
	local brightest = math.max(color.x, color.y, color.z, 1e-4)
	local absorption = Vec3()
	local scattering = Vec3()

	for _, c in ipairs({"x", "y", "z"}) do
		local channel_extinction = extinction * math.lerp(color[c] / brightest, 1.8, 0.7)
		scattering[c] = channel_extinction * math.clamp(color[c] * albedo_scale, 0.005, 0.9)
		absorption[c] = channel_extinction - scattering[c]
	end

	return absorption, scattering
end

return media
