local T = import("test/environment.lua")
local list = import("goluwa/list.lua")
local library = import("lua/particle_shader_library.lua")
local shaders = import("goluwa/render3d/particle_shaders.lua")

T.Test("particle shader library loads the shipped shaders, rejects bad updates and names duplicates", function()
	library.Init()
	T(not not table.has_value(library.Names, "snow"))["=="](true)
	T(not not table.has_value(library.Names, "glow"))["=="](true)
	local defaults = library.GetDefaults("snow")
	T(defaults.Sway)["=="](0.35)
	T(defaults.Wind[1])["=="](0.05)
	T(defaults.Flake)["=="]("snowflake")
	T(shaders.GetSpriteParam("snow"))["=="]("Flake")
	local data = table.copy(library.Files.Source.snow)
	data.Params[2].Name = "Flake"
	local ok = pcall(library.Update, "snow", data)
	T(ok)["=="](false)
	T(library.GetStatus("snow") ~= nil)["=="](true)
	T(library.GetDefaults("snow").Sway)["=="](0.35)
	T(library.Files.Source.snow.Params[2].Name)["=="]("Sway")
	T(library.GetNewName("snow"))["=="]("snow_2")
	library.Create("snow_2", "snow")
	T(not not table.has_value(library.Names, "snow_2"))["=="](true)
	T(library.GetNewName("snow"))["=="]("snow_3")
	T(#library.GetParams("snow_2"))["=="](#library.GetParams("snow"))
	shaders.Remove("snow_2")
	list.remove_value(library.Names, "snow_2")
	library.Files.Source.snow_2 = nil
end)

T.Test("particle shader params pack into the emitter block in declaration order", function()
	library.Init()
	local target = {}

	for i = 0, 3 do
		target[i] = {[0] = 0, 0, 0, 0}
	end

	shaders.WriteParams("snow", {Sway = 2, Wind = {1, 2, 3}}, target)
	local entry = shaders.Get("snow")
	local offsets = {}

	for _, item in ipairs(entry.layout) do
		offsets[item.param.Name] = item.offset
	end

	local function read(name, component)
		local slot = offsets[name] + component
		return target[math.floor(slot / 4)][slot % 4]
	end

	T(read("Sway", 0))["=="](2)
	T(read("SwayRate", 0))["=="](1.2)
	T(read("Wind", 0))["=="](1)
	T(read("Wind", 2))["=="](3)
	T(offsets.Flake)["=="](nil)
end)
