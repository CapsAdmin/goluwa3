local solve_order = {}
local STATIC_PAIR_DROP = 0.25
local BUCKET_FACTOR = 8

local function movable(body)
	return body.InverseMass > 0 and body.MotionType == "dynamic"
end

-- Gauss-Seidel carries a stack's weight down only as far as one sweep reaches, so contacts are
-- solved from the top of the pile (along gravity) to the bottom, static contacts a bit later.
function solve_order.Build(island, up_x, up_y, up_z)
	local pairs = island.pairs
	local count = #pairs
	local order = island.solve_pairs

	if not order then
		order = {}
		island.solve_pairs = order
		island.solve_keys = {}
		island.solve_buckets = {}
	end

	local keys = island.solve_keys
	local min_key, max_key = math.huge, -math.huge

	for i = 1, count do
		local body_a = pairs[i].entry_a.body
		local body_b = pairs[i].entry_b.body
		local key

		if movable(body_a) then
			key = body_a.Position.x * up_x + body_a.Position.y * up_y + body_a.Position.z * up_z

			if movable(body_b) then
				local other = body_b.Position.x * up_x + body_b.Position.y * up_y + body_b.Position.z * up_z

				if other < key then key = other end
			else
				key = key - STATIC_PAIR_DROP
			end
		else
			key = body_b.Position.x * up_x + body_b.Position.y * up_y + body_b.Position.z * up_z - STATIC_PAIR_DROP
		end

		keys[i] = key

		if key < min_key then min_key = key end

		if key > max_key then max_key = key end
	end

	for i = count + 1, #order do
		order[i] = nil
	end

	if count < 2 or max_key - min_key < 1e-4 then
		for i = 1, count do
			order[i] = pairs[i]
		end

		return order
	end

	local buckets = island.solve_buckets
	local bucket_count = count * BUCKET_FACTOR
	local scale = (bucket_count - 1) / (max_key - min_key)

	for i = 1, bucket_count + 1 do
		buckets[i] = 0
	end

	for i = 1, count do
		local bucket = ((max_key - keys[i]) * scale) % bucket_count + 1
		bucket = bucket - bucket % 1
		keys[i] = bucket
		buckets[bucket + 1] = buckets[bucket + 1] + 1
	end

	for i = 2, bucket_count + 1 do
		buckets[i] = buckets[i] + buckets[i - 1]
	end

	for i = 1, count do
		local bucket = keys[i]
		local slot = buckets[bucket] + 1
		buckets[bucket] = slot
		order[slot] = pairs[i]
	end

	return order
end

return solve_order
