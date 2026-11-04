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
	local function bake(clip)
		local plan = clip.plan
		local skeleton = plan.skeleton
		local source = clip.source
		local source_count = #plan.bank.bone_names
		local source_parents = plan.bank.parents
		local count = skeleton.BoneCount
		local parents = skeleton.parents
		local frames = ffi.new("float[?]", source.frame_count * count * POSE_SIZE)
		local source_rotation, source_position = {}, {}
		local rotation, position = {}, {}
		local foot_x, foot_z, foot_y = {}, {}, {}

		for f = 0, source.frame_count - 1 do
			for i = 0, source_count - 1 do
				local o = (f * source_count + i) * POSE_SIZE
				local q = Quat(source.frames[o + 3], source.frames[o + 4], source.frames[o + 5], source.frames[o + 6])
				local parent = source_parents[i + 1]

				if parent >= 0 then
					source_position[i] = source_position[parent] + source_rotation[parent]:VecMul(Vec3(source.frames[o], source.frames[o + 1], source.frames[o + 2]))
					source_rotation[i] = source_rotation[parent] * q
				else
					source_position[i] = Vec3(0, 0, 0)
					source_rotation[i] = q
				end
			end

			for t = 0, count - 1 do
				local parent = parents[t]
				local s = plan.source_of[t]
				local o = (f * count + t) * POSE_SIZE
				local bind_o = t * POSE_SIZE
				local bind = skeleton.BindLocal
				local world
				local blend = plan.blend[t]

				if blend then
					world = plan.heading * plan.facing * (
							source_rotation[blend.a] * plan.source_bind_rotation[blend.a]:GetConjugated()
						):Interpolate(source_rotation[blend.b] * plan.source_bind_rotation[blend.b]:GetConjugated(), blend.u) * plan.facing_inverse * (
							plan.rest_rotation[t] or
							plan.bind_rotation[t]
						)
				elseif s then
					world = plan.heading * plan.facing * (
							source_rotation[s] * plan.source_bind_rotation[s]:GetConjugated()
						) * plan.facing_inverse * plan.rest_rotation[t]
				elseif parent >= 0 then
					world = rotation[parent] * Quat(bind[bind_o + 3], bind[bind_o + 4], bind[bind_o + 5], bind[bind_o + 6])
				else
					world = Quat(bind[bind_o + 3], bind[bind_o + 4], bind[bind_o + 5], bind[bind_o + 6])
				end

				rotation[t] = world
				local local_position = Vec3(bind[bind_o], bind[bind_o + 1], bind[bind_o + 2])

				if t == plan.hips then
					local moved = source_position[plan.source_hips] - plan.source_bind_position[plan.source_hips]
					local target = plan.heading:VecMul(plan.bind_position[t] + plan.facing:VecMul(moved) * plan.scale)

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
				frames[o], frames[o + 1], frames[o + 2] = local_position.x, local_position.y, local_position.z
				frames[o + 3], frames[o + 4], frames[o + 5], frames[o + 6] = local_rotation.x, local_rotation.y, local_rotation.z, local_rotation.w
			end

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

	function animation_retarget.AddBank(skeleton, bank, map)
		local count = skeleton.BoneCount
		local plan = {
			skeleton = skeleton,
			bank = bank,
			source_of = {},
			feet = {},
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

		for _, toe in ipairs(map.toes) do
			if not skeleton:GetBoneIndex(map.bones[toe]) or not source_index[toe] then
				return false
			end
		end

		local source_parents = {}

		for i, parent in ipairs(bank.parents) do
			source_parents[i - 1] = parent
		end

		plan.source_bind_rotation, plan.source_bind_position = get_world_bind(bank.bind, source_parents, #bank.bone_names, true)
		plan.bind_rotation, plan.bind_position = get_world_bind(skeleton.BindLocal, skeleton.parents, count, false)
		plan.scale = plan.bind_position[plan.hips].y / plan.source_bind_position[plan.source_hips].y
		local source_forward, target_forward = Vec3(0, 0, 0), Vec3(0, 0, 0)

		for k, foot in ipairs(map.feet) do
			local source_delta = plan.source_bind_position[source_index[map.toes[k]]] - plan.source_bind_position[source_index[foot]]
			local target_delta = plan.bind_position[skeleton:GetBoneIndex(map.bones[map.toes[k]])] - plan.bind_position[plan.feet[k]]
			source_forward = source_forward + Vec3(source_delta.x, 0, source_delta.z)
			target_forward = target_forward + Vec3(target_delta.x, 0, target_delta.z)
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

				if not map.align(bank.bone_names[s + 1]) then
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
