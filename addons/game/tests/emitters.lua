local T = import("test/environment.lua")
local list = import("goluwa/list.lua")
local Color = import("goluwa/structs/color.lua")
local emitters = import("lua/emitters.lua")

T.Test("emitters load the shipped files, hand out realized copies and name duplicates", function()
	for _, name in ipairs{
		"hit_position",
		"hit_normal",
		"hit_force",
		"muzzle_flash",
		"tool_hit",
		"melee_sparks",
	} do
		T(not not table.has_value(emitters.Names, name))["=="](true)
	end

	local properties = emitters.Get("melee_sparks")
	T(properties.RatePerMeter)["=="](20)
	T(properties.Color.Keys[1][2][1])["=="](1)
	T(properties.Color.Keys[2][2].a)["=="](0)
	properties.RatePerMeter = 5
	properties.Color.Keys[1][2][1] = 0.5
	T(emitters.Files.Source.melee_sparks.RatePerMeter)["=="](20)
	T(emitters.Files.Source.melee_sparks.Color.Keys[1][2][1])["=="](1)
	T(emitters.GetNewName("tool_hit"))["=="]("tool_hit_2")
	emitters.Create("tool_hit_2", "tool_hit")
	T(not not table.has_value(emitters.Names, "tool_hit_2"))["=="](true)
	T(emitters.GetNewName("tool_hit"))["=="]("tool_hit_3")
	T(emitters.Get("tool_hit_2").Speed[2])["=="](emitters.Get("tool_hit").Speed[2])
	list.remove_value(emitters.Names, "tool_hit_2")
	emitters.Files.Source.tool_hit_2 = nil
end)

T.Test("emitter inputs set, scale and add properties and fall back to their defaults", function()
	T(emitters.Get("hit_force").Inputs)["=="](nil)
	T(emitters.Get("hit_force").Speed[2])["=="](3)
	T(emitters.Get("hit_force").Speed[1])["=="](0.1)
	T(emitters.Get("hit_force", {Strength = 7}).Speed[2])["=="](7)
	T(emitters.Files.Source.hit_force.Inputs.Strength.Default)["=="](3)
	local tinted = emitters.Get("melee_sparks", {Tint = Color(0.2, 0.4, 0.6, 1)})
	T(tinted.Color.Keys[2][2].r)["=="](0.2)
	T(tinted.Color.Keys[2][2].b)["=="](0.6)
	T(tinted.Color.Keys[2][2].a)["=="](0)
	T(tinted.Color.Keys[1][2][1])["=="](1)
	T(emitters.Get("melee_sparks").Color.Keys[2][2].r)["=="](1)
	local ok = pcall(emitters.Get, "hit_force", {Nope = 1})
	T(ok)["=="](false)
	T(emitters.GetBurstKey("hit_force"))["=="]("hit_force")
	T(emitters.GetBurstKey("hit_force", {}))["=="]("hit_force")
	T(emitters.GetBurstKey("hit_force", {Strength = 7}))["=="]("hit_force:Strength=7")
	local data = table.copy(emitters.Files.Source.hit_force)
	data.Inputs = {
		Size = {Default = 2, Targets = {{"Size", "scale"}}},
		Lift = {Default = 0.5, Targets = {{"Drag", "add"}}},
	}
	emitters.Update("input_test", data)
	local properties = emitters.Get("input_test")
	T(properties.Size)["=="](0.03)
	T(properties.Drag)["=="](0.5)
	T(emitters.Get("input_test", {Size = 1, Lift = 0}).Size)["=="](0.015)
	local curved = table.copy(data)
	curved.Size = {Keys = {{0, 0.1}, {1, 0.4}}}
	emitters.Update("input_curve", curved)
	local scaled_curve = emitters.Get("input_curve", {Size = 2, Lift = 0}).Size
	T(scaled_curve.Keys[1][2])["=="](0.2)
	T(scaled_curve.Keys[2][2])["=="](0.8)
	list.remove_value(emitters.Names, "input_curve")
	emitters.Files.Source.input_curve = nil
	data.Inputs.Size.Targets[1][2] = "nope"
	T(pcall(emitters.Update, "input_test", data))["=="](false)
	T(emitters.Files.Source.input_test.Inputs.Size.Targets[1][2])["=="]("scale")
	local list = import("goluwa/list.lua")
	list.remove_value(emitters.Names, "input_test")
	emitters.Files.Source.input_test = nil
end)

T.Test("emitter inputs fall back to the component default of a property the file leaves out", function()
	local data = {
		MaxParticles = 8,
		Inputs = {Tint = {DefaultColor = {1, 0, 0, 1}, Targets = {{"Color", "set_last"}}}},
	}
	emitters.Update("default_fallback", data)
	local properties = emitters.Get("default_fallback", {Tint = Color(0, 1, 0, 1)})
	T(properties.Color.Keys[2][2].g)["=="](1)
	T(properties.Color.Keys[2][2].a)["=="](0)
	T(properties.Color.Keys[1][2].a)["=="](1)
	T(emitters.Get("default_fallback").Color.Keys[2][2].r)["=="](1)
	local scaled = {Drag = nil, Inputs = {Strength = {Default = 3, Targets = {{"Drag", "scale"}}}}}
	emitters.Update("default_fallback", scaled)
	T(math.abs(emitters.Get("default_fallback").Drag - 0.3) < 1e-9)["=="](true)
	local list = import("goluwa/list.lua")
	list.remove_value(emitters.Names, "default_fallback")
	emitters.Files.Source.default_fallback = nil
end)

T.Test("emitters reject values the emitter component would reject, and keep the last good data", function()
	local good = table.copy(emitters.Files.Source.tool_hit)

	local function rejected(change)
		local data = table.copy(good)
		change(data)
		local ok = pcall(emitters.Update, "tool_hit", data)
		T(emitters.Files.Source.tool_hit.MaxParticles)["=="](good.MaxParticles)
		return not ok
	end

	T(rejected(function(data)
		data.MaxParticles = 100.5
	end))["=="](true)
	T(rejected(function(data)
		data.MaxParticles = 0
	end))["=="](true)
	T(rejected(function(data)
		data.MaxParticles = 100000
	end))["=="](true)
	T(rejected(function(data)
		data.Shape = "blob"
	end))["=="](true)
	T(rejected(function(data)
		data.Lit = "yes"
	end))["=="](true)
	T(rejected(function(data)
		data.Drag = {1}
	end))["=="](true)
	T(rejected(function(data)
		data.Rate = {1, 2}
	end))["=="](true)
	T(rejected(function(data)
		data.NotAProperty = 1
	end))["=="](true)
	local data = table.copy(good)
	data.MaxParticles = 128
	data.Drag = {1, 2}
	T(pcall(emitters.Update, "tool_hit", data))["=="](true)
	emitters.Update("tool_hit", good)
end)
