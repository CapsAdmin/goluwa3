local ffi = require("ffi")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local animation_bank = import("goluwa/render3d/animation_bank.lua")
local animation_retarget = {}
local POSE_SIZE = 7
local MIN_GROUND_SPEED = 0.3
local MIN_MAPPED_BONES = 20
local bone_map = {
	["DEF-hips"] = "Pelvis",
	["DEF-spine.001"] = "Spine",
	["DEF-spine.002"] = "Spine1",
	["DEF-spine.003"] = "Spine2",
	["DEF-neck"] = "Neck1",
	["DEF-head"] = "Head1",
}
local FINGERS = {
	thumb = "Finger0",
	f_index = "Finger1",
	f_middle = "Finger2",
	f_ring = "Finger3",
	f_pinky = "Finger4",
}

for side in ("LR"):gmatch(".") do
	bone_map["DEF-shoulder." .. side] = side .. "_Clavicle"
	bone_map["DEF-upper_arm." .. side] = side .. "_UpperArm"
	bone_map["DEF-forearm." .. side] = side .. "_Forearm"
	bone_map["DEF-hand." .. side] = side .. "_Hand"
	bone_map["DEF-thigh." .. side] = side .. "_Thigh"
	bone_map["DEF-shin." .. side] = side .. "_Calf"
	bone_map["DEF-foot." .. side] = side .. "_Foot"
	bone_map["DEF-toe." .. side] = side .. "_Toe0"

	for rigify, source in pairs(FINGERS) do
		for joint = 1, 3 do
			bone_map[string.format("DEF-%s.%02d.%s", rigify, joint, side)] = side .. "_" .. source .. (joint == 1 and "" or joint - 1)
		end
	end
end

for rigify, source in pairs(bone_map) do
	bone_map[rigify] = "ValveBiped.Bip01_" .. source
end

animation_retarget.ValveBiped = {
	bones = bone_map,
	hips = "DEF-hips",
	feet = {"DEF-foot.L", "DEF-foot.R"},
	toes = {"DEF-toe.L", "DEF-toe.R"},
	aim = {
		["DEF-hand.L"] = "DEF-f_middle.01.L",
		["DEF-hand.R"] = "DEF-f_middle.01.R",
	},
	chain = {
		source = {"DEF-hips", "DEF-spine.001", "DEF-spine.002", "DEF-spine.003", "DEF-neck"},
		target = {
			"ValveBiped.Bip01_Pelvis",
			"ValveBiped.Bip01_Spine",
			"ValveBiped.Bip01_Spine1",
			"ValveBiped.Bip01_Spine2",
			"ValveBiped.Bip01_Spine4",
			"ValveBiped.Bip01_Neck1",
		},
	},
	align = function(name)
		return name:find("^DEF%-upper_arm") or
			name:find("^DEF%-forearm") or
			name:find("^DEF%-hand") or
			name:find("^DEF%-f_") or
			name:find("^DEF%-thumb")
	end,
}

do
	local SOURCE = "ValveBiped.Bip01_"
	local bones = {
		[SOURCE .. "Pelvis"] = "pelvis",
		[SOURCE .. "Spine"] = "spine_0",
		[SOURCE .. "Spine1"] = "spine_1",
		[SOURCE .. "Spine2"] = "spine_2",
		[SOURCE .. "Spine4"] = "spine_3",
		[SOURCE .. "Neck1"] = "neck_0",
		[SOURCE .. "Head1"] = "head",
	}
	local FINGERS = {
		Finger0 = "thumb",
		Finger1 = "index",
		Finger2 = "middle",
		Finger3 = "ring",
		Finger4 = "pinky",
	}

	for _, side in ipairs{"L", "R"} do
		bones[SOURCE .. side .. "_Clavicle"] = "clavicle_" .. side
		bones[SOURCE .. side .. "_UpperArm"] = "arm_upper_" .. side
		bones[SOURCE .. side .. "_Forearm"] = "arm_lower_" .. side
		bones[SOURCE .. side .. "_Hand"] = "hand_" .. side
		bones[SOURCE .. side .. "_Thigh"] = "leg_upper_" .. side
		bones[SOURCE .. side .. "_Calf"] = "leg_lower_" .. side
		bones[SOURCE .. side .. "_Foot"] = "ankle_" .. side
		bones[SOURCE .. side .. "_Toe0"] = "ball_" .. side

		for source, target in pairs(FINGERS) do
			for joint = 0, 2 do
				bones[SOURCE .. side .. "_" .. source .. (joint == 0 and "" or joint)] = "finger_" .. target .. "_" .. joint .. "_" .. side
			end
		end
	end

	animation_retarget.ValveBipedToAlyx = {
		lateral_forward = true,
		reference = {
			source = "idle_all_01",
			hips = SOURCE .. "Pelvis",
			head = SOURCE .. "Head1",
			compare = {
				SOURCE .. "R_UpperArm",
				SOURCE .. "R_Forearm",
				SOURCE .. "R_Hand",
				SOURCE .. "L_UpperArm",
				SOURCE .. "L_Forearm",
				SOURCE .. "L_Hand",
				SOURCE .. "Spine2",
			},
			bind_limbs = {
				{SOURCE .. "L_Thigh", SOURCE .. "L_Foot"},
				{SOURCE .. "R_Thigh", SOURCE .. "R_Foot"},
			},
		},
		bones = bones,
		hips = SOURCE .. "Pelvis",
		feet = {SOURCE .. "L_Foot", SOURCE .. "R_Foot"},
		toes = {SOURCE .. "L_Toe0", SOURCE .. "R_Toe0"},
		aim = {
			[SOURCE .. "L_Hand"] = SOURCE .. "L_Finger2",
			[SOURCE .. "R_Hand"] = SOURCE .. "R_Finger2",
		},
		chain = {
			source = {
				SOURCE .. "Pelvis",
				SOURCE .. "Spine",
				SOURCE .. "Spine1",
				SOURCE .. "Spine2",
				SOURCE .. "Spine4",
				SOURCE .. "Neck1",
			},
			target = {"pelvis", "spine_0", "spine_1", "spine_2", "spine_3", "neck_0"},
		},
		align = function(name)
			return name:find("Clavicle") or
				name:find("UpperArm") or
				name:find("Forearm") or
				name:find("Hand") or
				name:find("Finger")
		end,
	}
end

local function get_world_bind(bind, parents, count, ignore_root_translation)
	local rotations, positions = {}, {}

	for i = 0, count - 1 do
		local o = i * POSE_SIZE
		local rotation = Quat(bind[o + 3], bind[o + 4], bind[o + 5], bind[o + 6])
		local position = Vec3(bind[o], bind[o + 1], bind[o + 2])
		local parent = parents[i]

		if parent >= 0 then
			positions[i] = positions[parent] + rotations[parent]:VecMul(position)
			rotations[i] = rotations[parent] * rotation
		else
			positions[i] = ignore_root_translation and Vec3(0, 0, 0) or position
			rotations[i] = rotation
		end
	end

	return rotations, positions
end

do
	local function retarget_frame(plan, source_frame, out)
		local skeleton = plan.skeleton
		local source_parents = plan.source_parents
		local count = skeleton.BoneCount
		local parents = skeleton.parents
		local bind = skeleton.BindLocal
		local source_rotation, source_position = plan.source_rotation, plan.source_position
		local rotation, position = plan.rotation, plan.position

		for i = 0, plan.source_count - 1 do
			local o = i * POSE_SIZE
			local q = Quat(source_frame[o + 3], source_frame[o + 4], source_frame[o + 5], source_frame[o + 6])
			local parent = source_parents[i + 1]

			if parent >= 0 then
				source_position[i] = source_position[parent] + source_rotation[parent]:VecMul(Vec3(source_frame[o], source_frame[o + 1], source_frame[o + 2]))
				source_rotation[i] = source_rotation[parent] * q
			else
				source_position[i] = plan.source_root_translation and
					Vec3(source_frame[o], source_frame[o + 1], source_frame[o + 2]) or
					Vec3(0, 0, 0)
				source_rotation[i] = q
			end
		end

		for t = 0, count - 1 do
			local parent = parents[t]
			local s = plan.source_of[t]
			local o = t * POSE_SIZE
			local bind_o = t * POSE_SIZE
			local world
			local blend = plan.blend[t]

			if blend then
				local delta = (
					source_rotation[blend.a] * plan.source_bind_rotation[blend.a]:GetConjugated()
				):Interpolate(source_rotation[blend.b] * plan.source_bind_rotation[blend.b]:GetConjugated(), blend.u)

				if not plan.engine_frame then delta = plan.heading * plan.facing * delta end

				world = delta * plan.facing_inverse * (plan.rest_rotation[t] or plan.bind_rotation[t])
			elseif s then
				local delta = source_rotation[s] * plan.source_bind_rotation[s]:GetConjugated()

				if not plan.engine_frame then delta = plan.heading * plan.facing * delta end

				world = delta * plan.facing_inverse * plan.rest_rotation[t]
			elseif parent >= 0 then
				world = rotation[parent] * Quat(bind[bind_o + 3], bind[bind_o + 4], bind[bind_o + 5], bind[bind_o + 6])
			else
				world = Quat(bind[bind_o + 3], bind[bind_o + 4], bind[bind_o + 5], bind[bind_o + 6])
			end

			rotation[t] = world
			local local_position = Vec3(bind[bind_o], bind[bind_o + 1], bind[bind_o + 2])

			if t == plan.hips then
				local moved = source_position[plan.source_hips] - plan.source_bind_position[plan.source_hips]
				local target = plan.engine_frame and
					plan.bind_position[t] + moved * plan.scale or
					plan.heading:VecMul(plan.bind_position[t] + plan.facing:VecMul(moved) * plan.scale)

				if parent >= 0 then
					local_position = rotation[parent]:GetConjugated():VecMul(target - position[parent])
				else
					local_position = target
				end
			end

			position[t] = parent >= 0 and
				position[parent] + rotation[parent]:VecMul(local_position)
				or
				local_position
			local local_rotation = parent >= 0 and rotation[parent]:GetConjugated() * world or world
			out[o], out[o + 1], out[o + 2] = local_position.x, local_position.y, local_position.z
			out[o + 3], out[o + 4], out[o + 5], out[o + 6] = local_rotation.x, local_rotation.y, local_rotation.z, local_rotation.w
		end

		return position
	end

	local function bake(clip)
		local plan = clip.plan
		local source = clip.source
		local count = plan.skeleton.BoneCount
		local frames = ffi.new("float[?]", source.frame_count * count * POSE_SIZE)
		local foot_x, foot_z, foot_y = {}, {}, {}

		for f = 0, source.frame_count - 1 do
			local position = retarget_frame(
				plan,
				source.frames + f * plan.source_count * POSE_SIZE,
				frames + f * count * POSE_SIZE
			)

			for k, foot in ipairs(plan.feet) do
				foot_x[k] = foot_x[k] or {}
				foot_y[k] = foot_y[k] or {}
				foot_z[k] = foot_z[k] or {}
				foot_x[k][f], foot_y[k][f], foot_z[k][f] = position[foot].x, position[foot].y, position[foot].z
			end
		end

		local ground_speed = 0

		if source.loop and source.frame_count > 1 and #plan.feet == 2 then
			local total, steps = 0, 0

			for f = 0, source.frame_count - 2 do
				local k = (foot_y[1][f] + foot_y[1][f + 1]) < (foot_y[2][f] + foot_y[2][f + 1]) and 1 or 2
				local backward = -(
						(
							foot_x[k][f + 1] - foot_x[k][f]
						) * plan.forward.x + (
							foot_z[k][f + 1] - foot_z[k][f]
						) * plan.forward.z
					) * source.fps

				if backward > 0 then
					total = total + backward
					steps = steps + 1
				end
			end

			if steps * 2 >= source.frame_count - 1 then ground_speed = total / steps end

			if ground_speed < MIN_GROUND_SPEED then ground_speed = 0 end
		end

		clip.baked = {frames = frames, frame_count = source.frame_count, ground_speed = ground_speed}
		return clip.baked
	end

	local function sample(clip, cycle, params, out)
		local baked = clip.baked or bake(clip)
		local stride = clip.plan.skeleton.BoneCount * POSE_SIZE
		local last = baked.frame_count - 1

		if last == 0 then
			ffi.copy(out, baked.frames, stride * 4)
			return
		end

		local x = math.clamp(cycle, 0, 1) * last
		local i = math.min(math.floor(x), last - 1)
		clip.plan.skeleton:BlendPoses(baked.frames + i * stride, baked.frames + (i + 1) * stride, x - i, out)
	end

	local function get_ground_speed(clip)
		return (clip.baked or bake(clip)).ground_speed
	end

	local function build_plan(skeleton, bank, map)
		local count = skeleton.BoneCount
		local plan = {
			skeleton = skeleton,
			bank = bank,
			source_of = {},
			feet = {},
			source_count = #bank.bone_names,
			source_parents = bank.parents,
			source_root_translation = bank.root_translation,
			engine_frame = bank.engine_frame,
			source_rotation = {},
			source_position = {},
			rotation = {},
			position = {},
		}
		local mapped = 0
		local source_index = {}

		for i, name in ipairs(bank.bone_names) do
			source_index[name] = i - 1
		end

		for source_name, target_name in pairs(map.bones) do
			local t = skeleton:GetBoneIndex(target_name)

			if t and source_index[source_name] then
				plan.source_of[t] = source_index[source_name]
				mapped = mapped + 1
			end
		end

		plan.hips = skeleton:GetBoneIndex(map.bones[map.hips])
		plan.source_hips = source_index[map.hips]

		for _, foot in ipairs(map.feet) do
			plan.feet[#plan.feet + 1] = skeleton:GetBoneIndex(map.bones[foot])
		end

		if mapped < MIN_MAPPED_BONES or not plan.hips or #plan.feet ~= 2 then
			return false
		end

		if not map.lateral_forward then
			for _, toe in ipairs(map.toes) do
				if not skeleton:GetBoneIndex(map.bones[toe]) or not source_index[toe] then
					return false
				end
			end
		end

		local source_parents = {}

		for i, parent in ipairs(bank.parents) do
			source_parents[i - 1] = parent
		end

		plan.source_bind_rotation, plan.source_bind_position = get_world_bind(bank.bind, source_parents, #bank.bone_names, not bank.root_translation)
		plan.bind_rotation, plan.bind_position = get_world_bind(bank.target_reference or skeleton.BindLocal, skeleton.parents, count, false)
		plan.scale = plan.bind_position[plan.hips].y / plan.source_bind_position[plan.source_hips].y
		local source_forward, target_forward = Vec3(0, 0, 0), Vec3(0, 0, 0)

		if map.lateral_forward then
			local source_right = plan.source_bind_position[source_index[map.feet[2]]] - plan.source_bind_position[source_index[map.feet[1]]]
			local target_right = plan.bind_position[plan.feet[2]] - plan.bind_position[plan.feet[1]]
			source_forward = Vec3(source_right.z, 0, -source_right.x)
			target_forward = Vec3(target_right.z, 0, -target_right.x)
		else
			for k, foot in ipairs(map.feet) do
				local source_delta = plan.source_bind_position[source_index[map.toes[k]]] - plan.source_bind_position[source_index[foot]]
				local target_delta = plan.bind_position[skeleton:GetBoneIndex(map.bones[map.toes[k]])] - plan.bind_position[plan.feet[k]]
				source_forward = source_forward + Vec3(source_delta.x, 0, source_delta.z)
				target_forward = target_forward + Vec3(target_delta.x, 0, target_delta.z)
			end
		end

		local function yaw_of(v)
			return math.atan2(v.x, v.z)
		end

		local function yaw_quat(angle)
			return Quat(0, math.sin(angle / 2), 0, math.cos(angle / 2))
		end

		plan.forward = orientation.FORWARD_VECTOR
		plan.facing = yaw_quat(yaw_of(target_forward) - yaw_of(source_forward))
		plan.heading = yaw_quat(yaw_of(plan.forward) - yaw_of(target_forward))

		if bank.engine_frame then
			plan.facing = Quat(0, 0, 0, 1)
			plan.heading = Quat(0, 0, 0, 1)
		end

		plan.facing_inverse = plan.facing:GetConjugated()
		local target_of, children = {}, {}

		for t, s in pairs(plan.source_of) do
			target_of[s] = t
		end

		for i, parent in ipairs(bank.parents) do
			if parent >= 0 then
				children[parent] = children[parent] or {}
				table.insert(children[parent], i - 1)
			end
		end

		local swings = {}
		plan.rest_rotation = {}

		for s = 0, #bank.bone_names - 1 do
			local t = target_of[s]

			if t then
				local aim_name = map.aim[bank.bone_names[s + 1]]
				local aim = aim_name and source_index[aim_name]

				if not map.align(bank.bone_names[s + 1]) then aim_name, aim = nil, nil end

				if aim and not target_of[aim] then aim = nil end

				if not aim_name and map.align(bank.bone_names[s + 1]) then
					for _, child in ipairs(children[s] or {}) do
						if target_of[child] then
							assert(not aim, "ambiguous aim child of " .. bank.bone_names[s + 1])
							aim = child
						end
					end
				end

				if not map.align(bank.bone_names[s + 1]) or bank.target_reference then
					swings[s] = Quat(0, 0, 0, 1)
				elseif aim then
					local source_direction = plan.facing:VecMul(plan.source_bind_position[aim] - plan.source_bind_position[s]):GetNormalized()
					local target_direction = (plan.bind_position[target_of[aim]] - plan.bind_position[t]):GetNormalized()
					assert(
						source_direction:Dot(target_direction) > -0.999,
						"opposite rest directions at " .. bank.bone_names[s + 1]
					)
					local axis = target_direction:GetCross(source_direction)
					swings[s] = Quat(axis.x, axis.y, axis.z, 1 + target_direction:Dot(source_direction)):GetNormalized()
				else
					swings[s] = swings[bank.parents[s + 1]] or Quat(0, 0, 0, 1)
				end

				plan.rest_rotation[t] = swings[s] * plan.bind_rotation[t]
			end
		end

		plan.blend = {}
		local chain_ok = true

		for _, name in ipairs(map.chain.target) do
			chain_ok = chain_ok and skeleton:GetBoneIndex(name) ~= nil
		end

		for _, name in ipairs(map.chain.source) do
			chain_ok = chain_ok and source_index[name] ~= nil
		end

		if chain_ok then
			local function get_fractions(names, get_position)
				local fractions, total = {0}, 0

				for i = 2, #names do
					total = total + (get_position(names[i]) - get_position(names[i - 1])):GetLength()
					fractions[i] = total
				end

				for i = 2, #names do
					fractions[i] = fractions[i] / total
				end

				return fractions
			end

			local source_fractions = get_fractions(map.chain.source, function(name)
				return plan.source_bind_position[source_index[name]]
			end)
			local target_fractions = get_fractions(map.chain.target, function(name)
				return plan.bind_position[skeleton:GetBoneIndex(name)]
			end)

			for i, name in ipairs(map.chain.target) do
				local k = 1

				while k < #source_fractions - 1 and source_fractions[k + 1] < target_fractions[i] do
					k = k + 1
				end

				local u = (target_fractions[i] - source_fractions[k]) / (source_fractions[k + 1] - source_fractions[k])
				plan.blend[skeleton:GetBoneIndex(name)] = {
					a = source_index[map.chain.source[k]],
					b = source_index[map.chain.source[k + 1]],
					u = math.clamp(u, 0, 1),
				}
			end
		end

		return plan
	end

	function animation_retarget.AddBank(skeleton, bank, map)
		local plan = build_plan(skeleton, bank, map)

		if not plan then return false end

		local added = 0

		for _, source in ipairs(bank.clips) do
			local name = (bank.prefix or "") .. source.name:lower()

			if not skeleton.ClipsByName[name] then
				skeleton:AddClip{
					Name = name,
					Duration = (source.frame_count - 1) / source.fps,
					Loop = source.loop,
					Sample = sample,
					GetGroundSpeed = get_ground_speed,
					plan = plan,
					source = source,
				}
				added = added + 1
			end
		end

		return added
	end

	local function sample_source(clip, cycle, params, out)
		local plan = clip.plan
		ffi.copy(plan.source_pose, plan.source_skeleton.BindLocal, plan.source_count * POSE_SIZE * 4)
		clip.source_clip:Sample(cycle, params, plan.source_pose)
		retarget_frame(plan, plan.source_pose, out)
	end

	local function get_source_ground_speed(clip, params)
		return clip.source_clip:GetGroundSpeed(params) * clip.plan.scale
	end

	function animation_retarget.AddSkeleton(skeleton, source_skeleton, map)
		local source_parents = {}

		for i = 1, source_skeleton.BoneCount do
			source_parents[i] = source_skeleton.parents[i - 1]
		end

		local source_reference, target_reference = source_skeleton.BindLocal, nil
		local reference = map.reference
		local source_clip = reference and source_skeleton.ClipsByName[reference.source]
		local reference_name, source_lean

		if source_clip then
			source_reference = ffi.new("float[?]", source_skeleton.BoneCount * POSE_SIZE)
			ffi.copy(
				source_reference,
				source_skeleton.BindLocal,
				source_skeleton.BoneCount * POSE_SIZE * 4
			)
			source_clip:Sample(0, {}, source_reference)
			local _, source_positions = get_world_bind(source_reference, source_skeleton.parents, source_skeleton.BoneCount, false)
			local source_index = {}

			for i, name in ipairs(source_skeleton.BoneNames) do
				source_index[name] = i - 1
			end

			local function get_shape(positions, index_of)
				local hips = positions[index_of(reference.hips)]
				local height = (positions[index_of(reference.head)] - hips):GetLength()
				local shape = {Vec3(0, hips.y / height, 0)}

				for i, name in ipairs(reference.compare) do
					shape[i + 1] = (positions[index_of(name)] - hips) / height
				end

				return shape
			end

			local source_shape = get_shape(source_positions, function(name)
				return source_index[name]
			end)
			source_lean = (
				source_positions[source_index[reference.head]] - source_positions[source_index[reference.hips]]
			):GetNormalized()
			local target_count = skeleton.BoneCount
			local pose = ffi.new("float[?]", target_count * POSE_SIZE)

			local function get_target_index(name)
				return skeleton:GetBoneIndex(map.bones[name])
			end

			local best = math.huge

			local function consider(name, data)
				local _, positions = get_world_bind(data, skeleton.parents, target_count, false)
				local shape = get_shape(positions, get_target_index)
				local distance = 0

				for i = 1, #shape do
					distance = distance + (shape[i] - source_shape[i]):GetLength()
				end

				if distance < best then
					best, reference_name = distance, name
					target_reference = name and ffi.new("float[?]", target_count * POSE_SIZE) or nil

					if target_reference then
						ffi.copy(target_reference, data, target_count * POSE_SIZE * 4)
					end
				end
			end

			consider(nil, skeleton.BindLocal)

			for _, clip in ipairs(skeleton.Clips) do
				ffi.copy(pose, skeleton.BindLocal, target_count * POSE_SIZE * 4)
				clip:Sample(0, {}, pose)
				consider(clip.Name, pose)
			end
		end

		local limb_roots = {}

		if target_reference then
			for _, limb in ipairs(reference.bind_limbs) do
				limb_roots[skeleton:GetBoneIndex(map.bones[limb[1]])] = true
			end

			for i = 0, skeleton.BoneCount - 1 do
				local ancestor = i

				while ancestor >= 0 and not limb_roots[ancestor] do
					ancestor = skeleton.parents[ancestor]
				end

				if ancestor >= 0 then
					ffi.copy(
						target_reference + i * POSE_SIZE,
						skeleton.BindLocal + i * POSE_SIZE,
						POSE_SIZE * 4
					)
				end
			end
		end

		if target_reference then
			local rotations, positions = get_world_bind(target_reference, skeleton.parents, skeleton.BoneCount, false)
			local hips = skeleton:GetBoneIndex(map.bones[reference.hips])
			local current = (
				positions[skeleton:GetBoneIndex(map.bones[reference.head])] - positions[hips]
			):GetNormalized()
			local axis = current:GetCross(source_lean)
			local lean = Quat(axis.x, axis.y, axis.z, 1 + current:Dot(source_lean)):GetNormalized()
			local pelvis = rotations[hips]

			for i = 0, skeleton.BoneCount - 1 do
				if skeleton.parents[i] == hips and not limb_roots[i] then
					local o = i * POSE_SIZE
					local rotation = pelvis:GetConjugated() * lean * pelvis * Quat(
							target_reference[o + 3],
							target_reference[o + 4],
							target_reference[o + 5],
							target_reference[o + 6]
						)
					target_reference[o + 3], target_reference[o + 4], target_reference[o + 5], target_reference[o + 6] = rotation.x, rotation.y, rotation.z, rotation.w
				end
			end
		end

		if target_reference then
			local rotations, positions = get_world_bind(target_reference, skeleton.parents, skeleton.BoneCount, false)

			for _, limb in ipairs(reference.bind_limbs) do
				local thigh = skeleton:GetBoneIndex(map.bones[limb[1]])
				local current = (positions[skeleton:GetBoneIndex(map.bones[limb[2]])] - positions[thigh]):GetNormalized()
				local upright = Vec3(current.x, current.y, 0):GetNormalized()
				local axis = current:GetCross(upright)
				local correction = Quat(axis.x, axis.y, axis.z, 1 + current:Dot(upright)):GetNormalized()
				local parent = rotations[skeleton.parents[thigh]]
				local o = thigh * POSE_SIZE
				local rotation = parent:GetConjugated() * correction * parent * Quat(
						target_reference[o + 3],
						target_reference[o + 4],
						target_reference[o + 5],
						target_reference[o + 6]
					)
				target_reference[o + 3], target_reference[o + 4], target_reference[o + 5], target_reference[o + 6] = rotation.x, rotation.y, rotation.z, rotation.w
			end
		end

		local plan = build_plan(
			skeleton,
			{
				bone_names = source_skeleton.BoneNames,
				parents = source_parents,
				bind = source_reference,
				target_reference = target_reference,
				root_translation = true,
				engine_frame = true,
			},
			map
		)

		if not plan then return false end

		plan.source_skeleton = source_skeleton
		plan.reference_name = reference_name
		plan.source_pose = ffi.new("float[?]", plan.source_count * POSE_SIZE)

		for _, name in ipairs(source_skeleton.PoseParameterNames) do
			if not skeleton.PoseParameterRanges[name] then
				skeleton.PoseParameterNames[#skeleton.PoseParameterNames + 1] = name
				skeleton.PoseParameterRanges[name] = source_skeleton.PoseParameterRanges[name]
			end
		end

		local added = 0

		for _, source_clip in ipairs(source_skeleton.Clips) do
			if not skeleton.ClipsByName[source_clip.Name] then
				skeleton:AddClip{
					Name = source_clip.Name,
					Duration = source_clip.Duration,
					Loop = source_clip.Loop,
					Sample = sample_source,
					GetGroundSpeed = get_source_ground_speed,
					plan = plan,
					source_clip = source_clip,
				}
				added = added + 1
			end
		end

		return added
	end
end

function animation_retarget.AddBanks(skeleton)
	local added = 0

	for _, bank in ipairs(animation_bank.GetBanks()) do
		added = added + (
				animation_retarget.AddBank(skeleton, bank, animation_retarget.ValveBiped) or
				0
			)
	end

	return added
end

return animation_retarget
