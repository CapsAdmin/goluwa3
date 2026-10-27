local vegetation_pivots = {}
vegetation_pivots.SUPPORT_STIFFNESS = 0.9
vegetation_pivots.MIN_STIFFNESS_RANGE = 0.05
vegetation_pivots.BASE_FRACTION = 0.05
vegetation_pivots.MIN_BASE_HEIGHT = 0.02
local POSITION_SCALE = 1e4
local floor, max = math.floor, math.max
local format = string.format

local function solve(count, px, py, pz, stiffness, triangles, triangle_count)
	local canon, canon_count, key_to_id = {}, 0, {}
	local cx, cy, cz, cb = {}, {}, {}, {}

	for i = 1, count do
		local key = format(
			"%d,%d,%d",
			floor(px[i] * POSITION_SCALE + 0.5),
			floor(py[i] * POSITION_SCALE + 0.5),
			floor(pz[i] * POSITION_SCALE + 0.5)
		)
		local id = key_to_id[key]

		if id then
			cb[id] = max(cb[id], stiffness[i])
		else
			canon_count = canon_count + 1
			id = canon_count
			key_to_id[key] = id
			cx[id], cy[id], cz[id], cb[id] = px[i], py[i], pz[i], stiffness[i]
		end

		canon[i] = id
	end

	local neighbors = {}

	for id = 1, canon_count do
		neighbors[id] = {}
	end

	for t = 0, triangle_count - 1 do
		local a, b, c = canon[triangles[t * 3 + 1]], canon[triangles[t * 3 + 2]], canon[triangles[t * 3 + 3]]

		if a ~= b then
			local list = neighbors[a]
			list[#list + 1] = b
			list = neighbors[b]
			list[#list + 1] = a
		end

		if b ~= c then
			local list = neighbors[b]
			list[#list + 1] = c
			list = neighbors[c]
			list[#list + 1] = b
		end

		if c ~= a then
			local list = neighbors[c]
			list[#list + 1] = a
			list = neighbors[a]
			list[#list + 1] = c
		end
	end

	local component, component_max, component_min = {}, {}, {}
	local component_low, component_high = {}, {}
	local stack = {}
	local component_count = 0

	for id = 1, canon_count do
		if not component[id] then
			component_count = component_count + 1
			component[id] = component_count
			local high, low = cb[id], cb[id]
			local low_y, high_y = cy[id], cy[id]
			local top = 1
			stack[1] = id

			while top > 0 do
				local node = stack[top]
				top = top - 1
				local value = cb[node]

				if value > high then high = value end

				if value < low then low = value end

				if cy[node] < low_y then low_y = cy[node] end

				if cy[node] > high_y then high_y = cy[node] end

				local list = neighbors[node]

				for k = 1, #list do
					local other = list[k]

					if not component[other] then
						component[other] = component_count
						top = top + 1
						stack[top] = other
					end
				end
			end

			component_max[component_count], component_min[component_count] = high, low
			component_low[component_count], component_high[component_count] = low_y, high_y
		end
	end

	local is_support = {}

	for id = 1, canon_count do
		local c = component[id]

		if component_max[c] - component_min[c] >= vegetation_pivots.MIN_STIFFNESS_RANGE then
			local threshold = component_max[c] < vegetation_pivots.SUPPORT_STIFFNESS and
				component_max[c] - vegetation_pivots.MIN_STIFFNESS_RANGE * 0.5 or
				vegetation_pivots.SUPPORT_STIFFNESS
			is_support[id] = cb[id] >= threshold
		else
			local base = component_low[c] + max(
					(component_high[c] - component_low[c]) * vegetation_pivots.BASE_FRACTION,
					vegetation_pivots.MIN_BASE_HEIGHT
				)
			is_support[id] = cy[id] <= base
		end
	end

	local cluster, cluster_count = {}, 0
	local sum_x, sum_y, sum_z, sum_n = {}, {}, {}, {}

	for id = 1, canon_count do
		if is_support[id] and not cluster[id] then
			cluster_count = cluster_count + 1
			cluster[id] = cluster_count
			local x, y, z, n = 0, 0, 0, 0
			local top = 1
			stack[1] = id

			while top > 0 do
				local node = stack[top]
				top = top - 1
				x, y, z, n = x + cx[node], y + cy[node], z + cz[node], n + 1
				local list = neighbors[node]

				for k = 1, #list do
					local other = list[k]

					if is_support[other] and not cluster[other] then
						cluster[other] = cluster_count
						top = top + 1
						stack[top] = other
					end
				end
			end

			sum_x[cluster_count], sum_y[cluster_count], sum_z[cluster_count], sum_n[cluster_count] = x, y, z, n
		end
	end

	local queue, head, tail = {}, 1, 0
	local parent = {}

	for id = 1, canon_count do
		if cluster[id] then
			tail = tail + 1
			queue[tail] = id
		end
	end

	while head <= tail do
		local node = queue[head]
		head = head + 1
		local list = neighbors[node]

		for k = 1, #list do
			local other = list[k]

			if not cluster[other] then
				cluster[other] = cluster[node]
				parent[other] = node
				tail = tail + 1
				queue[tail] = other
			end
		end
	end

	local tip_node, tip_distance = {}, {}

	for id = 1, canon_count do
		local c = cluster[id]

		if c then
			local n = sum_n[c]
			local dx, dy, dz = cx[id] - sum_x[c] / n, cy[id] - sum_y[c] / n, cz[id] - sum_z[c] / n
			local distance = dx * dx + dy * dy + dz * dz

			if not tip_distance[c] or distance > tip_distance[c] then
				tip_node[c], tip_distance[c] = id, distance
			end
		end
	end

	local mid_x, mid_y, mid_z = {}, {}, {}

	for c = 1, cluster_count do
		local tip = tip_node[c]
		local path = {tip}
		local node = tip

		while parent[node] do
			node = parent[node]
			path[#path + 1] = node
		end

		local total = 0
		local lengths = {}

		for k = 1, #path - 1 do
			local a, b = path[k], path[k + 1]
			local dx, dy, dz = cx[a] - cx[b], cy[a] - cy[b], cz[a] - cz[b]
			lengths[k] = math.sqrt(dx * dx + dy * dy + dz * dz)
			total = total + lengths[k]
		end

		local n = sum_n[c]

		if #path == 1 or total == 0 then
			mid_x[c], mid_y[c], mid_z[c] = (sum_x[c] / n + cx[tip]) * 0.5, (sum_y[c] / n + cy[tip]) * 0.5, (sum_z[c] / n + cz[tip]) * 0.5
		else
			local walked = 0

			for k = 1, #path - 1 do
				if walked + lengths[k] >= total * 0.5 then
					local t = lengths[k] > 0 and (total * 0.5 - walked) / lengths[k] or 0
					local a, b = path[k], path[k + 1]
					mid_x[c], mid_y[c], mid_z[c] = cx[a] + (cx[b] - cx[a]) * t, cy[a] + (cy[b] - cy[a]) * t, cz[a] + (cz[b] - cz[a]) * t

					break
				end

				walked = walked + lengths[k]
			end
		end
	end

	local result = {pivot = {{}, {}, {}}, mid = {{}, {}, {}}, tip = {{}, {}, {}}}

	for i = 1, count do
		local c = cluster[canon[i]]

		if c then
			local n = sum_n[c]
			local tip = tip_node[c]
			result.pivot[1][i], result.pivot[2][i], result.pivot[3][i] = sum_x[c] / n, sum_y[c] / n, sum_z[c] / n
			result.mid[1][i], result.mid[2][i], result.mid[3][i] = mid_x[c], mid_y[c], mid_z[c]
			result.tip[1][i], result.tip[2][i], result.tip[3][i] = cx[tip], cy[tip], cz[tip]
		end
	end

	return result
end

function vegetation_pivots.ComputeTables(vertices, indices)
	local count = #vertices
	local px, py, pz, stiffness = {}, {}, {}, {}

	for i = 1, count do
		local vertex = vertices[i]
		local pos = vertex.pos
		px[i], py[i], pz[i] = pos.x, pos.y, pos.z
		stiffness[i] = vertex.vertex_color.b
	end

	local result = solve(count, px, py, pz, stiffness, indices, #indices / 3)

	for i = 1, count do
		if result.pivot[1][i] then
			vertices[i].pivot = {result.pivot[1][i], result.pivot[2][i], result.pivot[3][i]}
			vertices[i].chain_mid = {result.mid[1][i], result.mid[2][i], result.mid[3][i]}
			vertices[i].chain_tip = {result.tip[1][i], result.tip[2][i], result.tip[3][i]}
		end
	end

	return true
end

vegetation_pivots.MIN_ROOT_LENGTH = 0.5
vegetation_pivots.ROOT_BASE_TOLERANCE = 0.3

vegetation_pivots.DEFAULT_ROOT_FLEX = 0.1

local function add_piece(pieces, seen, pivot, mid, tip)
	local key = format(
		"%d,%d,%d",
		floor(pivot[1] * 1000 + 0.5),
		floor(pivot[2] * 1000 + 0.5),
		floor(pivot[3] * 1000 + 0.5)
	)

	if seen[key] then return end

	seen[key] = true
	local dx, dy, dz = tip[1] - pivot[1], tip[2] - pivot[2], tip[3] - pivot[3]
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)

	if length >= vegetation_pivots.MIN_ROOT_LENGTH then
		pieces[#pieces + 1] = {pivot = pivot, mid = mid, tip = tip, length = length}
	end
end

local function choose_root(pieces, flex)
	if not pieces[1] then return nil end

	local lowest = math.huge

	for _, piece in ipairs(pieces) do
		lowest = math.min(lowest, piece.pivot[2])
	end

	local root

	for _, piece in ipairs(pieces) do
		if
			piece.pivot[2] <= lowest + vegetation_pivots.ROOT_BASE_TOLERANCE and
			(
				not root or
				piece.length > root.length
			)
		then
			root = piece
		end
	end

	return {
		pivot = {root.pivot[1], root.pivot[2], root.pivot[3]},
		mid = {root.mid[1], root.mid[2], root.mid[3]},
		tip = {root.tip[1], root.tip[2], root.tip[3]},
		flex = flex or vegetation_pivots.DEFAULT_ROOT_FLEX,
	}
end

function vegetation_pivots.FindRoot(entries, lod_level, flex)
	local pieces, seen = {}, {}

	for _, entry in ipairs(entries) do
		if entry.lod_level == lod_level then
			for _, vertex in ipairs(entry.vertices) do
				if vertex.pivot then
					add_piece(pieces, seen, vertex.pivot, vertex.chain_mid, vertex.chain_tip)
				end
			end
		end
	end

	return choose_root(pieces, flex)
end

local STIFFNESS_CHANNEL = 2

function vegetation_pivots.ComputeArray(vertices, vertex_count, indices, index_count, only_missing)
	local px, py, pz, stiffness = {}, {}, {}, {}

	for i = 1, vertex_count do
		local vertex = vertices[i - 1]
		local position = vertex.position
		px[i], py[i], pz[i] = position[0], position[1], position[2]
		stiffness[i] = vertex.vertex_color[STIFFNESS_CHANNEL]
	end

	local triangles = {}

	for i = 0, index_count - 1 do
		triangles[i + 1] = indices[i] + 1
	end

	local result = solve(vertex_count, px, py, pz, stiffness, triangles, index_count / 3)

	for i = 1, vertex_count do
		local vertex = vertices[i - 1]

		if result.pivot[1][i] and not (only_missing and vertex.pivot[3] > 0.5) then
			local pivot, mid, tip = vertex.pivot, vertex.chain_mid, vertex.chain_tip
			pivot[0], pivot[1], pivot[2], pivot[3] = result.pivot[1][i], result.pivot[2][i], result.pivot[3][i], 1
			mid[0], mid[1], mid[2] = result.mid[1][i], result.mid[2][i], result.mid[3][i]
			tip[0], tip[1], tip[2] = result.tip[1][i], result.tip[2][i], result.tip[3][i]
		end
	end

	return true
end

return vegetation_pivots
