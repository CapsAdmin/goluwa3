local ffi = require("ffi")
local cgf = import("lua/crysis_loader/cgf.lua")
local animation_bank = import("goluwa/render3d/animation_bank.lua")
local caf = {}
caf.CHUNK_CONTROLLER = 0xCCCC000D
caf.CHUNK_TIMING = 0xCCCC000E
caf.CONTROLLER_PQ_LOG = 0x827
local Floats = ffi.typeof("float[?]")

function caf.Parse(data)
	local parsed = cgf.OpenData(data)
	local file = parsed.file
	local out = {controllers = {}}

	for _, chunk in ipairs(parsed.chunks) do
		if chunk.type == caf.CHUNK_TIMING then
			file:PushPosition(chunk.offset + 16)
			out.seconds_per_tick = file:ReadFloat()
			out.ticks_per_frame = file:ReadI32()
			file:Advance(32)
			out.first_frame = file:ReadI32()
			out.last_frame = file:ReadI32()
			file:PopPosition()
		elseif chunk.type == caf.CHUNK_CONTROLLER then
			if chunk.version ~= caf.CONTROLLER_PQ_LOG then
				error(string.format("unsupported caf controller version 0x%X", chunk.version))
			end

			file:PushPosition(chunk.offset)
			local key_count = file:ReadU32()
			local controller = {times = {}, keys = {}}
			out.controllers[file:ReadU32()] = controller

			for i = 1, key_count do
				controller.times[i] = file:ReadI32()
				local px, py, pz = file:ReadFloat(), file:ReadFloat(), file:ReadFloat()
				local lx, ly, lz = file:ReadFloat(), file:ReadFloat(), file:ReadFloat()
				local angle = math.sqrt(lx * lx + ly * ly + lz * lz)
				-- the keys store the log of the inverse rotation
				local s = angle > 0 and -math.sin(angle) / angle or 0
				local o = (i - 1) * 7
				local keys = controller.keys
				keys[o + 1], keys[o + 2], keys[o + 3] = px / 100, pz / 100, -py / 100
				keys[o + 4], keys[o + 5], keys[o + 6], keys[o + 7] = lx * s, lz * s, -ly * s, math.cos(angle)
			end

			file:PopPosition()
		end
	end

	assert(out.ticks_per_frame, "caf has no timing chunk")
	return out
end

function caf.AddClip(skeleton, controller_ids, name, animation)
	local count = skeleton.BoneCount
	local stride = count * 7
	local frame_count = math.max(animation.last_frame - animation.first_frame + 1, 1)
	local frames = Floats(frame_count * stride)

	for frame = 0, frame_count - 1 do
		ffi.copy(frames + frame * stride, skeleton.BindLocal, stride * 4)
	end

	for bone = 1, count do
		local controller = animation.controllers[controller_ids[bone]]

		if controller then
			local times, keys = controller.times, controller.keys
			local last = #times
			local k = 1

			for frame = 0, frame_count - 1 do
				local tick = (animation.first_frame + frame) * animation.ticks_per_frame

				while k < last and times[k + 1] <= tick do
					k = k + 1
				end

				local n = math.min(k + 1, last)
				local t = n ~= k and math.clamp((tick - times[k]) / (times[n] - times[k]), 0, 1) or 0
				local s = 1 - t
				local a, b = (k - 1) * 7, (n - 1) * 7
				local o = frame * stride + (bone - 1) * 7
				frames[o] = keys[a + 1] * s + keys[b + 1] * t
				frames[o + 1] = keys[a + 2] * s + keys[b + 2] * t
				frames[o + 2] = keys[a + 3] * s + keys[b + 3] * t
				local bx, by, bz, bw = keys[b + 4], keys[b + 5], keys[b + 6], keys[b + 7]

				if keys[a + 4] * bx + keys[a + 5] * by + keys[a + 6] * bz + keys[a + 7] * bw < 0 then
					bx, by, bz, bw = -bx, -by, -bz, -bw
				end

				local x, y, z, w = keys[a + 4] * s + bx * t,
				keys[a + 5] * s + by * t,
				keys[a + 6] * s + bz * t,
				keys[a + 7] * s + bw * t
				local inv = 1 / math.sqrt(x * x + y * y + z * z + w * w)
				frames[o + 3], frames[o + 4], frames[o + 5], frames[o + 6] = x * inv, y * inv, z * inv, w * inv
			end
		end
	end

	animation_bank.AddNativeClips(
		skeleton,
		{
			clips = {
				{
					name = name,
					fps = 1 / (animation.seconds_per_tick * animation.ticks_per_frame),
					frame_count = frame_count,
					loop = true,
					frames = frames,
				},
			},
		}
	)
end

return caf
