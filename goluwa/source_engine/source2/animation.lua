local ffi = require("ffi")
local bit = require("bit")
local resource = import("goluwa/source_engine/source2/resource.lua")
local units = import("goluwa/source_engine/units.lua")
local animation = {}
local u16_ptr_t = ffi.typeof("const uint16_t *")
local i16_ptr_t = ffi.typeof("const int16_t *")
local f32_ptr_t = ffi.typeof("const float *")
local QUATERNION_SCALE = 0.70710677 / 16384
local SCALE = units.meters

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

-- source (x, y, z) in inches is engine (-y, z, -x) in meters, a proper rotation, so quaternions swap axes the same way
local function write_engine_pose(position, rotation, out, offset)
	out[offset], out[offset + 1], out[offset + 2] = -position[2] * SCALE, position[3] * SCALE, -position[1] * SCALE
	out[offset + 3], out[offset + 4], out[offset + 5], out[offset + 6] = -rotation[2], rotation[3], -rotation[1], rotation[4]
end

-- the model's bones (1 based, parent 0 for roots). Cloth bones are roots in the file: cloth_parents (0 based bone to 0 based bone) makes each a child of the animated bone it rigidly follows, keeping its bind pose in the model
function animation.ReadBones(model_data, cloth_parents)
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

	if cloth_parents then
		local bind = model_space(bones, bones)

		for child, parent in pairs(cloth_parents) do
			local c, p = bind[child + 1], bind[parent + 1]
			local inverse = {p.rotation[1] * -1, p.rotation[2] * -1, p.rotation[3] * -1, p.rotation[4]}
			local x, y, z = mat_vec(quat_matrix(inverse), c.x - p.x, c.y - p.y, c.z - p.z)
			local bone = bones[child + 1]
			bone.parent = parent + 1
			bone.position = {x / p.scale, y / p.scale, z / p.scale}
			bone.rotation = quat_mul(inverse, c.rotation)
		end
	end

	return bones
end

-- the bones a model's skin needs: the ones its vertices are weighted to and their ancestors, in skeleton order
function animation.GetKeptBones(bones, used)
	local keep = {}

	for bone in pairs(used) do
		bone = bone + 1

		while bone > 0 and not keep[bone] do
			keep[bone] = true
			bone = bones[bone].parent
		end
	end

	local kept, new_index = {}, {}

	for bone = 1, #bones do
		if keep[bone] then
			kept[#kept + 1] = bone - 1
			new_index[bone - 1] = #kept - 1
			assert(bones[bone].parent < bone, "source 2 bones are not ordered parent first")
		end
	end

	return kept, new_index
end

-- engine axes as source axis and sign: x = -y, y = z, z = -x
local AXES = {{2, -1}, {3, 1}, {1, -1}}

-- engine skeleton data for the kept bones: names, parents, local bind poses and inverse model bind matrices (3x4, row major)
function animation.GetBindData(bones, kept, new_index)
	local bind = model_space(bones, bones)
	local names, parents = {}, {}
	local bind_local = ffi.new("float[?]", #kept * 7)
	local inverse_bind = ffi.new("float[?]", #kept * 12)

	for k, bone_index in ipairs(kept) do
		local bone = bones[bone_index + 1]
		names[k] = bone.name
		parents[k] = bone.parent > 0 and new_index[bone.parent - 1] or -1
		write_engine_pose(bone.position, bone.rotation, bind_local, (k - 1) * 7)
		local b = bind[bone_index + 1]
		local m = b.matrix
		local inv_scale = 1 / b.scale
		local r = {
			m[1] * inv_scale,
			m[4] * inv_scale,
			m[7] * inv_scale,
			m[2] * inv_scale,
			m[5] * inv_scale,
			m[8] * inv_scale,
			m[3] * inv_scale,
			m[6] * inv_scale,
			m[9] * inv_scale,
		}
		local t = {mat_vec(r, b.x, b.y, b.z)}
		local o = (k - 1) * 12

		for row = 1, 3 do
			local source_row, sign = AXES[row][1], AXES[row][2]

			for column = 1, 3 do
				inverse_bind[o + (row - 1) * 4 + column - 1] = sign * AXES[column][2] * r[(source_row - 1) * 3 + AXES[column][1]]
			end

			inverse_bind[o + (row - 1) * 4 + 3] = -sign * t[source_row] * SCALE
		end
	end

	return names, parents, bind_local, inverse_bind
end

-- the model's sequences that play one non delta animation: name, animation index, fps, frame count and looping
function animation.GetClips(res)
	local sequences = resource.ReadKV3(res, "ASEQ")
	local animations = resource.ReadKV3(res, "ANIM").m_animArray
	local by_name = {}
	local clips = {}

	for i, anim in ipairs(animations) do
		by_name[anim.m_name:lower()] = i
	end

	for i, sequence in ipairs(sequences.m_localS1SeqDescArray) do
		local reference = sequence.m_fetch.m_localReferenceArray[1]
		local name = reference and sequences.m_localSequenceNameArray[reference + 1]
		local index = name and by_name[name:lower()]

		if
			index and
			not animations[index].m_flags.m_bDelta and
			animations[index].m_pData.m_nFrames > 0
		then
			local anim = animations[index]
			clips[#clips + 1] = {
				name = sequence.m_sName,
				animation = index,
				fps = anim.fps,
				frame_count = anim.m_pData.m_nFrames,
				loop = anim.m_flags.m_bLooping,
			}
		end
	end

	return clips
end

local Decoder = {}
Decoder.__index = Decoder

-- reads single frames of a model's animations as engine local poses of the kept bones
function animation.NewDecoder(res, bones, kept)
	local anim_data = resource.ReadKV3(res, "ANIM")
	local decoder_names = {}
	local pose = {}

	for i, decoder in ipairs(anim_data.m_decoderArray) do
		decoder_names[i - 1] = decoder.m_szName
	end

	for i in ipairs(bones) do
		pose[i] = {}
	end

	return setmetatable(
		{
			bones = bones,
			kept = kept,
			anim_data = anim_data,
			decoder_names = decoder_names,
			channels = build_channels(resource.ReadKV3(res, "AGRP").m_decodeKey, bones),
			pose = pose,
		},
		Decoder
	)
end

function Decoder:ReadFrame(animation_index, frame, out)
	local pose, bones = self.pose, self.bones

	for i, bone in ipairs(bones) do
		local p = pose[i]
		p.position, p.rotation, p.scale = bone.position, bone.rotation, bone.scale
	end

	local anim = self.anim_data.m_animArray[animation_index]

	for _, block in ipairs(anim.m_pData.m_frameblockArray) do
		if frame >= block.m_nStartFrame and frame <= block.m_nEndFrame then
			for _, segment_index in ipairs(block.m_segmentIndexArray) do
				read_segment(
					self.anim_data.m_segmentArray[segment_index + 1],
					self.decoder_names,
					self.channels,
					pose,
					frame - block.m_nStartFrame
				)
			end
		end
	end

	for k, bone_index in ipairs(self.kept) do
		local p = pose[bone_index + 1]
		write_engine_pose(p.position, p.rotation, out, (k - 1) * 7)
	end
end

-- the cloth (finite element) model of a vphys: node count, per node mass, gravity and animation attraction, distance rods and the animated bones each node is attached to
function animation.ReadCloth(model_data, fe)
	local skeleton = model_data.m_modelSkeleton
	local bone_of = {}

	for i, name in ipairs(skeleton.m_boneName) do
		bone_of[name] = i - 1
	end

	local names = fe.m_CtrlName
	local count = fe.m_nNodeCount
	local cloth = {
		count = count,
		node_bone = {},
		inv_mass = fe.m_NodeInvMasses,
		attraction = {},
		gravity = {},
		rods = fe.m_Rods,
		targets = {},
		parents = {},
		target_bones = {},
	}
	local entries = {}

	for node = 0, count - 1 do
		cloth.node_bone[node] = bone_of[names[node + 1]]
		local integrator = fe.m_NodeIntegrator[node + 1]
		cloth.attraction[node] = integrator.flAnimationVertexAttraction
		cloth.gravity[node] = integrator.flGravity * SCALE
		entries[node] = {}
	end

	local function add_target(node, parent_name, offset, alpha)
		local bone = bone_of[parent_name]
		local list = entries[node]
		list[#list + 1] = {
			bone = bone,
			x = -offset[2] * SCALE,
			y = offset[3] * SCALE,
			z = -offset[1] * SCALE,
			alpha = alpha,
		}
		cloth.target_bones[bone] = true
	end

	for _, offset in ipairs(fe.m_CtrlOffsets) do
		local child = bone_of[names[offset.nCtrlChild + 1]]
		local parent = bone_of[names[offset.nCtrlParent + 1]]

		if child and parent and skeleton.m_nParent[child + 1] < 0 then
			cloth.parents[child] = parent
		end

		cloth.rigid = cloth.rigid or {}
		cloth.rigid[offset.nCtrlChild] = {names[offset.nCtrlParent + 1], offset.vOffset}
	end

	local soft_count = {}

	for _, offset in ipairs(fe.m_CtrlSoftOffsets) do
		add_target(offset.nCtrlChild, names[offset.nCtrlParent + 1], offset.vOffset, offset.flAlpha)
		soft_count[offset.nCtrlChild] = true
	end

	for node = 0, count - 1 do
		if not soft_count[node] then
			local rigid = cloth.rigid and cloth.rigid[node]

			if rigid then
				add_target(node, rigid[1], rigid[2], 1)
			elseif cloth.node_bone[node] then
				add_target(node, names[node + 1], {0, 0, 0}, 1)
			end
		end
	end

	cloth.entries = entries
	cloth.bends = {}

	-- an axial edge is two strips of three nodes in a line (node 1 and 2 are the middles, 3 and 5, 4 and 6 the ends)
	for _, edge in ipairs(fe.m_AxialEdges) do
		local n = edge.nNode

		for _, ends in ipairs{{n[3], n[5]}, {n[4], n[6]}} do
			local a, b = fe.m_InitPose[ends[1] + 1], fe.m_InitPose[ends[2] + 1]
			cloth.bends[#cloth.bends + 1] = {
				ends[1],
				ends[2],
				math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) * SCALE,
			}
		end
	end

	cloth.capsules = {}

	for _, capsule in ipairs(fe.m_TaperedCapsuleRigids) do
		local bone = bone_of[names[capsule.nNode + 1]]

		if bone then
			local a, b = capsule.vCenter[1], capsule.vCenter[2]
			cloth.capsules[#cloth.capsules + 1] = {
				bone = bone,
				points = {
					-a[2] * SCALE,
					a[3] * SCALE,
					-a[1] * SCALE,
					-b[2] * SCALE,
					b[3] * SCALE,
					-b[1] * SCALE,
				},
				radii = {capsule.flRadius[1] * SCALE, capsule.flRadius[2] * SCALE},
			}
			cloth.target_bones[bone] = true
		end
	end

	return cloth
end

-- the cloth as flat arrays for the kept bones (bone indices are engine skeleton indices, -1 for none)
function animation.PackCloth(cloth, new_index)
	local count = cloth.count
	local node_bone = ffi.new("int32_t[?]", count)
	local inv_mass = ffi.new("float[?]", count)
	local attraction = ffi.new("float[?]", count)
	local gravity = ffi.new("float[?]", count)
	local target_start = ffi.new("int32_t[?]", count + 1)
	local targets = 0

	for node = 0, count - 1 do
		node_bone[node] = cloth.node_bone[node] and new_index[cloth.node_bone[node]] or -1
		inv_mass[node] = cloth.inv_mass[node + 1]
		attraction[node] = cloth.attraction[node]
		gravity[node] = cloth.gravity[node]
		target_start[node] = targets
		targets = targets + #cloth.entries[node]
	end

	target_start[count] = targets
	local target_bone = ffi.new("int32_t[?]", targets)
	local target_offset = ffi.new("float[?]", targets * 3)
	local target_alpha = ffi.new("float[?]", targets)
	local k = 0

	for node = 0, count - 1 do
		for _, entry in ipairs(cloth.entries[node]) do
			target_bone[k] = new_index[entry.bone]
			target_offset[k * 3], target_offset[k * 3 + 1], target_offset[k * 3 + 2] = entry.x, entry.y, entry.z
			target_alpha[k] = entry.alpha
			k = k + 1
		end
	end

	local rod_count = #cloth.rods
	local rod_nodes = ffi.new("int32_t[?]", rod_count * 2)
	local rod_limits = ffi.new("float[?]", rod_count * 2)

	for i, rod in ipairs(cloth.rods) do
		rod_nodes[(i - 1) * 2], rod_nodes[(i - 1) * 2 + 1] = rod.nNode[1], rod.nNode[2]
		rod_limits[(i - 1) * 2], rod_limits[(i - 1) * 2 + 1] = rod.flMinDist * SCALE, rod.flMaxDist * SCALE
	end

	local bend_count = #cloth.bends
	local bend_nodes = ffi.new("int32_t[?]", math.max(bend_count * 2, 1))
	local bend_rest = ffi.new("float[?]", math.max(bend_count, 1))

	for i, bend in ipairs(cloth.bends) do
		bend_nodes[(i - 1) * 2], bend_nodes[(i - 1) * 2 + 1] = bend[1], bend[2]
		bend_rest[i - 1] = bend[3]
	end

	local capsule_count = #cloth.capsules
	local capsule_bone = ffi.new("int32_t[?]", math.max(capsule_count, 1))
	local capsule_points = ffi.new("float[?]", math.max(capsule_count * 6, 1))
	local capsule_radius = ffi.new("float[?]", math.max(capsule_count * 2, 1))

	for i, capsule in ipairs(cloth.capsules) do
		capsule_bone[i - 1] = new_index[capsule.bone]

		for k = 1, 6 do
			capsule_points[(i - 1) * 6 + k - 1] = capsule.points[k]
		end

		capsule_radius[(i - 1) * 2], capsule_radius[(i - 1) * 2 + 1] = capsule.radii[1], capsule.radii[2]
	end

	return {
		count = count,
		target_count = targets,
		rod_count = rod_count,
		bend_count = bend_count,
		capsule_count = capsule_count,
		arrays = {
			bend_nodes = bend_nodes,
			bend_rest = bend_rest,
			capsule_bone = capsule_bone,
			capsule_points = capsule_points,
			capsule_radius = capsule_radius,
			node_bone = node_bone,
			inv_mass = inv_mass,
			attraction = attraction,
			gravity = gravity,
			target_start = target_start,
			target_bone = target_bone,
			target_offset = target_offset,
			target_alpha = target_alpha,
			rod_nodes = rod_nodes,
			rod_limits = rod_limits,
		},
	}
end

-- the model bone a mesh's local bone index refers to
function animation.GetMeshBones(model_data, mesh_index)
	local starts, remap = model_data.m_remappingTableStarts, model_data.m_remappingTable
	local first = starts[mesh_index + 1]
	local count = (starts[mesh_index + 2] or #remap) - first
	local bones = {}

	for i = 0, count - 1 do
		bones[i] = remap[first + i + 1]
	end

	return bones
end

return animation
