local ffi = require("ffi")
local Cloth = {}
Cloth.__index = Cloth
local SUBSTEP = 1 / 60
local MAX_SUBSTEPS = 4
local MAX_DT = 0.1
local DAMPING = 3
local ITERATIONS = 3
local ATTRACTION_RATE = 60
local TELEPORT_DISTANCE = 2
local Doubles = ffi.typeof("double[?]")

function Cloth.New(skeleton)
	local desc = skeleton.Cloth
	local count = desc.count
	local self = setmetatable(
		{
			desc = desc,
			skeleton = skeleton,
			position = Doubles(count * 3),
			previous = Doubles(count * 3),
			target = Doubles(count * 3),
			current_matrix = Doubles(12),
			next_matrix = Doubles(12),
			transform = Doubles(12),
			bind_rotation = ffi.new("float[?]", skeleton.BoneCount * 9),
			dt = 0,
			initialized = false,
		},
		Cloth
	)
	local bind = skeleton.BindLocal
	local rotation = self.bind_rotation

	for node = 0, count - 1 do
		local bone = desc.node_bone[node]

		if bone >= 0 and desc.inv_mass[node] > 0 then
			local x, y, z, w = bind[bone * 7 + 3], bind[bone * 7 + 4], bind[bone * 7 + 5], bind[bone * 7 + 6]
			local o = bone * 9
			rotation[o], rotation[o + 1], rotation[o + 2] = 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)
			rotation[o + 3], rotation[o + 4], rotation[o + 5] = 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)
			rotation[o + 6], rotation[o + 7], rotation[o + 8] = 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)
		end
	end

	return self
end

function Cloth:Advance(dt, matrix)
	local m = self.next_matrix
	self.dt = self.dt + dt
	m[0], m[1], m[2], m[3] = matrix.m00, matrix.m10, matrix.m20, matrix.m30
	m[4], m[5], m[6], m[7] = matrix.m01, matrix.m11, matrix.m21, matrix.m31
	m[8], m[9], m[10], m[11] = matrix.m02, matrix.m12, matrix.m22, matrix.m32
end

-- writes into out the transform that takes model space positions of the previous entity matrix to the current one, and returns the direction of world down in model space
local function get_transform(previous, current, out)
	local a, b, c, d, e, f, g, h, i = current[0],
	current[1],
	current[2],
	current[4],
	current[5],
	current[6],
	current[8],
	current[9],
	current[10]
	local c00, c01, c02 = e * i - f * h, c * h - b * i, b * f - c * e
	local c10, c11, c12 = f * g - d * i, a * i - c * g, c * d - a * f
	local c20, c21, c22 = d * h - e * g, b * g - a * h, a * e - b * d
	local inverse_determinant = 1 / (a * c00 + b * c10 + c * c20)
	c00, c01, c02, c10, c11, c12, c20, c21, c22 = c00 * inverse_determinant,
	c01 * inverse_determinant,
	c02 * inverse_determinant,
	c10 * inverse_determinant,
	c11 * inverse_determinant,
	c12 * inverse_determinant,
	c20 * inverse_determinant,
	c21 * inverse_determinant,
	c22 * inverse_determinant
	local tx, ty, tz = previous[3] - current[3], previous[7] - current[7], previous[11] - current[11]
	local p00, p01, p02, p10, p11, p12, p20, p21, p22 = previous[0],
	previous[1],
	previous[2],
	previous[4],
	previous[5],
	previous[6],
	previous[8],
	previous[9],
	previous[10]
	out[0], out[1], out[2] = c00 * p00 + c01 * p10 + c02 * p20,
	c00 * p01 + c01 * p11 + c02 * p21,
	c00 * p02 + c01 * p12 + c02 * p22
	out[4], out[5], out[6] = c10 * p00 + c11 * p10 + c12 * p20,
	c10 * p01 + c11 * p11 + c12 * p21,
	c10 * p02 + c11 * p12 + c12 * p22
	out[8], out[9], out[10] = c20 * p00 + c21 * p10 + c22 * p20,
	c20 * p01 + c21 * p11 + c22 * p21,
	c20 * p02 + c21 * p12 + c22 * p22
	out[3], out[7], out[11] = c00 * tx + c01 * ty + c02 * tz,
	c10 * tx + c11 * ty + c12 * tz,
	c20 * tx + c21 * ty + c22 * tz
	return -c01, -c11, -c21
end

-- the model space position the animation gives each node: the alpha weighted mean of its bone attachments
local function compute_targets(desc, world, target)
	local target_start, target_bone, target_offset, target_alpha = desc.target_start, desc.target_bone, desc.target_offset, desc.target_alpha

	for node = 0, desc.count - 1 do
		local x, y, z, total = 0, 0, 0, 0

		for k = target_start[node], target_start[node + 1] - 1 do
			local w = target_bone[k] * 12
			local ox, oy, oz = target_offset[k * 3], target_offset[k * 3 + 1], target_offset[k * 3 + 2]
			local alpha = target_alpha[k]
			x = x + (
					world[w] * ox + world[w + 1] * oy + world[w + 2] * oz + world[w + 3]
				) * alpha
			y = y + (
					world[w + 4] * ox + world[w + 5] * oy + world[w + 6] * oz + world[w + 7]
				) * alpha
			z = z + (
					world[w + 8] * ox + world[w + 9] * oy + world[w + 10] * oz + world[w + 11]
				) * alpha
			total = total + alpha
		end

		if total > 0 then
			target[node * 3], target[node * 3 + 1], target[node * 3 + 2] = x / total, y / total, z / total
		end
	end
end

-- called after the rig computed the animated pose: simulates the nodes and replaces the world and skin matrices of the cloth bones
function Cloth:Apply(rig)
	local desc, position, previous, target = self.desc, self.position, self.previous, self.target
	local count = desc.count
	local inv_mass, attraction, gravity = desc.inv_mass, desc.attraction, desc.gravity
	local world, matrices = rig.world, rig.matrices
	compute_targets(desc, world, target)
	local dt = math.min(self.dt, MAX_DT)
	self.dt = 0

	if not self.initialized then
		self.initialized = true
		ffi.copy(position, target, count * 24)
		ffi.copy(previous, target, count * 24)
		ffi.copy(self.current_matrix, self.next_matrix, 96)
	elseif dt > 0 then
		local transform = self.transform
		local down_x, down_y, down_z = get_transform(self.current_matrix, self.next_matrix, transform)
		ffi.copy(self.current_matrix, self.next_matrix, 96)
		local t00, t01, t02, t03 = transform[0], transform[1], transform[2], transform[3]
		local t10, t11, t12, t13 = transform[4], transform[5], transform[6], transform[7]
		local t20, t21, t22, t23 = transform[8], transform[9], transform[10], transform[11]

		if t03 * t03 + t13 * t13 + t23 * t23 > TELEPORT_DISTANCE * TELEPORT_DISTANCE then
			ffi.copy(position, target, count * 24)
			ffi.copy(previous, target, count * 24)
		else
			for node = 0, count * 3 - 3, 3 do
				local x, y, z = position[node], position[node + 1], position[node + 2]
				position[node], position[node + 1], position[node + 2] = t00 * x + t01 * y + t02 * z + t03,
				t10 * x + t11 * y + t12 * z + t13,
				t20 * x + t21 * y + t22 * z + t23
				x, y, z = previous[node], previous[node + 1], previous[node + 2]
				previous[node], previous[node + 1], previous[node + 2] = t00 * x + t01 * y + t02 * z + t03,
				t10 * x + t11 * y + t12 * z + t13,
				t20 * x + t21 * y + t22 * z + t23
			end
		end

		local steps = math.min(math.ceil(dt / SUBSTEP), MAX_SUBSTEPS)
		local h = dt / steps
		local damping = 1 - math.min(DAMPING * h, 1)
		local rod_nodes, rod_limits = desc.rod_nodes, desc.rod_limits

		for _ = 1, steps do
			for node = 0, count - 1 do
				local o = node * 3

				if inv_mass[node] > 0 then
					local x, y, z = position[o], position[o + 1], position[o + 2]
					local g = gravity[node] * h * h
					local nx = x + (x - previous[o]) * damping + down_x * g
					local ny = y + (y - previous[o + 1]) * damping + down_y * g
					local nz = z + (z - previous[o + 2]) * damping + down_z * g
					previous[o], previous[o + 1], previous[o + 2] = x, y, z
					local pull = 1 - (1 - attraction[node]) ^ (ATTRACTION_RATE * h)
					position[o] = nx + (target[o] - nx) * pull
					position[o + 1] = ny + (target[o + 1] - ny) * pull
					position[o + 2] = nz + (target[o + 2] - nz) * pull
				else
					position[o], position[o + 1], position[o + 2] = target[o], target[o + 1], target[o + 2]
					previous[o], previous[o + 1], previous[o + 2] = target[o], target[o + 1], target[o + 2]
				end
			end

			for _ = 1, ITERATIONS do
				for rod = 0, desc.rod_count - 1 do
					local a, b = rod_nodes[rod * 2] * 3, rod_nodes[rod * 2 + 1] * 3
					local wa, wb = inv_mass[rod_nodes[rod * 2]], inv_mass[rod_nodes[rod * 2 + 1]]
					local total = wa + wb

					if total > 0 then
						local dx, dy, dz = position[b] - position[a],
						position[b + 1] - position[a + 1],
						position[b + 2] - position[a + 2]
						local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
						local wanted = math.min(math.max(distance, rod_limits[rod * 2]), rod_limits[rod * 2 + 1])

						if distance > 1e-9 and wanted ~= distance then
							local correction = (distance - wanted) / distance / total
							position[a] = position[a] + dx * correction * wa
							position[a + 1] = position[a + 1] + dy * correction * wa
							position[a + 2] = position[a + 2] + dz * correction * wa
							position[b] = position[b] - dx * correction * wb
							position[b + 1] = position[b + 1] - dy * correction * wb
							position[b + 2] = position[b + 2] - dz * correction * wb
						end
					end
				end
			end
		end
	end

	local parents, bind_rotation, inverse_bind, node_bone = self.skeleton.parents, self.bind_rotation, self.skeleton.InverseBind, desc.node_bone

	for node = 0, count - 1 do
		local bone = node_bone[node]

		if bone >= 0 and inv_mass[node] > 0 then
			local p = parents[bone] * 12
			local r = bone * 9
			local w = bone * 12
			local a00, a01, a02 = world[p], world[p + 1], world[p + 2]
			local a10, a11, a12 = world[p + 4], world[p + 5], world[p + 6]
			local a20, a21, a22 = world[p + 8], world[p + 9], world[p + 10]
			local r00, r01, r02, r10, r11, r12, r20, r21, r22 = bind_rotation[r],
			bind_rotation[r + 1],
			bind_rotation[r + 2],
			bind_rotation[r + 3],
			bind_rotation[r + 4],
			bind_rotation[r + 5],
			bind_rotation[r + 6],
			bind_rotation[r + 7],
			bind_rotation[r + 8]
			local o = node * 3
			world[w], world[w + 1], world[w + 2], world[w + 3] = a00 * r00 + a01 * r10 + a02 * r20,
			a00 * r01 + a01 * r11 + a02 * r21,
			a00 * r02 + a01 * r12 + a02 * r22,
			position[o]
			world[w + 4], world[w + 5], world[w + 6], world[w + 7] = a10 * r00 + a11 * r10 + a12 * r20,
			a10 * r01 + a11 * r11 + a12 * r21,
			a10 * r02 + a11 * r12 + a12 * r22,
			position[o + 1]
			world[w + 8], world[w + 9], world[w + 10], world[w + 11] = a20 * r00 + a21 * r10 + a22 * r20,
			a20 * r01 + a21 * r11 + a22 * r21,
			a20 * r02 + a21 * r12 + a22 * r22,
			position[o + 2]
			local m00, m01, m02, m03 = world[w], world[w + 1], world[w + 2], world[w + 3]
			local m10, m11, m12, m13 = world[w + 4], world[w + 5], world[w + 6], world[w + 7]
			local m20, m21, m22, m23 = world[w + 8], world[w + 9], world[w + 10], world[w + 11]
			local b00, b01, b02, b03 = inverse_bind[w], inverse_bind[w + 1], inverse_bind[w + 2], inverse_bind[w + 3]
			local b10, b11, b12, b13 = inverse_bind[w + 4], inverse_bind[w + 5], inverse_bind[w + 6], inverse_bind[w + 7]
			local b20, b21, b22, b23 = inverse_bind[w + 8], inverse_bind[w + 9], inverse_bind[w + 10], inverse_bind[w + 11]
			matrices[w] = m00 * b00 + m01 * b10 + m02 * b20
			matrices[w + 1] = m00 * b01 + m01 * b11 + m02 * b21
			matrices[w + 2] = m00 * b02 + m01 * b12 + m02 * b22
			matrices[w + 3] = m00 * b03 + m01 * b13 + m02 * b23 + m03
			matrices[w + 4] = m10 * b00 + m11 * b10 + m12 * b20
			matrices[w + 5] = m10 * b01 + m11 * b11 + m12 * b21
			matrices[w + 6] = m10 * b02 + m11 * b12 + m12 * b22
			matrices[w + 7] = m10 * b03 + m11 * b13 + m12 * b23 + m13
			matrices[w + 8] = m20 * b00 + m21 * b10 + m22 * b20
			matrices[w + 9] = m20 * b01 + m21 * b11 + m22 * b21
			matrices[w + 10] = m20 * b02 + m21 * b12 + m22 * b22
			matrices[w + 11] = m20 * b03 + m21 * b13 + m22 * b23 + m23
		end
	end
end

return Cloth
