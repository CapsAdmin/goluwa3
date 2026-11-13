local Vec3 = import("goluwa/structs/vec3.lua")
local media = {}
media.presets = {
	ice = {
		Absorption = Vec3(0.19, 0.058, 0.012),
		ParticleScattering = Vec3(0, 0, 0),
		IOR = 1.31,
		AbbeNumber = 55.8,
		Skin = {
			tint_ratio = {1.0, 0.7, 0.55},
			deep_color = {0.02, 0.21, 0.71},
			porous_color = {0.92, 0.96, 1.0},
		},
	},
}
media.MAX_SLOTS = 15
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
		local skin = assert(preset.Skin, "medium " .. slot.name .. " has no skin")
		local absorption = preset.Absorption
		local density = slot.density
		local extinction = out[id * 4]
		extinction[0] = absorption.x * density
		extinction[1] = absorption.y * density
		extinction[2] = absorption.z * density
		extinction[3] = density
		local tint = out[id * 4 + 1]
		tint[0], tint[1], tint[2] = skin.tint_ratio[1], skin.tint_ratio[2], skin.tint_ratio[3]
		local deep = out[id * 4 + 2]
		deep[0], deep[1], deep[2] = skin.deep_color[1], skin.deep_color[2], skin.deep_color[3]
		local porous = out[id * 4 + 3]
		porous[0], porous[1], porous[2] = skin.porous_color[1], skin.porous_color[2], skin.porous_color[3]
	end
end

return media
