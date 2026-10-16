-- how the foliage moves in the wind, measured on the cpu: get_vertex_animation_offset_at_time of
-- goluwa/render3d/model_pipeline.lua copied to lua (keep it in step), run over every vertex of a model at many times in a
-- strong wind. it prints for each model:
--   stretch: how much the edges of the wood get longer or shorter, of their length (0 is rigid, the sway of a trunk
--     around its root keeps it near 0, a trunk going up and down along itself does not)
--   detach: how far the base of a leaf card, the frond or the blade moves from the wood it hangs on, meters (the
--     nearest wood vertex at rest of the same limb, the same phase, is followed. a card on a twig too thin to have wood
--     is followed against the branch the twig grows on)
-- MODEL=pine_a luajit glw --2d --background lua test/harnesses/foliage/wind_check.lua, NO_MAIN=1 leaves out the sway
-- of the whole and NO_DETAIL=1 the detail bending, to tell which one it is
local ffi = require("ffi")
local system = import("goluwa/system.lua")
local foliage = import("lua/foliage/foliage.lua")
local floor, sqrt, abs, max, min = math.floor, math.sqrt, math.abs, math.max, math.min
local WIND_X, WIND_Z = 6, 0
local BEND_RESPONSE, MAX_BENDING, BEND_PER_HEIGHT = 0.25, 2, 0.25
local MODES = {none = 0, leaves = 1, grass = 2}

local function fract(x)
	return x - floor(x)
end

local function triangle(x)
	return abs(fract(x + 0.5) * 2 - 1)
end

local function clamp01(x)
	return min(max(x, 0), 1)
end

-- the block model_pipeline.FillVertexAnimationData writes for a part
local function animation_block(part)
	local wind_x, wind_z = WIND_X * BEND_RESPONSE, WIND_Z * BEND_RESPONSE
	local wind_length = sqrt(wind_x * wind_x + wind_z * wind_z)
	local bending = wind_length * MAX_BENDING / (MAX_BENDING + wind_length)
	local material, height = part.material, part.mesh:GetBendHeight()
	return {
		main = height > 0 and not os.getenv("NO_MAIN") and bending * material:GetBending() * height * BEND_PER_HEIGHT or 0,
		height = height,
		speed = wind_length,
		dir_x = wind_x / wind_length,
		dir_z = wind_z / wind_length,
		detail = os.getenv("NO_DETAIL") and 0 or MODES[material:GetDetailBending()],
		frequency = material:GetBendDetailFrequency(),
		leaf = material:GetBendDetailLeafAmplitude(),
		branch = material:GetBendDetailBranchAmplitude(),
		phase = material:GetBendDetailPhase(),
	}
end

-- the object space position of a vertex at time t, an instance at the origin without rotation
local function animate(block, v, t)
	local p, c = v.position, v.vertex_color
	local x, y, z = p[0], p[1], p[2]

	if block.detail ~= 0 then
		local edge, branch_atten = os.getenv("NO_FLUTTER") and 0 or clamp01(c[0]), 1 - clamp01(c[2])
		local speed = block.speed

		if block.detail == 2 then speed = speed * y end

		local branch_phase = clamp01(c[1])
		local vertex_phase = (x + y + z) * (block.phase + branch_phase)
		local scale = speed * block.frequency
		local w1 = triangle((fract((t + vertex_phase) * 1.975) * 2 - 1) * scale)
		local w2 = triangle((fract((t + vertex_phase) * 0.793) * 2 - 1) * scale)
		local w3 = triangle((fract((t + branch_phase) * 0.375) * 2 - 1) * scale)
		local w4 = triangle((fract((t + branch_phase) * 0.193) * 2 - 1) * scale)
		x = x + (w1 + w2) * edge * block.leaf * block.dir_x
		z = z + (w1 + w2) * edge * block.leaf * block.dir_z
		y = y + (w3 + w4) * branch_atten * block.branch
	end

	if block.main > 0 then
		-- an instance at the origin, its phase is 0
		local gust = 0.5 * math.sin(t * 0.71) + 0.3 * math.sin(t * 1.63 + 1.7) + 0.2 * math.sin(t * 2.87 + 4.1)
		local sway = t * 6.2832 * 1.2 / sqrt(max(block.height, 0.5))
		local strength = 0.6 + 0.4 * gust
		local along = 0.25 * gust + 0.15 * strength * math.sin(sway)
		local across = 0.12 * strength * math.sin(sway * 1.13 + 1.3)
		local bx = (block.dir_x * (1 + along) - block.dir_z * across) * block.main * 0.015
		local bz = (block.dir_z * (1 + along) + block.dir_x * across) * block.main * 0.015
		local f = y / block.height + 1
		f = f * f
		f = f * f - f
		local length = sqrt(x * x + y * y + z * z)

		if length > 0 then
			local nx, ny, nz = x + bx * f, y, z + bz * f
			local l = sqrt(nx * nx + ny * ny + nz * nz)
			x, y, z = nx / l * length, ny / l * length, nz / l * length
		end
	end

	return x, y, z
end

local function distance(ax, ay, az, bx, by, bz)
	return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end

local TIMES = {}

for i = 1, 24 do
	TIMES[i] = i * 1.37
end

local function check(name, config)
	local parts = foliage.Build(name, config)
	local wood
	local stretch, detach = 0, 0

	for _, part in ipairs(parts) do
		local packed = part.mesh.packed

		if part.mesh:GetLODLevel() == 0 and packed then
			local block = animation_block(part)
			local vertices, indices = packed.vertices, packed.indices

			-- the wood is the first part, whatever is not wood hangs on it
			if not wood then
				wood = {block = block, vertices = vertices, count = packed.vertex_count}

				for _, t in ipairs(TIMES) do
					local moved = {}

					for i = 0, packed.vertex_count - 1 do
						moved[i] = {animate(block, vertices[i], t)}
					end

					for i = 0, packed.index_count - 1, 3 do
						for k = 0, 2 do
							local a, b = indices[i + k], indices[i + (k + 1) % 3]
							local pa, pb = vertices[a].position, vertices[b].position
							local rest = distance(pa[0], pa[1], pa[2], pb[0], pb[1], pb[2])

							if rest > 0.01 then
								local ma, mb = moved[a], moved[b]
								stretch = max(stretch, abs(distance(ma[1], ma[2], ma[3], mb[1], mb[2], mb[3]) - rest) / rest)
							end
						end
					end
				end
			elseif wood.block.detail ~= 0 or wood.block.main > 0 then
				-- the vertices of each part that are held (no flutter) against the wood vertex nearest to them, a sample
				local held = {}

				for i = 0, packed.vertex_count - 1 do
					if vertices[i].vertex_color[0] < 0.2 and #held < 200 and i % 7 == 0 then held[#held + 1] = i end
				end

				for _, i in ipairs(held) do
					local p = vertices[i].position
					local best, nearest = math.huge, 0

					local phase = vertices[i].vertex_color[1]

					for j = 0, wood.count - 1 do
						local q = wood.vertices[j].position
						local d = (p[0] - q[0]) ^ 2 + (p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2

						if d < best and abs(wood.vertices[j].vertex_color[1] - phase) < 1e-4 then best, nearest = d, j end
					end

					-- only what hangs on the wood near it
					if best < 0.5 * 0.5 then
						local q = wood.vertices[nearest].position
						local rx, ry, rz = p[0] - q[0], p[1] - q[1], p[2] - q[2]

						for _, t in ipairs(TIMES) do
							local px, py, pz = animate(block, vertices[i], t)
							local qx, qy, qz = animate(wood.block, wood.vertices[nearest], t)
							detach = max(detach, distance(px - qx, py - qy, pz - qz, rx, ry, rz))
						end
					end
				end
			end
		end
	end

	return stretch, detach
end

local only = os.getenv("MODEL")

for _, category in ipairs{"trees", "plants", "grass"} do
	for _, path in ipairs(foliage.GetModelPaths(category)) do
		local preset = path:match("([^/]+)%.lua$")

		if not only or preset:find(only, 1, true) then
			local entry = foliage.models[path]
			local stretch, detach = check(entry.generator, entry.config)
			print(("%-28s stretch %5.1f%%   detach %.3f m"):format(category .. "/" .. preset, stretch * 100, detach))
		end
	end
end

system.ShutDown(0)
