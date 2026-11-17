local T = import("test/environment.lua")
local ffi = require("ffi")
local system = import("goluwa/system.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local UInt32Array = ffi.typeof("uint32_t[?]")

local function new_index_buffer(count, seed)
	local data = UInt32Array(count)

	for i = 0, count - 1 do
		data[i] = seed + i
	end

	return {
		GetIndexCount = function()
			return count
		end,
		GetData = function()
			return data
		end,
		GetIndexTypeFFI = function()
			return "uint32_t"
		end,
	}
end

T.Test3D("Index pool keeps ranges apart, grows, and reuses freed ranges", function()
	local real_frame = system.GetFrameNumber
	local frame = 1000
	system.GetFrameNumber = function()
		return frame
	end
	local ok, err = pcall(function()
		local count = 150000
		local live = {}

		for i = 1, 14 do
			live[i] = new_index_buffer(count, i * 1000000)
			live[i].first = index_pool.GetFirstIndex(live[i])
		end

		local pointer = ffi.cast("uint32_t *", index_pool.GetBuffer():Map())
		local grown = index_pool.GetBuffer()

		for i = 1, 14 do
			for _, at in ipairs{0, 1, count - 1} do
				T(pointer[live[i].first + at])["=="](i * 1000000 + at)
			end

			for j = i + 1, 14 do
				local a, b = live[i].first, live[j].first
				T(a + count <= b or b + count <= a)["=="](true)
			end
		end

		live = nil
		collectgarbage()
		collectgarbage()
		frame = frame + 32
		local reused = new_index_buffer(count * 8, 5)
		T(index_pool.GetFirstIndex(reused))["<"](count * 14)
		T(index_pool.GetBuffer())["=="](grown)
	end)
	system.GetFrameNumber = real_frame
	assert(ok, err)
end)
