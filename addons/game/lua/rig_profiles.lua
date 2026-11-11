local rig_profiles = {}
rig_profiles.ValveBiped = {
	Name = "valvebiped",
	Bones = {
		body = "ValveBiped.Bip01_Pelvis",
		waist = "ValveBiped.Bip01_Spine",
		spine = "ValveBiped.Bip01_Spine1",
		chest = "ValveBiped.Bip01_Spine2",
		back = "ValveBiped.Bip01_Spine4",
		neck = "ValveBiped.Bip01_Neck1",
		head = "ValveBiped.Bip01_Head1",
		clavicle_r = "ValveBiped.Bip01_R_Clavicle",
		upperarm_r = "ValveBiped.Bip01_R_UpperArm",
		forearm_r = "ValveBiped.Bip01_R_Forearm",
		hand_r = "ValveBiped.Bip01_R_Hand",
		clavicle_l = "ValveBiped.Bip01_L_Clavicle",
		upperarm_l = "ValveBiped.Bip01_L_UpperArm",
		forearm_l = "ValveBiped.Bip01_L_Forearm",
		hand_l = "ValveBiped.Bip01_L_Hand",
		thigh_r = "ValveBiped.Bip01_R_Thigh",
		calf_r = "ValveBiped.Bip01_R_Calf",
		foot_r = "ValveBiped.Bip01_R_Foot",
		thigh_l = "ValveBiped.Bip01_L_Thigh",
		calf_l = "ValveBiped.Bip01_L_Calf",
		foot_l = "ValveBiped.Bip01_L_Foot",
	},
}
rig_profiles.Alyx = {
	Name = "alyx",
	Bones = {
		body = "pelvis",
		waist = "spine_0",
		spine = "spine_1",
		chest = "spine_2",
		back = "spine_3",
		neck = "neck_0",
		head = "head",
		clavicle_r = "clavicle_R",
		upperarm_r = "arm_upper_R",
		forearm_r = "arm_lower_R",
		hand_r = "hand_R",
		clavicle_l = "clavicle_L",
		upperarm_l = "arm_upper_L",
		forearm_l = "arm_lower_L",
		hand_l = "hand_L",
		thigh_r = "leg_upper_R",
		calf_r = "leg_lower_R",
		foot_r = "ankle_R",
		thigh_l = "leg_upper_L",
		calf_l = "leg_lower_L",
		foot_l = "ankle_L",
	},
	Eyes = {"eye_L", "eye_R"},
	Fingers = {
		hand_r = {fingers = "finger_middle_0_R", thumb = "finger_thumb_0_R"},
		hand_l = {fingers = "finger_middle_0_L", thumb = "finger_thumb_0_L"},
	},
}

local function normalize(v)
	local length = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	return {v[1] / length, v[2] / length, v[3] / length}
end

-- the bone frames the pose code was written against, as the directions of anatomy in the Source 1 bone's own axes (measured from the ValveBiped bind pose)
local CANONICAL = {
	head = {
		normalize{0.9851, 0, -0.1719},
		normalize{-0.1719, 0, -0.9851},
	},
	chest = {
		normalize{-0.9999, 0, 0.0152},
		normalize{-0.0152, 0, -0.9999},
	},
	hand_r = {
		normalize{0.0129, -0.1103, -0.9938},
		normalize{0.2268, -0.8309, -0.5080},
	},
	hand_l = {
		normalize{0.0120, 0.1104, -0.9938},
		normalize{0.2199, 0.8328, -0.5080},
	},
}

local function cross(a, b)
	return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]}
end

-- an orthonormal basis (columns, row major) whose first axis is a and whose second lies in the plane of a and b
local function triad(a, b)
	local second = normalize(cross(a, b))
	local third = cross(a, second)
	return {a[1], second[1], third[1], a[2], second[2], third[2], a[3], second[3], third[3]}
end

local function multiply(a, b)
	local out = {}

	for row = 0, 2 do
		for column = 0, 2 do
			out[row * 3 + column + 1] = a[row * 3 + 1] * b[column + 1] + a[row * 3 + 2] * b[column + 4] + a[row * 3 + 3] * b[column + 7]
		end
	end

	return out
end

local function transpose(a)
	return {a[1], a[4], a[7], a[2], a[5], a[8], a[3], a[6], a[9]}
end

local function quaternion_matrix(x, y, z, w)
	return {
		1 - 2 * (
			y * y + z * z
		),
		2 * (
			x * y - z * w
		),
		2 * (
			x * z + y * w
		),
		2 * (
			x * y + z * w
		),
		1 - 2 * (
			x * x + z * z
		),
		2 * (
			y * z - x * w
		),
		2 * (
			x * z - y * w
		),
		2 * (
			y * z + x * w
		),
		1 - 2 * (
			x * x + y * y
		),
	}
end

-- model space bind rotations and positions of every bone of a skeleton
local function get_bind(skeleton)
	local bind = skeleton.BindLocal
	local rotations, positions = {}, {}

	for i = 0, skeleton.BoneCount - 1 do
		local o = i * 7
		local rotation = quaternion_matrix(bind[o + 3], bind[o + 4], bind[o + 5], bind[o + 6])
		local position = {bind[o], bind[o + 1], bind[o + 2]}
		local parent = skeleton.parents[i]

		if parent >= 0 then
			local pr, pp = rotations[parent], positions[parent]
			positions[i] = {
				pr[1] * position[1] + pr[2] * position[2] + pr[3] * position[3] + pp[1],
				pr[4] * position[1] + pr[5] * position[2] + pr[6] * position[3] + pp[2],
				pr[7] * position[1] + pr[8] * position[2] + pr[9] * position[3] + pp[3],
			}
			rotations[i] = multiply(pr, rotation)
		else
			positions[i], rotations[i] = position, rotation
		end
	end

	return rotations, positions
end

-- per biped bone, the rotation fix with canonical = bone * fix (the pose code works in the canonical frames, the rig in its own)
function rig_profiles.GetFrames(skeleton, profile)
	local frames = {}
	local rotations, positions = get_bind(skeleton)
	local bones = profile.Bones
	local right_index, left_index = skeleton:GetBoneIndex(bones.thigh_r), skeleton:GetBoneIndex(bones.thigh_l)

	if not (right_index and left_index) then return frames end

	local right = {
		positions[right_index][1] - positions[left_index][1],
		0,
		positions[right_index][3] - positions[left_index][3],
	}
	local forward = normalize{right[3], 0, -right[1]}
	local up = {0, 1, 0}

	for name, canonical in pairs(CANONICAL) do
		local index = skeleton:GetBoneIndex(bones[name])
		local first, second

		if name == "head" or name == "chest" then
			first, second = forward, up
		else
			local markers = profile.Fingers[name]
			local fingers, thumb = skeleton:GetBoneIndex(markers.fingers), skeleton:GetBoneIndex(markers.thumb)

			if fingers and thumb then
				local hand = positions[index]
				first = normalize{
					positions[fingers][1] - hand[1],
					positions[fingers][2] - hand[2],
					positions[fingers][3] - hand[3],
				}
				second = normalize{
					positions[thumb][1] - hand[1],
					positions[thumb][2] - hand[2],
					positions[thumb][3] - hand[3],
				}
			end
		end

		if index and first then
			local wanted = multiply(triad(first, second), transpose(triad(canonical[1], canonical[2])))
			local fix = multiply(transpose(rotations[index]), wanted)
			frames[name] = {fix = fix, unfix = transpose(fix)}
		end
	end

	return frames
end

do
	local cache = table.weak("k")

	-- the bone names and frame fixes of a skeleton: ValveBiped unless it is an Alyx humanoid
	function rig_profiles.Get(skeleton)
		local resolved = cache[skeleton]

		if resolved then return resolved end

		local profile = rig_profiles.ValveBiped

		if
			not skeleton:GetBoneIndex(profile.Bones.body) and
			skeleton:GetBoneIndex(rig_profiles.Alyx.Bones.body) and
			skeleton:GetBoneIndex(rig_profiles.Alyx.Bones.upperarm_l)
		then
			profile = rig_profiles.Alyx
		end

		resolved = {
			Name = profile.Name,
			Bones = profile.Bones,
			Eyes = profile.Eyes,
			Frames = profile.Fingers and rig_profiles.GetFrames(skeleton, profile) or {},
		}
		cache[skeleton] = resolved
		return resolved
	end
end

return rig_profiles
