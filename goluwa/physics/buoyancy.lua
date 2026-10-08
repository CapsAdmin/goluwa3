local Vec3 = import("goluwa/structs/vec3.lua")
local fluid = import("goluwa/physics/fluid.lua")
local water = import("goluwa/render3d/water.lua")
local buoyancy = {}
local CELLS_PER_AXIS = 5
local ACTIVE_REGIONS = {}
local TORQUE_IMPULSE = Vec3()
local COLLIDER_OFFSET = Vec3()
local OCEAN_SAMPLE = {}

-- fills each collider with cubic-ish cells that stand in for its volume. the cell volumes are
-- normalized so they sum to the shape's volume however coarse the grid is
function buoyancy.BuildCells(body)
	local cx, cy, cz, cv = {}, {}, {}, {}
	local count = 0
	local radius = 0
	local total_volume = 0
	local spacing = 0
	local spacing_count = 0

	for _, collider in ipairs(body:GetColliders()) do
		local shape = collider:GetPhysicsShape()
		local shape_type = collider:GetShapeType()
		local hx, hy, hz
		local sphere_radius, half_segment

		if shape_type == "sphere" then
			sphere_radius = shape:GetRadius()
			hx, hy, hz = sphere_radius, sphere_radius, sphere_radius
			half_segment = 0
		elseif shape_type == "capsule" then
			sphere_radius = shape:GetRadius()
			half_segment = shape:GetCylinderHeight() / 2
			hx, hy, hz = sphere_radius, half_segment + sphere_radius, sphere_radius
		else
			local half = collider:GetHalfExtents()
			hx, hy, hz = half.x, half.y, half.z
		end

		local edge = 2 * math.max(hx, hy, hz) / CELLS_PER_AXIS
		local nx = math.max(1, math.round(2 * hx / edge))
		local ny = math.max(1, math.round(2 * hy / edge))
		local nz = math.max(1, math.round(2 * hz / edge))
		local first = count + 1

		for ix = 1, nx do
			local x = -hx + (ix - 0.5) * 2 * hx / nx

			for iy = 1, ny do
				local y = -hy + (iy - 0.5) * 2 * hy / ny

				for iz = 1, nz do
					local z = -hz + (iz - 0.5) * 2 * hz / nz
					local inside = true

					if sphere_radius then
						local dy = y - math.clamp(y, -half_segment, half_segment)
						inside = x * x + dy * dy + z * z <= sphere_radius * sphere_radius
					end

					if inside then
						count = count + 1
						cx[count], cy[count], cz[count] = x, y, z
					end
				end
			end
		end

		if count < first then
			count = count + 1
			cx[count], cy[count], cz[count] = 0, 0, 0
		end

		local density = collider:GetDensity()
		local volume = density > 0 and shape:GetAutomaticMass(collider) / density or 0

		if not (volume > 0) then volume = 8 * hx * hy * hz end

		local local_rotation = collider:GetLocalRotation()
		local local_position = collider:GetLocalPosition()

		for i = first, count do
			cv[i] = volume / (count - first + 1)
			COLLIDER_OFFSET:Set(cx[i], cy[i], cz[i])
			local_rotation:VecMul(COLLIDER_OFFSET, COLLIDER_OFFSET)
			cx[i] = COLLIDER_OFFSET.x + local_position.x
			cy[i] = COLLIDER_OFFSET.y + local_position.y
			cz[i] = COLLIDER_OFFSET.z + local_position.z
			radius = math.max(radius, math.sqrt(cx[i] * cx[i] + cy[i] * cy[i] + cz[i] * cz[i]))
		end

		radius = math.max(radius, math.sqrt(hx * hx + hy * hy + hz * hz) + local_position:GetLength())
		total_volume = total_volume + volume
		spacing = spacing + (2 * hx / nx + 2 * hy / ny + 2 * hz / nz) / 3
		spacing_count = spacing_count + 1
	end

	return {
		count = count,
		x = cx,
		y = cy,
		z = cz,
		volume = cv,
		total_volume = total_volume,
		radius = radius,
		spacing = spacing / spacing_count,
	}
end

-- Archimedes: every cell below a surface pushes up with the weight of the fluid it displaces,
-- applied at the cell so a body that is only partly under rights itself. a cell crosses the surface
-- over one cell spacing, which keeps the force continuous. drag is applied implicitly.
-- gravity is scaled by the body's GravityScale, and BuoyancyDensity makes the body float as if its
-- material had that density whatever its simulated mass is, which drag follows too
function buoyancy.Apply(body, dt, gravity)
	local cells = body.BuoyancyCells

	if not cells then
		cells = buoyancy.BuildCells(body)
		body.BuoyancyCells = cells
	end

	local position = body.Position
	local px, py, pz = position.x, position.y, position.z
	local regions = fluid.regions
	local active = ACTIVE_REGIONS
	local active_count = 0
	local ocean_active = false

	for i = 1, #regions do
		local region = regions[i]

		if fluid.Overlaps(region, px, py, pz, cells.radius) then
			active_count = active_count + 1
			active[active_count] = region
			ocean_active = ocean_active or region.ocean
		end
	end

	if active_count == 0 then
		body.SubmergedFraction = 0
		return
	end

	local wave_height, wave_slope_x, wave_slope_z = 0, 0, 0
	local water_velocity_x, water_velocity_y, water_velocity_z = 0, 0, 0

	if ocean_active then
		local sample = water.SampleOcean(px, pz, fluid.time, cells.radius * 3, OCEAN_SAMPLE)
		wave_height, wave_slope_x, wave_slope_z = sample.height, sample.slope_x, sample.slope_z

		if active_count == 1 then
			water_velocity_x, water_velocity_y, water_velocity_z = sample.velocity_x, sample.velocity_y, sample.velocity_z
		end
	end

	local rotation = body.Rotation
	local qx, qy, qz, qw = rotation.x, rotation.y, rotation.z, rotation.w
	local r00 = 1 - 2 * (qy * qy + qz * qz)
	local r01 = 2 * (qx * qy - qz * qw)
	local r02 = 2 * (qx * qz + qy * qw)
	local r10 = 2 * (qx * qy + qz * qw)
	local r11 = 1 - 2 * (qx * qx + qz * qz)
	local r12 = 2 * (qy * qz - qx * qw)
	local r20 = 2 * (qx * qz - qy * qw)
	local r21 = 2 * (qy * qz + qx * qw)
	local r22 = 1 - 2 * (qx * qx + qy * qy)
	local cx, cy, cz, cv = cells.x, cells.y, cells.z, cells.volume
	local gravity_scale = body.GravityScale
	local displaced_scale = gravity_scale

	if body.BuoyancyDensity then
		displaced_scale = displaced_scale * (
				1 / body.InverseMass
			) / (
				cells.total_volume * body.BuoyancyDensity
			)
	end

	local spacing = cells.spacing
	local inverse_spacing = 1 / spacing
	local weight = 0
	local submerged = 0
	local force_x, force_y, force_z = 0, 0, 0
	local torque_x, torque_y, torque_z = 0, 0, 0

	for i = 1, cells.count do
		local ox = r00 * cx[i] + r01 * cy[i] + r02 * cz[i]
		local oy = r10 * cx[i] + r11 * cy[i] + r12 * cz[i]
		local oz = r20 * cx[i] + r21 * cy[i] + r22 * cz[i]
		local x, y, z = px + ox, py + oy, pz + oz
		local best_weight = 0
		local best_fraction = 0

		for j = 1, active_count do
			local region = active[j]
			local fraction

			if region.ocean then
				fraction = (
						region.level + wave_height + wave_slope_x * (
							x - px
						) + wave_slope_z * (
							z - pz
						) - y
					) * inverse_spacing + 0.5
			else
				local lx = x * region.m00 + y * region.m10 + z * region.m20 + region.m30
				local ly = x * region.m01 + y * region.m11 + z * region.m21 + region.m31
				local lz = x * region.m02 + y * region.m12 + z * region.m22 + region.m32

				if
					lx > -region.half_x and
					lx < region.half_x and
					lz > -region.half_z and
					lz < region.half_z and
					ly > -region.depth
				then
					fraction = -ly * inverse_spacing + 0.5
				else
					fraction = 0
				end
			end

			if fraction > 1 then fraction = 1 end

			if fraction > 0 and region.density * fraction > best_weight then
				best_weight = region.density * fraction
				best_fraction = fraction
			end
		end

		if best_weight > 0 then
			local displaced = best_weight * cv[i] * displaced_scale
			local fx, fy, fz = -gravity.x * displaced, -gravity.y * displaced, -gravity.z * displaced
			force_x, force_y, force_z = force_x + fx, force_y + fy, force_z + fz
			torque_x = torque_x + oy * fz - oz * fy
			torque_y = torque_y + oz * fx - ox * fz
			torque_z = torque_z + ox * fy - oy * fx
			weight = weight + displaced
			submerged = submerged + best_fraction * cv[i]
		end
	end

	body.SubmergedFraction = submerged / cells.total_volume

	if submerged == 0 then return end

	if ocean_active then body.SleepTimer = 0 end

	local inverse_mass = body.InverseMass
	local acceleration = math.sqrt(force_x * force_x + force_y * force_y + force_z * force_z) * inverse_mass
	local limit = fluid.MAX_ACCELERATION * gravity:GetLength() * gravity_scale
	local scale = acceleration > limit and limit / acceleration or 1
	local velocity = body.Velocity
	local angular_velocity = body.AngularVelocity
	local impulse = scale * inverse_mass * dt
	velocity.x = velocity.x + force_x * impulse
	velocity.y = velocity.y + force_y * impulse
	velocity.z = velocity.z + force_z * impulse
	TORQUE_IMPULSE:Set(torque_x * scale * dt, torque_y * scale * dt, torque_z * scale * dt)
	angular_velocity:Add(body:GetAngularVelocityDelta(TORQUE_IMPULSE))
	local fraction = body.SubmergedFraction
	local fluid_density = weight / (submerged * displaced_scale)
	local drag = 0.5 * fluid_density * fluid.DRAG_COEFFICIENT * submerged ^ (
			2 / 3
		) * inverse_mass * displaced_scale / gravity_scale
	local relative_x = velocity.x - water_velocity_x
	local relative_y = velocity.y - water_velocity_y
	local relative_z = velocity.z - water_velocity_z
	local relative_speed = math.sqrt(relative_x * relative_x + relative_y * relative_y + relative_z * relative_z)
	local linear_rate = fluid.LINEAR_VISCOSITY * fraction + drag * relative_speed
	local angular_rate = fluid.ANGULAR_VISCOSITY * fraction + drag * submerged ^ (
			1 / 3
		) * angular_velocity:GetLength()
	local linear_scale = 1 / (1 + linear_rate * dt)
	local angular_scale = 1 / (1 + angular_rate * dt)
	velocity.x = water_velocity_x + relative_x * linear_scale
	velocity.y = water_velocity_y + relative_y * linear_scale
	velocity.z = water_velocity_z + relative_z * linear_scale
	angular_velocity.x = angular_velocity.x * angular_scale
	angular_velocity.y = angular_velocity.y * angular_scale
	angular_velocity.z = angular_velocity.z * angular_scale
end

return buoyancy
