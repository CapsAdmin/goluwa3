local ffi = require("ffi")
local gltf = import("goluwa/codecs/gltf.lua")
local clip_bank = import("goluwa/codecs/clip_bank.lua")
local codec = import("goluwa/codec.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local animation_bank = {}
local POSE_SIZE = 7
local ANIMATIONS_DIR = "animations/"
local SCALE_TOLERANCE = 1e-3
local LOOP_POSITION_TOLERANCE = 0.01
local LOOP_ROTATION_DOT = 0.9999

function animation_bank.FromData(data, fps, prefix)
	local skin = assert(data.skins[1], "no skin in " .. data.path)
	local joint_of_node = {}
	local node_parent = {}

	for i, node in ipairs(skin.joints) do
		joint_of_node[node] = i
	end

	for i, node in ipairs(data.nodes) do
		for _, child in ipairs(node.children or {}) do
			node_parent[child] = i - 1
		end
	end

	local bone_count = #skin.joints
	local bone_names, parents = {}, {}
	local bind = ffi.new("float[?]", bone_count * POSE_SIZE)

	for i, node_index in ipairs(skin.joints) do
		local node = data.nodes[node_index + 1]
		assert(not node.matrix, "joint " .. node.name .. " uses a matrix")
		bone_names[i] = node.name
		local ancestor = node_parent[node_index]

		while ancestor and not joint_of_node[ancestor] do
			local transform = data.nodes[ancestor + 1]
			assert(
				transform.translation[1] == 0 and
					transform.translation[2] == 0 and
					transform.translation[3] == 0 and
					transform.rotation[4] == 1 and
					transform.scale[1] == 1 and
					transform.scale[2] == 1 and
					transform.scale[3] == 1,
				"transformed non joint ancestor " .. tostring(transform.name)
			)
			ancestor = node_parent[ancestor]
		end

		parents[i] = ancestor and joint_of_node[ancestor] - 1 or -1
		local o = (i - 1) * POSE_SIZE
		bind[o], bind[o + 1], bind[o + 2] = node.translation[1], node.translation[2], node.translation[3]
		bind[o + 3], bind[o + 4], bind[o + 5], bind[o + 6] = node.rotation[1], node.rotation[2], node.rotation[3], node.rotation[4]
	end

	local bank = {
		prefix = prefix,
		bone_names = bone_names,
		parents = parents,
		bind = bind,
		clips = {},
	}

	for _, animation in ipairs(data.animations) do
		local duration = 0

		for _, channel in ipairs(animation.channels) do
			local times = channel.sampler.input
			duration = math.max(duration, times.data[times.count - 1])
		end

		local frame_count = math.floor(duration * fps + 0.5) + 1
		local frames = ffi.new("float[?]", frame_count * bone_count * POSE_SIZE)

		for f = 0, frame_count - 1 do
			ffi.copy(frames + f * bone_count * POSE_SIZE, bind, bone_count * POSE_SIZE * 4)
		end

		for _, channel in ipairs(animation.channels) do
			local joint = joint_of_node[channel.node]

			if joint then
				assert(channel.sampler.interpolation == "LINEAR", animation.name .. " is not linearly interpolated")
				local times = channel.sampler.input.data
				local count = channel.sampler.input.count
				local values = channel.sampler.output.data
				local width = channel.path == "rotation" and 4 or 3
				local key = 0

				for f = 0, frame_count - 1 do
					local time = math.min(f / fps, times[count - 1])

					while key < count - 2 and times[key + 1] < time do
						key = key + 1
					end

					local span = times[key + 1] - times[key]
					local t = count == 1 and
						0 or
						(
							span > 0 and
							math.clamp((time - times[key]) / span, 0, 1) or
							0
						)
					local a = key * width
					local b = math.min(key + 1, count - 1) * width
					local o = (f * bone_count + joint - 1) * POSE_SIZE

					if channel.path == "translation" then
						for c = 0, 2 do
							frames[o + c] = values[a + c] + (values[b + c] - values[a + c]) * t
						end
					elseif channel.path == "rotation" then
						local sign = (
								values[a] * values[b] + values[a + 1] * values[b + 1] + values[a + 2] * values[b + 2] + values[a + 3] * values[b + 3]
							) < 0 and
							-1 or
							1
						local x = values[a] + (values[b] * sign - values[a]) * t
						local y = values[a + 1] + (values[b + 1] * sign - values[a + 1]) * t
						local z = values[a + 2] + (values[b + 2] * sign - values[a + 2]) * t
						local w = values[a + 3] + (values[b + 3] * sign - values[a + 3]) * t
						local inverse = 1 / math.sqrt(x * x + y * y + z * z + w * w)
						frames[o + 3], frames[o + 4], frames[o + 5], frames[o + 6] = x * inverse, y * inverse, z * inverse, w * inverse
					else
						for c = 0, 2 do
							local scale = values[a + c] + (values[b + c] - values[a + c]) * t
							assert(
								math.abs(scale - 1) < SCALE_TOLERANCE,
								animation.name .. " animates the scale of " .. bone_names[joint]
							)
						end
					end
				end
			end
		end

		local loop = true
		local last = (frame_count - 1) * bone_count * POSE_SIZE

		for bone = 0, bone_count - 1 do
			local o = bone * POSE_SIZE

			if parents[bone + 1] >= 0 then
				for c = 0, 2 do
					if math.abs(frames[o + c] - frames[last + o + c]) > LOOP_POSITION_TOLERANCE then
						loop = false
					end
				end
			end

			local dot = frames[o + 3] * frames[last + o + 3] + frames[o + 4] * frames[last + o + 4] + frames[o + 5] * frames[last + o + 5] + frames[o + 6] * frames[last + o + 6]

			if math.abs(dot) < LOOP_ROTATION_DOT then loop = false end
		end

		bank.clips[#bank.clips + 1] = {
			name = animation.name,
			fps = fps,
			frame_count = frame_count,
			loop = loop,
			frames = frames,
		}
	end

	return bank
end

function animation_bank.FromGltf(path, fps, prefix)
	return animation_bank.FromData(assert(gltf.Load(path)), fps, prefix)
end

function animation_bank.Convert(gltf_path, fps, prefix)
	local bank = animation_bank.FromGltf(gltf_path, fps, prefix)
	local out_path = gltf_path:gsub("%.[^./]+$", ".clips")
	assert(fs.write_file(out_path, clip_bank.Encode(bank)))
	return out_path, bank
end

do
	local function sample(clip, cycle, params, out)
		local last = clip.source.frame_count - 1
		local stride = clip.skeleton.BoneCount * POSE_SIZE

		if last == 0 then
			ffi.copy(out, clip.source.frames, stride * 4)
			return
		end

		local x = math.clamp(cycle, 0, 1) * last
		local i = math.min(math.floor(x), last - 1)
		clip.skeleton:BlendPoses(clip.source.frames + i * stride, clip.source.frames + (i + 1) * stride, x - i, out)
	end

	function animation_bank.AddNativeClips(skeleton, bank)
		for _, source in ipairs(bank.clips) do
			skeleton:AddClip{
				Name = source.name,
				Duration = (source.frame_count - 1) / source.fps,
				Loop = source.loop,
				Sample = sample,
				skeleton = skeleton,
				source = source,
			}
		end
	end
end

do
	local banks

	function animation_bank.GetBanks()
		if banks then return banks end

		banks = {}

		for _, name in ipairs(vfs.Find(ANIMATIONS_DIR)) do
			if name:ends_with(".clips") then
				banks[#banks + 1] = assert(codec.DecodeFile(ANIMATIONS_DIR .. name, "clip_bank"))
			end
		end

		return banks
	end
end

return animation_bank
