local ffi = require("ffi")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local vegetation_pushers = {}
vegetation_pushers.MAX = 16
vegetation_pushers.RANGE = 40
vegetation_pushers.MIN_RADIUS = 0.1
vegetation_pushers.BOX_ROUNDING = 0.05
vegetation_pushers.POSES = 6
vegetation_pushers.POSE_INTERVAL = 0.07
vegetation_pushers.FREQUENCY = 2.5
vegetation_pushers.DAMPING = 0.3
vegetation_pushers.STRIDE = 2 + vegetation_pushers.POSES
local POSES = vegetation_pushers.POSES
local STRIDE = vegetation_pushers.STRIDE
local HISTORY = 128
local MAX = vegetation_pushers.MAX
local BOX_ROUNDING = vegetation_pushers.BOX_ROUNDING
local RANGE_SQUARED = vegetation_pushers.RANGE ^ 2
local FLOATS = 4 * (1 + MAX * STRIDE)
local data = ffi.new("float[?]", FLOATS)
local distances = {}
local picked = {}
local weights = {}
local histories = setmetatable({}, {__mode = "k"})
local buffer
local address_low, address_high = 0, 0

function vegetation_pushers.GetAddress()
	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = FLOATS * 4,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "vegetation_pushers",
		}
		local address = ffi.cast("uint64_t", buffer:GetDeviceAddress())
		address_low = tonumber(ffi.cast("int32_t", address))
		address_high = tonumber(ffi.cast("int32_t", address / 4294967296ULL))
		ffi.copy(buffer:Map(), data, FLOATS * 4)
	end

	return address_low, address_high
end

function vegetation_pushers.GetData()
	return data
end

event.AddListener("LateUpdate", "vegetation_pushers", function()
	if not buffer then return end

	local camera = render3d.GetCamera():GetPosition()
	local cx, cy, cz = camera.x, camera.y, camera.z
	local bodies = RigidBody.Instances
	local min_radius = vegetation_pushers.MIN_RADIUS
	local count = 0

	for i = 1, #bodies do
		local body = bodies[i]

		if body.MotionType ~= "static" then
			local position = body.Position
			local dx, dy, dz = position.x - cx, position.y - cy, position.z - cz
			local distance = dx * dx + dy * dy + dz * dz

			if distance < RANGE_SQUARED and (count < MAX or distance < distances[count]) then
				local half = body:GetHalfExtents()

				if math.max(half.x, half.z) >= min_radius then
					local at = count < MAX and count + 1 or MAX

					while at > 1 and distances[at - 1] > distance do
						distances[at] = distances[at - 1]
						picked[at] = picked[at - 1]
						at = at - 1
					end

					distances[at] = distance
					picked[at] = body

					if count < MAX then count = count + 1 end
				end
			end
		end
	end

	local now = system.GetElapsedTime()
	local interval = vegetation_pushers.POSE_INTERVAL
	local omega = 2 * math.pi * vegetation_pushers.FREQUENCY
	local damping = vegetation_pushers.DAMPING
	local damped = omega * math.sqrt(1 - damping * damping)
	local decay = damping * omega
	local total = 0
	local previous_step = 0

	for j = 0, POSES - 1 do
		local t = (j + 0.5) * interval
		local step = 1 - math.exp(-decay * t) * (
				math.cos(damped * t) + decay / damped * math.sin(damped * t)
			)
		weights[j] = step - previous_step
		total = total + weights[j]
		previous_step = step
	end

	local alpha = physics.GetInterpolationAlpha()
	data[0] = count

	for i = 1, count do
		local body = picked[i]
		local position = body:GetInterpolatedPosition(alpha)
		local half = body:GetHalfExtents()
		local o = (i - 1) * STRIDE * 4 + 4
		local shape_type = body:GetShapeType()
		local history = histories[body]

		if not history then
			history = {head = 0, count = 0, time = {}, x = {}, y = {}, z = {}}
			histories[body] = history
		end

		local head = history.head

		if history.count > 0 and now - history.time[head] > POSES * interval then
			history.count = 0
		end

		head = head % HISTORY + 1
		history.head = head
		history.count = math.min(history.count + 1, HISTORY)
		history.time[head] = now
		history.x[head] = position.x
		history.y[head] = position.y
		history.z[head] = position.z
		data[o] = position.x
		data[o + 1] = position.y
		data[o + 2] = position.z
		data[o + 3] = (
				shape_type == "sphere" or
				shape_type == "capsule"
			)
			and
			math.max(half.x, half.z) or
			BOX_ROUNDING
		data[o + 4] = half.x
		data[o + 5] = half.y
		data[o + 6] = half.z
		data[o + 7] = 0

		for j = 0, POSES - 1 do
			local target = now - j * interval
			local newer = head
			local x, y, z = history.x[newer], history.y[newer], history.z[newer]

			for _ = 2, history.count do
				if history.time[newer] <= target then break end

				local older = (newer - 2) % HISTORY + 1
				local t0, t1 = history.time[older], history.time[newer]

				if t0 <= target then
					local f = (target - t0) / (t1 - t0)
					x = history.x[older] + (history.x[newer] - history.x[older]) * f
					y = history.y[older] + (history.y[newer] - history.y[older]) * f
					z = history.z[older] + (history.z[newer] - history.z[older]) * f

					break
				end

				newer = older
				x, y, z = history.x[older], history.y[older], history.z[older]
			end

			local q = o + 8 + j * 4
			data[q] = x
			data[q + 1] = y
			data[q + 2] = z
			data[q + 3] = weights[j] / total
		end

		picked[i] = nil
	end

	ffi.copy(buffer:Map(), data, FLOATS * 4)
end)

return vegetation_pushers
