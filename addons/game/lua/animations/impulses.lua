local RECOIL_ANGLE = math.rad(6)
local FLINCH_ANGLE = math.rad(10)
local REACT_ATTACK = 0.05
local REACT_HOLD = 0.07
local REACT_SPRING = 14
local REACT_DAMP = 9
local REACT_SHOVE = 0.22
local REACT_LEAN = 0.4
local REACT_DIP = 0.06
local REACT_MAX_INTENSITY = 2

local function react_envelope(t)
	if t < REACT_ATTACK then
		local f = t / REACT_ATTACK
		return 1 - (1 - f) ^ 3
	end

	local h = t - REACT_ATTACK - REACT_HOLD

	if h < 0 then return 1 end

	return math.exp(-REACT_DAMP * h) * math.cos(REACT_SPRING * h)
end

return {
	recoil = {
		Kind = "impulse",
		Trigger = "Shots",
		Decay = 8,
		Aim = function(inst, aim)
			return aim:Copy():RotatePitch(RECOIL_ANGLE * inst.weight)
		end,
	},
	flinch = {
		Kind = "impulse",
		Trigger = "Hits",
		Decay = 4,
		Torso = function(inst)
			return inst.weight * FLINCH_ANGLE
		end,
	},
	hit_react = {
		Kind = "action",
		Trigger = "Reacts",
		Restart = true,
		Duration = 0.5,
		Intensity = 1,
		Init = function(inst, pose)
			local direction = pose.Owner.transform:GetRotation():GetConjugated():VecMul(pose.ReactDirection)
			inst.dx, inst.dy, inst.dz = direction.x, direction.y, direction.z
			inst.intensity = math.clamp(pose.ReactIntensity, 0, REACT_MAX_INTENSITY) * inst.def.Intensity
		end,
		Pelvis = function(inst, pose, out)
			local e = react_envelope(inst.time) * inst.intensity
			out[1] = inst.dx * REACT_SHOVE * e
			out[2] = inst.dy * REACT_SHOVE * e - REACT_DIP * e
			out[3] = inst.dz * REACT_SHOVE * e
			out[4] = 0
			out[5] = REACT_LEAN * inst.dz * e
			out[6] = -REACT_LEAN * inst.dx * e
		end,
	},
}
