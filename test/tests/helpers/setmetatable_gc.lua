local T = require("test.environment")
local setmetatable_with_gc = dofile("goluwa/helpers/setmetatable_gc.lua")

T.Test("setmetatable_gc triggers during runtime GC", function()
	local gc_called = false

	local function create_object()
		local t = {}
		local meta = {
			__gc = function(self)
				gc_called = true
			end,
		}
		setmetatable_with_gc(t, meta)
	end

	create_object()

	while not gc_called do
		collectgarbage("collect")
	end

	T(gc_called)["=="](true)
end)

T.Test("setmetatable_gc triggers for multiple objects", function()
	local gc_count = 0

	local function create_objects()
		for i = 1, 5 do
			local t = {id = i}
			local meta = {
				__gc = function(self)
					gc_count = gc_count + 1
				end,
			}
			setmetatable_with_gc(t, meta)
		end
	end

	create_objects()

	while gc_count ~= 5 do
		collectgarbage("collect")
	end

	T(gc_count == 5)["=="](true)
end)

T.Test("setmetatable_gc does not trigger for live objects", function()
	local gc_called = false
	local t = {}
	local meta = {
		__gc = function(self)
			gc_called = true
		end,
	}
	setmetatable_with_gc(t, meta)

	for i = 1, 100 do
		collectgarbage("collect")
	end

	T(not gc_called)["=="](true)
	-- Now let it go
	t = nil

	while not gc_called do
		collectgarbage("collect")
	end

	T(gc_called)["=="](true)
end)

T.Test("setmetatable_gc receives correct self", function()
	local received_value = nil

	local function create_object()
		local t = {secret = 42}
		local meta = {
			__gc = function(self)
				received_value = self.secret
			end,
		}
		setmetatable_with_gc(t, meta)
	end

	create_object()

	while not received_value do
		collectgarbage("collect")
	end

	T(received_value == 42)["=="](true)
end)
