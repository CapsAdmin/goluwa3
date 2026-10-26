local Matrix44 = import("goluwa/structs/matrix44.lua")
local aim_pose = import("lua/aim_pose.lua")
local bone_keys = {}
local TURN = math.pi * 2
local rotation = Matrix44():Identity()

local function sample(keys, t)
	local count = #keys

	if t <= keys[1][1] then return keys[1][2] end

	for i = 2, count do
		local key = keys[i]

		if t <= key[1] then
			local previous = keys[i - 1]
			local f = (t - previous[1]) / (key[1] - previous[1])
			f = f * f * (3 - 2 * f)
			return previous[2] + (key[2] - previous[2]) * f
		end
	end

	return keys[count][2]
end

local function get_value(value, t, inst, pose)
	if type(value) == "function" then return value(inst, pose) end

	if type(value) == "table" then return sample(value, t) end

	return value
end

local function rotate(bones, entry, axis, angle)
	local c, s = math.cos(angle), math.sin(angle)
	rotation:Identity()

	if axis == 1 then
		rotation.m11, rotation.m12, rotation.m21, rotation.m22 = c, s, -s, c
	elseif axis == 2 then
		rotation.m00, rotation.m02, rotation.m20, rotation.m22 = c, -s, s, c
	else
		rotation.m00, rotation.m01, rotation.m10, rotation.m11 = c, s, -s, c
	end

	aim_pose.RotateChain(bones, entry.Chain, #entry.Chain, bones[entry.Pivot], rotation)
end

function bone_keys.Apply(bones, keys, inst, pose)
	local def = inst.def
	local t = 0
	local wave = inst.phase * TURN

	if keys.Time == "phase" then
		t = inst.phase
	elseif keys.Time == "cycle" then
		t = inst.cycle % def.Period / def.Period
		wave = inst.cycle
	end

	local phase = pose.seed * TURN

	for i = 1, #keys do
		local entry = keys[i]
		local scale = inst.weight

		if entry.Wobble then
			scale = scale * (
					1 + entry.Wobble * math.sin(wave * entry.Frequency + entry.Offset + phase)
				)
		end

		if entry.Pitch then
			rotate(bones, entry, 1, get_value(entry.Pitch, t, inst, pose) * scale)
		end

		if entry.Yaw then
			rotate(bones, entry, 2, get_value(entry.Yaw, t, inst, pose) * scale)
		end

		if entry.Roll then
			rotate(bones, entry, 3, get_value(entry.Roll, t, inst, pose) * scale)
		end
	end
end

return bone_keys
