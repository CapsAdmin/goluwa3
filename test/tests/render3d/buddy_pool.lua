local T = import("test/environment.lua")
local BuddyPool = import("goluwa/render3d/buddy_pool.lua")

T.Test("Buddy pool hands out rooms that are aligned to their size and do not overlap", function()
	local pool = BuddyPool.New(2 ^ 12, 2, 8)
	local taken = {}
	local rooms = {}
	math.randomseed(7)

	for _ = 1, 400 do
		local class = math.random(2, 8)
		local offset = pool:Alloc(class)

		if offset then
			T(offset % 2 ^ class)["=="](0)

			for slot = offset, offset + 2 ^ class - 1 do
				T(taken[slot])["=="](nil)
				taken[slot] = true
			end

			rooms[#rooms + 1] = {offset = offset, class = class}
		end
	end

	T(#rooms > 0)["=="](true)
end)

T.Test("Buddy pool makes a small room from the free space of bigger ones", function()
	local pool = BuddyPool.New(2 ^ 10, 2, 10)
	local big = pool:Alloc(10)
	T(pool:Alloc(2))["=="](nil)
	pool:Free(big, 10)
	local small = pool:Alloc(2)
	T(small)["~="](nil)
	local free = pool:GetFree()
	T(free)["=="](2 ^ 10 - 4)
end)

T.Test("Buddy pool puts a room back together when its buddies are free", function()
	local pool = BuddyPool.New(2 ^ 10, 2, 10)
	local rooms = {}

	for i = 1, 2 ^ 8 do
		rooms[i] = pool:Alloc(2)
		T(rooms[i])["~="](nil)
	end

	T(pool:Alloc(2))["=="](nil)

	-- the other way round than they were handed out
	for i = #rooms, 1, -1 do
		pool:Free(rooms[i], 2)
	end

	local free, by_class = pool:GetFree()
	T(free)["=="](2 ^ 10)
	T(by_class[10])["=="](1)
	T(pool:Alloc(10))["=="](0)
end)

T.Test("Buddy pool fills up as far as the slots go, whatever was freed in between", function()
	local pool = BuddyPool.New(2 ^ 12, 2, 8)
	local held = {}
	math.randomseed(11)

	for _ = 1, 3000 do
		if math.random() < 0.55 or #held == 0 then
			local class = math.random(2, 8)
			local offset = pool:Alloc(class)

			if offset then held[#held + 1] = {offset = offset, class = class} end
		else
			local entry = table.remove(held, math.random(#held))
			pool:Free(entry.offset, entry.class)
		end
	end

	for _, entry in ipairs(held) do
		pool:Free(entry.offset, entry.class)
	end

	local free, by_class = pool:GetFree()
	-- every block of the biggest class that was handed out is whole again, and nothing is held
	T(free)["=="](pool.Top)

	for class = 2, 7 do
		T(by_class[class])["=="](0)
	end

	for _ = 1, pool.Size / 2 ^ 8 do
		T(pool:Alloc(8))["~="](nil)
	end

	T(pool:Alloc(2))["=="](nil)
end)

T.Test("Buddy pool refuses a size that is not whole rooms", function()
	local ok = pcall(BuddyPool.New, 1000, 2, 8)
	T(ok)["=="](false)
end)
