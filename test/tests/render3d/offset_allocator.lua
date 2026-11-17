local T = import("test/environment.lua")
local OffsetAllocator = import("goluwa/render3d/offset_allocator.lua")

local function check_free_layout(pool, live)
	local used = 0

	for _, a in pairs(live) do
		used = used + a.size
	end

	local free, largest = pool:GetFree()
	T(free)["=="](pool.Size - used)
	T(largest <= free)["=="](true)
end

T.Test("Offset allocator hands out ranges that stay inside the pool and do not overlap", function()
	local pool = OffsetAllocator.New(100000)
	local live, taken = {}, {}
	math.randomseed(11)

	for id = 1, 600 do
		local size = math.random(1, 700)
		local offset, node = pool:Alloc(size)

		if offset then
			T(offset + size <= pool.Size)["=="](true)
			T(pool:GetSize(node))["=="](size)

			for at = offset, offset + size - 1 do
				T(taken[at])["=="](nil)
				taken[at] = id
			end

			live[id] = {offset = offset, size = size, node = node}
		end
	end

	check_free_layout(pool, live)
end)

T.Test("Offset allocator reuses and merges freed ranges under random churn", function()
	local pool = OffsetAllocator.New(1 << 20)
	local live, taken, ids = {}, {}, {}
	math.randomseed(5)

	for step = 1, 4000 do
		if #ids > 0 and math.random() < 0.45 then
			local at = math.random(#ids)
			local id = ids[at]
			ids[at] = ids[#ids]
			ids[#ids] = nil
			local a = live[id]

			for i = a.offset, a.offset + a.size - 1, 61 do
				taken[i] = nil
			end

			pool:Free(a.node)
			live[id] = nil
		else
			local size = math.random(1, 3) == 1 and math.random(1, 40000) or math.random(1, 400)
			local offset, node = pool:Alloc(size)

			if offset then
				for i = offset, offset + size - 1, 61 do
					T(taken[i])["=="](nil)
					taken[i] = step
				end

				live[step] = {offset = offset, size = size, node = node}
				ids[#ids + 1] = step
			end
		end

		if step % 500 == 0 then check_free_layout(pool, live) end
	end

	for _, id in ipairs(ids) do
		pool:Free(live[id].node)
	end

	local free, largest = pool:GetFree()
	T(free)["=="](1 << 20)
	T(largest)["=="](1 << 20)
	T(pool:Alloc(1 << 20))["=="](0)
end)

T.Test("Offset allocator returns exact sizes and merges everything back", function()
	local pool = OffsetAllocator.New(1 << 24)
	local live = {}

	for _, size in ipairs{1, 7, 8, 9, 100, 1000, 4097, 99999} do
		local offset, node = pool:Alloc(size)
		T(offset)["~="](nil)
		T(pool:GetSize(node))["=="](size)
		live[#live + 1] = node
	end

	for _, node in ipairs(live) do
		pool:Free(node)
	end

	T(select(2, pool:GetFree()))["=="](1 << 24)
end)

T.Test("Offset allocator grows by merging the new space into a free tail", function()
	local pool = OffsetAllocator.New(1024)
	local _, node_a = pool:Alloc(512)
	local _, node_b = pool:Alloc(512)
	T(pool:Alloc(1))["=="](nil)
	pool:Grow(1024)
	T(pool.Size)["=="](2048)
	local c, node_c = pool:Alloc(1024)
	T(c)["=="](1024)
	pool:Free(node_b)
	pool:Grow(512)
	local free, largest = pool:GetFree()
	T(free)["=="](1024)
	T(largest)["=="](512)
	pool:Free(node_a)
	pool:Free(node_c)
	local free, largest = pool:GetFree()
	T(free)["=="](2560)
	T(largest)["=="](2560)
	T(pool:Alloc(2560))["=="](0)
end)

T.Test("Offset allocator grows its node table past the first capacity", function()
	local pool = OffsetAllocator.New(1 << 22)
	local nodes = {}

	for i = 1, 2000 do
		local offset, node = pool:Alloc(8)
		T(offset)["=="]((i - 1) * 8)
		nodes[i] = node
	end

	for i = 1, 2000, 2 do
		pool:Free(nodes[i])
	end

	for i = 2, 2000, 2 do
		pool:Free(nodes[i])
	end

	T(select(2, pool:GetFree()))["=="](1 << 22)
end)
