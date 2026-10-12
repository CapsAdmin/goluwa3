local T = import("test/environment.lua")
local fs = import("goluwa/filesystem/fs.lua")
local hotreload = import("goluwa/filesystem/watcher.lua")
local DIR = "tmp/hotreload_test/"
local files = {}

local function write(name, code)
	fs.create_directory_recursive(DIR)
	files[name] = true
	fs.write_file(DIR .. name .. ".lua", code)
end

local function load(name)
	return import(DIR .. name .. ".lua")
end

local function reload(name, code)
	write(name, code)
	_G.HOTRELOAD = true
	hotreload.ReloadModule(DIR .. name .. ".lua")
	_G.HOTRELOAD = nil
end

local function with_tracking(fn)
	local tracking = import.tracking
	import.tracking = true
	local ok, err = pcall(fn)
	import.tracking = tracking

	for name in pairs(files) do
		local path = DIR .. name .. ".lua"
		import.loaded[path] = nil
		import.imports[path] = nil
		import.importers[path] = nil
		import.strong[path] = nil
		import.snapshots[path] = nil
		fs.remove_file(path)
		files[name] = nil
	end

	if not ok then error(err, 0) end
end

T.Test("hotreload keeps the table, state and data but drops removed functions", function()
	with_tracking(function()
		write(
			"lib",
			[[
local lib = {}
lib.state = lib.state or {n = 0}
lib.counter = 0
function lib.A() return "a1" end
function lib.Stale() end
return lib
]]
		)
		local lib = load("lib")
		T(lib.A())["=="]("a1")
		lib.counter = 5
		lib.state.n = 3
		reload(
			"lib",
			[[
local lib = {}
lib.state = lib.state or {n = 0}
lib.counter = 0
function lib.A() return "a2" end
return lib
]]
		)
		T(load("lib"))["=="](lib)
		T(lib.A())["=="]("a2")
		T(lib.Stale)["=="](nil)
		T(lib.counter)["=="](5)
		T(lib.state.n)["=="](3)
	end)
end)

T.Test("hotreload keeps the table of a plain module and what it holds in locals", function()
	with_tracking(function()
		write(
			"plain",
			[[
local plain = {}
local device
plain.value = 1
function plain.SetDevice(d) device = d end
function plain.GetDevice() return device end
function plain.Get() return "v1" end
return plain
]]
		)
		local plain = load("plain")
		local device = {}
		plain.SetDevice(device)
		plain.value = 10
		reload(
			"plain",
			[[
local plain = {}
local device
plain.value = 1
function plain.SetDevice(d) device = d end
function plain.GetDevice() return device end
function plain.Get() return "v2" end
return plain
]]
		)
		T(load("plain"))["=="](plain)
		T(plain.Get())["=="]("v2")
		T(plain.value)["=="](10)
		T(plain.GetDevice())["=="](device)
	end)
end)

T.Test("hotreload loads modules again that used another one while loading", function()
	with_tracking(function()
		write("helper", "local helper = {}\nfunction helper.Text() return 'v1' end\nreturn helper")
		write(
			"consumer",
			[[
local helper = import("]] .. DIR .. [[helper.lua")
local baked = helper.Text()
local consumer = {}
function consumer.Baked() return baked end
return consumer
]]
		)
		write(
			"bystander",
			[[
local helper = import("]] .. DIR .. [[helper.lua")
local bystander = {}
bystander.loads = (_G.hotreload_test_loads or 0) + 1
_G.hotreload_test_loads = bystander.loads
function bystander.Text() return helper.Text() end
return bystander
]]
		)
		local consumer = load("consumer")
		local bystander = load("bystander")
		T(consumer.Baked())["=="]("v1")
		reload("helper", "local helper = {}\nfunction helper.Text() return 'v2' end\nreturn helper")
		T(load("consumer"))["=="](consumer)
		T(consumer.Baked())["=="]("v2")
		T(bystander.Text())["=="]("v2")
		T(_G.hotreload_test_loads)["=="](1)
		_G.hotreload_test_loads = nil
	end)
end)

T.Test("hotreload loads importers again when a module is replaced by a new value", function()
	with_tracking(function()
		write("values", "return {1, 2}")
		write(
			"holder",
			[[
local values = import("]] .. DIR .. [[values.lua")
local holder = {}
function holder.Second() return values[2] end
return holder
]]
		)
		local holder = load("holder")
		T(holder.Second())["=="](2)
		reload("values", "return {1, 3}")
		T(holder.Second())["=="](3)
	end)
end)

T.Test("hotreload keeps the old module when the new one fails", function()
	with_tracking(function()
		write("broken", "local broken = {}\nfunction broken.A() return 'ok' end\nreturn broken")
		local broken = load("broken")
		reload("broken", "local broken = library(\nfunction")
		T(broken.A())["=="]("ok")
		reload("broken", "local broken = {}\nbroken.B = 1\nerror('boom')")
		T(broken.A())["=="]("ok")
		T(load("broken"))["=="](broken)
	end)
end)
