local ffi = require("ffi")
local Skeleton = {}
Skeleton.__index = Skeleton
-- a skeleton is what a model decoder hands to the renderer for animation, all in engine space:
--   BoneNames    1 based list of names
--   Parents      1 based list of 0 based parent bone indices, -1 for roots. parents come before their children
--   BindLocal    float[bone_count * 7] local bind pose per bone: position xyz, rotation quaternion xyzw
--   InverseBind  float[bone_count * 12] inverse of the bind pose in model space, 3x4 row major
--   Clips        list of clips, see below
--   PoseParameterNames  names clips can be driven by, filled by the decoder as it adds clips
--   PoseParameterRanges  name -> {min, max}
-- a clip has
--   Name, Duration (seconds), Loop
--   clip:Sample(cycle, pose_parameters, out)  writes a local pose like BindLocal for cycle 0..1. bones the clip does not animate keep the bind pose
-- there are two levels of api. decoders and clips use the raw float arrays (CreatePose, BlendPoses,
-- ComputeSkinMatrices). everything else uses Pose, an opaque local pose with no ffi in its interface, and the rig
-- (render3d/rig.lua) that turns a pose into skinned vertices
Skeleton.PoseSize = 7
Skeleton.MatrixSize = 12
local Floats = ffi.typeof("float[?]")
local Pose = {}
Pose.__index = Pose

function Skeleton.New(config)
	local self = setmetatable({}, Skeleton)
	self.BoneNames = config.BoneNames
	self.BoneCount = #config.BoneNames
	self.BindLocal = config.BindLocal
	self.InverseBind = config.InverseBind
	self.PoseParameterNames = {}
	self.PoseParameterRanges = {}
	self.Clips = {}
	self.ClipsByName = {}
	self.parents = ffi.new("int32_t[?]", self.BoneCount)

	for i = 1, self.BoneCount do
		self.parents[i - 1] = config.Parents[i]
	end

	return self
end

function Skeleton:NewPose()
	return setmetatable({skeleton = self, data = Floats(self.BoneCount * 7)}, Pose):Reset()
end

function Pose:Reset()
	ffi.copy(self.data, self.skeleton.BindLocal, self.skeleton.BoneCount * 7 * 4)
	return self
end

function Pose:Copy(other)
	ffi.copy(self.data, other.data, self.skeleton.BoneCount * 7 * 4)
	return self
end

-- the pose of a clip at a cycle from 0 to 1, bones the clip does not animate keep the bind pose
function Pose:Sample(clip, cycle, pose_parameters)
	clip:Sample(cycle, pose_parameters, self.data)
	return self
end

-- a crossfade, a at t = 0 and b at t = 1. self may be a or b
function Pose:Blend(a, b, t)
	self.skeleton:BlendPoses(a.data, b.data, t, self.data)
	return self
end

function Skeleton:AddClip(clip)
	self.Clips[#self.Clips + 1] = clip
	self.ClipsByName[clip.Name] = clip
end

function Skeleton:CreatePose()
	return Floats(self.BoneCount * 7)
end

function Skeleton:CreateMatrices()
	return Floats(self.BoneCount * 12)
end

-- bones that are moved on top of their pose: a local matrix is applied in the space of the bone, a model matrix
-- replaces the matrix of the bone in model space. both are 3x4 row major, translation in the last column
function Skeleton:CreateBoneOverrides()
	local count = self.BoneCount
	return {
		count = 0,
		local_set = ffi.new("uint8_t[?]", count),
		local_data = Floats(count * 12),
		model_set = ffi.new("uint8_t[?]", count),
		model_data = Floats(count * 12),
	}
end

function Skeleton:GetBoneIndex(name)
	name = name:lower()

	for i, bone_name in ipairs(self.BoneNames) do
		if bone_name:lower() == name then return i - 1 end
	end
end

-- crossfade of two local poses, a at t = 0
function Skeleton:BlendPoses(a, b, t, out)
	local s = 1 - t

	for i = 0, self.BoneCount - 1 do
		local o = i * 7
		out[o] = a[o] * s + b[o] * t
		out[o + 1] = a[o + 1] * s + b[o + 1] * t
		out[o + 2] = a[o + 2] * s + b[o + 2] * t
		local ax, ay, az, aw = a[o + 3], a[o + 4], a[o + 5], a[o + 6]
		local bx, by, bz, bw = b[o + 3], b[o + 4], b[o + 5], b[o + 6]

		if ax * bx + ay * by + az * bz + aw * bw < 0 then
			bx, by, bz, bw = -bx, -by, -bz, -bw
		end

		local x, y, z, w = ax * s + bx * t, ay * s + by * t, az * s + bz * t, aw * s + bw * t
		local inv = 1 / math.sqrt(x * x + y * y + z * z + w * w)
		out[o + 3] = x * inv
		out[o + 4] = y * inv
		out[o + 5] = z * inv
		out[o + 6] = w * inv
	end
end

-- local pose -> per bone matrix taking a bind pose vertex to where the pose puts it. world gets the matrices of the
-- bones in model space on the way, overrides is nil when no bone is moved
function Skeleton:ComputeSkinMatrices(pose, out, world, overrides)
	local parents = self.parents
	local inverse_bind = self.InverseBind

	for i = 0, self.BoneCount - 1 do
		local p = i * 7
		local qx, qy, qz, qw = pose[p + 3], pose[p + 4], pose[p + 5], pose[p + 6]
		local xx, yy, zz = qx * qx, qy * qy, qz * qz
		local xy, xz, yz = qx * qy, qx * qz, qy * qz
		local wx, wy, wz = qw * qx, qw * qy, qw * qz
		local r00, r01, r02 = 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)
		local r10, r11, r12 = 2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)
		local r20, r21, r22 = 2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)
		local tx, ty, tz = pose[p], pose[p + 1], pose[p + 2]
		local w = i * 12
		local parent = parents[i]

		if overrides and overrides.local_set[i] ~= 0 then
			local o = overrides.local_data
			local q00, q01, q02, q03 = o[w], o[w + 1], o[w + 2], o[w + 3]
			local q10, q11, q12, q13 = o[w + 4], o[w + 5], o[w + 6], o[w + 7]
			local q20, q21, q22, q23 = o[w + 8], o[w + 9], o[w + 10], o[w + 11]
			tx, ty, tz = r00 * q03 + r01 * q13 + r02 * q23 + tx,
			r10 * q03 + r11 * q13 + r12 * q23 + ty,
			r20 * q03 + r21 * q13 + r22 * q23 + tz
			r00, r01, r02, r10, r11, r12, r20, r21, r22 = r00 * q00 + r01 * q10 + r02 * q20,
			r00 * q01 + r01 * q11 + r02 * q21,
			r00 * q02 + r01 * q12 + r02 * q22,
			r10 * q00 + r11 * q10 + r12 * q20,
			r10 * q01 + r11 * q11 + r12 * q21,
			r10 * q02 + r11 * q12 + r12 * q22,
			r20 * q00 + r21 * q10 + r22 * q20,
			r20 * q01 + r21 * q11 + r22 * q21,
			r20 * q02 + r21 * q12 + r22 * q22
		end

		if parent < 0 then
			world[w], world[w + 1], world[w + 2], world[w + 3] = r00, r01, r02, tx
			world[w + 4], world[w + 5], world[w + 6], world[w + 7] = r10, r11, r12, ty
			world[w + 8], world[w + 9], world[w + 10], world[w + 11] = r20, r21, r22, tz
		else
			local pw = parent * 12
			local a00, a01, a02, a03 = world[pw], world[pw + 1], world[pw + 2], world[pw + 3]
			local a10, a11, a12, a13 = world[pw + 4], world[pw + 5], world[pw + 6], world[pw + 7]
			local a20, a21, a22, a23 = world[pw + 8], world[pw + 9], world[pw + 10], world[pw + 11]
			world[w] = a00 * r00 + a01 * r10 + a02 * r20
			world[w + 1] = a00 * r01 + a01 * r11 + a02 * r21
			world[w + 2] = a00 * r02 + a01 * r12 + a02 * r22
			world[w + 3] = a00 * tx + a01 * ty + a02 * tz + a03
			world[w + 4] = a10 * r00 + a11 * r10 + a12 * r20
			world[w + 5] = a10 * r01 + a11 * r11 + a12 * r21
			world[w + 6] = a10 * r02 + a11 * r12 + a12 * r22
			world[w + 7] = a10 * tx + a11 * ty + a12 * tz + a13
			world[w + 8] = a20 * r00 + a21 * r10 + a22 * r20
			world[w + 9] = a20 * r01 + a21 * r11 + a22 * r21
			world[w + 10] = a20 * r02 + a21 * r12 + a22 * r22
			world[w + 11] = a20 * tx + a21 * ty + a22 * tz + a23
		end

		if overrides and overrides.model_set[i] ~= 0 then
			ffi.copy(world + w, overrides.model_data + w, 48)
		end

		local a00, a01, a02, a03 = world[w], world[w + 1], world[w + 2], world[w + 3]
		local a10, a11, a12, a13 = world[w + 4], world[w + 5], world[w + 6], world[w + 7]
		local a20, a21, a22, a23 = world[w + 8], world[w + 9], world[w + 10], world[w + 11]
		local b00, b01, b02, b03 = inverse_bind[w], inverse_bind[w + 1], inverse_bind[w + 2], inverse_bind[w + 3]
		local b10, b11, b12, b13 = inverse_bind[w + 4], inverse_bind[w + 5], inverse_bind[w + 6], inverse_bind[w + 7]
		local b20, b21, b22, b23 = inverse_bind[w + 8], inverse_bind[w + 9], inverse_bind[w + 10], inverse_bind[w + 11]
		out[w] = a00 * b00 + a01 * b10 + a02 * b20
		out[w + 1] = a00 * b01 + a01 * b11 + a02 * b21
		out[w + 2] = a00 * b02 + a01 * b12 + a02 * b22
		out[w + 3] = a00 * b03 + a01 * b13 + a02 * b23 + a03
		out[w + 4] = a10 * b00 + a11 * b10 + a12 * b20
		out[w + 5] = a10 * b01 + a11 * b11 + a12 * b21
		out[w + 6] = a10 * b02 + a11 * b12 + a12 * b22
		out[w + 7] = a10 * b03 + a11 * b13 + a12 * b23 + a13
		out[w + 8] = a20 * b00 + a21 * b10 + a22 * b20
		out[w + 9] = a20 * b01 + a21 * b11 + a22 * b21
		out[w + 10] = a20 * b02 + a21 * b12 + a22 * b22
		out[w + 11] = a20 * b03 + a21 * b13 + a22 * b23 + a23
	end
end

return Skeleton
