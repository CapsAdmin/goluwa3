local ffi = require("ffi")
local bit = require("bit")
local resource = import("goluwa/source_engine/source2/resource.lua")
local animation = {}
local u16_ptr_t = ffi.typeof("const uint16_t *")
local i16_ptr_t = ffi.typeof("const int16_t *")
local f32_ptr_t = ffi.typeof("const float *")
local QUATERNION_SCALE = 0.70710677 / 16384

local function half(h)
	local e = bit.band(bit.rshift(h, 10), 31)
	local m = bit.band(h, 1023)
	local s = bit.band(h, 0x8000) ~= 0 and -1 or 1

	if e == 0 then return s * m * 2 ^ -24 end

	return s * (1 + m / 1024) * 2 ^ (e - 15)
end

local function read_quaternion(words)
	local w1, w2, w3 = words[0], words[1], words[2]
	local x = bit.band(w1, 0x4000) == 0 and
		QUATERNION_SCALE * (
			bit.band(w1, 0x3FFF) - 16384
		)
		or
		QUATERNION_SCALE * bit.band(w1, 0x3FFF)
	local y = bit.band(w2, 0x4000) == 0 and
		QUATERNION_SCALE * (
			bit.band(w2, 0x3FFF) - 16384
		)
		or
		QUATERNION_SCALE * bit.band(w2, 0x3FFF)
	local z = bit.band(w3, 0x4000) == 0 and
		QUATERNION_SCALE * (
			bit.band(w3, 0x3FFF) - 16384
		)
		or
		QUATERNION_SCALE * bit.band(w3, 0x3FFF)
	local w = math.sqrt(math.max(0, 1 - x * x - y * y - z * z))

	if bit.band(w3, 0x8000) ~= 0 then w = -w end

	if bit.band(w1, 0x8000) ~= 0 then
		if bit.band(w2, 0x8000) ~= 0 then return {y, z, w, x} end

		return {z, w, x, y}
	end

	if bit.band(w2, 0x8000) ~= 0 then return {w, x, y, z} end

	return {x, y, z, w}
end

local function quat_mul(a, b)
	return {
		a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
		a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
		a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
		a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
	}
end

local function quat_matrix(q)
	local x, y, z, w = q[1], q[2], q[3], q[4]
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

local function mat_vec(m, x, y, z)
	return m[1] * x + m[2] * y + m[3] * z,
	m[4] * x + m[5] * y + m[6] * z,
	m[7] * x + m[8] * y + m[9] * z
end

local function read_skeleton(model_data)
	local skeleton = model_data.m_modelSkeleton
	local bones = {}

	for i, name in ipairs(skeleton.m_boneName) do
		local p, q = skeleton.m_bonePosParent[i], skeleton.m_boneRotParent[i]
		bones[i] = {
			name = name,
			parent = skeleton.m_nParent[i] + 1,
			position = {p[1], p[2], p[3]},
			rotation = {q[1], q[2], q[3], q[4]},
			scale = skeleton.m_boneScaleParent and skeleton.m_boneScaleParent[i] or 1,
		}
	end

	return bones
end

local CHANNEL_ATTRIBUTES = {Position = "position", Angle = "rotation", Scale = "scale"}

local function build_channels(decode_key, bones)
	local indices = {}

	for i, bone in ipairs(bones) do
		local key = bone.name:lower()

		if not indices[key] then indices[key] = i end
	end

	local channels = {}

	for i, channel in ipairs(decode_key.m_dataChannelArray) do
		local remap = {}

		for j, name in ipairs(channel.m_szElementNameArray) do
			local bone = indices[name:lower()]

			if bone and not remap[bone] then
				remap[bone] = channel.m_nElementIndexArray[j]
			end
		end

		channels[i] = {
			attribute = channel.m_szChannelClass == "BoneChannel" and
				CHANNEL_ATTRIBUTES[channel.m_szVariableName],
			remap = remap,
		}
	end

	return channels
end

-- sets one decoded value of a segment on the pose, frame is relative to the frame block
local function read_segment(segment, decoder_names, channels, pose, frame)
	local container = segment.m_container
	local words = ffi.cast(u16_ptr_t, container)
	local decoder = decoder_names[words[0]]
	local element_count = ffi.cast(i16_ptr_t, container)[2]
	local channel = channels[segment.m_nLocalChannel + 1]

	if not channel.attribute then return end

	local positions = {}

	for i = 0, element_count - 1 do
		local element = ffi.cast(i16_ptr_t, container)[4 + i]

		if element >= 0 and positions[element] == nil then positions[element] = i end
	end

	local data_offset = 8 + element_count * 2
	local data = ffi.cast("const uint8_t *", container) + data_offset
	local attribute = channel.attribute
	local frame_offset = frame * element_count

	for bone, element in pairs(channel.remap) do
		local w = positions[element]

		if w then
			local value

			if decoder == "CCompressedStaticFullVector3" then
				local f = ffi.cast(f32_ptr_t, data)
				value = {f[w * 3], f[w * 3 + 1], f[w * 3 + 2]}
			elseif decoder == "CCompressedStaticVector3" then
				local h = ffi.cast(u16_ptr_t, data)
				value = {half(h[w * 3]), half(h[w * 3 + 1]), half(h[w * 3 + 2])}
			elseif decoder == "CCompressedStaticQuaternion" then
				value = read_quaternion(ffi.cast(u16_ptr_t, data + w * 6))
			elseif decoder == "CCompressedAnimQuaternion" then
				value = read_quaternion(ffi.cast(u16_ptr_t, data + (frame_offset + w) * 6))
			elseif decoder == "CCompressedAnimVector3" then
				local h = ffi.cast(u16_ptr_t, data) + (frame_offset + w) * 3
				value = {half(h[0]), half(h[1]), half(h[2])}
			elseif decoder == "CCompressedFullVector3" then
				local f = ffi.cast(f32_ptr_t, data) + (frame_offset + w) * 3
				value = {f[0], f[1], f[2]}
			elseif decoder == "CCompressedDeltaVector3" then
				local base = ffi.cast(f32_ptr_t, data) + w * 3
				local delta = ffi.cast(u16_ptr_t, data + element_count * 12) + (frame_offset + w) * 3
				value = {base[0] + half(delta[0]), base[1] + half(delta[1]), base[2] + half(delta[2])}
			elseif decoder == "CCompressedFullQuaternion" then
				local f = ffi.cast(f32_ptr_t, data) + (frame_offset + w) * 4
				value = {f[0], f[1], f[2], f[3]}
			elseif decoder == "CCompressedStaticFloat" then
				value = ffi.cast(f32_ptr_t, data)[w]
			elseif decoder == "CCompressedFullFloat" then
				value = ffi.cast(f32_ptr_t, data)[frame_offset + w]
			end

			if value ~= nil then pose[bone][attribute] = value end
		end
	end
end

-- the index of the animation the first sequence plays, nil when the model has none or it is a delta
function animation.GetDefaultAnimation(res)
	local sequences = resource.ReadKV3(res, "ASEQ")
	local animations = resource.ReadKV3(res, "ANIM").m_animArray
	local sequence = sequences.m_localS1SeqDescArray[1]
	local reference = sequence and sequence.m_fetch.m_localReferenceArray[1]
	local name = reference and sequences.m_localSequenceNameArray[reference + 1]

	for i, anim in ipairs(animations) do
		if name and anim.m_name:lower() == name:lower() then
			if anim.m_flags.m_bDelta then return nil end

			return i
		end
	end
end

-- the pose of a frame of one of the model's animations as local bone transforms
function animation.GetPose(res, model_data, animation_index, frame)
	local bones = read_skeleton(model_data)
	local anim_data = resource.ReadKV3(res, "ANIM")
	local anim = anim_data.m_animArray[animation_index]
	local pose = {}

	for i, bone in ipairs(bones) do
		pose[i] = {position = bone.position, rotation = bone.rotation, scale = bone.scale}
	end

	local decoder_names = {}

	for i, decoder in ipairs(anim_data.m_decoderArray) do
		decoder_names[i - 1] = decoder.m_szName
	end

	local channels = build_channels(resource.ReadKV3(res, "AGRP").m_decodeKey, bones)

	for _, block in ipairs(anim.m_pData.m_frameblockArray) do
		if frame >= block.m_nStartFrame and frame <= block.m_nEndFrame then
			for _, segment_index in ipairs(block.m_segmentIndexArray) do
				read_segment(anim_data.m_segmentArray[segment_index + 1], decoder_names, channels, pose, frame - block.m_nStartFrame)
			end
		end
	end

	return bones, pose
end

local function model_space(bones, locals)
	local result = {}

	for i, bone in ipairs(bones) do
		local l = locals[i]
		local parent = result[bone.parent]
		local rotation, scale, x, y, z = l.rotation, l.scale, l.position[1], l.position[2], l.position[3]

		if parent then
			local px, py, pz = mat_vec(parent.matrix, x * parent.scale, y * parent.scale, z * parent.scale)
			rotation = quat_mul(parent.rotation, rotation)
			x, y, z = parent.x + px, parent.y + py, parent.z + pz
			scale = parent.scale * scale
		end

		result[i] = {
			rotation = rotation,
			scale = scale,
			x = x,
			y = y,
			z = z,
			matrix = quat_matrix(rotation),
		}
	end

	return result
end

-- one affine transform per bone that takes a vertex from the bind pose to the pose: v' = M v + t
function animation.BuildSkin(bones, pose)
	local bind, posed = model_space(bones, bones), model_space(bones, pose)
	local skin = {}

	for i = 1, #bones do
		local b, p = bind[i], posed[i]
		local k = p.scale / b.scale
		local bm, pm = b.matrix, p.matrix
		local m = {}

		for row = 0, 2 do
			for column = 0, 2 do
				m[row * 3 + column + 1] = k * (
						pm[row * 3 + 1] * bm[column * 3 + 1] + pm[row * 3 + 2] * bm[column * 3 + 2] + pm[row * 3 + 3] * bm[column * 3 + 3]
					)
			end
		end

		local tx, ty, tz = mat_vec(m, b.x, b.y, b.z)
		skin[i] = {m = m, x = p.x - tx, y = p.y - ty, z = p.z - tz}
	end

	return skin
end

-- the skin of the first frame of the model's default animation, nil when there is none
function animation.GetDefaultSkin(res, model_data)
	local default = animation.GetDefaultAnimation(res)

	if not default then return nil end

	return animation.BuildSkin(animation.GetPose(res, model_data, default, 0))
end

-- the skin transforms indexed by the bone index a mesh's vertices carry (0 based)
function animation.GetMeshSkin(model_data, skin, mesh_index)
	local starts, remap = model_data.m_remappingTableStarts, model_data.m_remappingTable
	local first = starts[mesh_index + 1]
	local count = (starts[mesh_index + 2] or #remap) - first
	local mesh_skin = {}

	for i = 0, count - 1 do
		mesh_skin[i] = skin[remap[first + i + 1] + 1]
	end

	return mesh_skin
end

return animation
