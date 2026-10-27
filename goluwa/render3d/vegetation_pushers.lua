local ffi = require("ffi")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local physics = import("goluwa/physics.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local vegetation_pushers = {}
vegetation_pushers.MAX = 16
vegetation_pushers.RANGE = 40
vegetation_pushers.MIN_RADIUS = 0.1
vegetation_pushers.BOX_ROUNDING = 0.05
local MAX = vegetation_pushers.MAX
local BOX_ROUNDING = vegetation_pushers.BOX_ROUNDING
local RANGE_SQUARED = vegetation_pushers.RANGE ^ 2
local FLOATS = 4 * (1 + MAX * 2)
local data = ffi.new("float[?]", FLOATS)
local distances = {}
local picked = {}
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

	local alpha = physics.GetInterpolationAlpha()
	data[0] = count

	for i = 1, count do
		local body = picked[i]
		local position = body:GetInterpolatedPosition(alpha)
		local half = body:GetHalfExtents()
		local o = i * 8 - 4
		local shape_type = body:GetShapeType()
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
		picked[i] = nil
	end

	ffi.copy(buffer:Map(), data, FLOATS * 4)
end)

return vegetation_pushers
