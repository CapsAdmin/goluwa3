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

T.Test("a particle shader source defines the hook functions it wants and the rest are left out", function()
	local shader_module = import("goluwa/render3d/particle_shaders.lua")
	local ok = pcall(shader_module.Register, "test_none", {Source = "float helper() { return 1.0; }"})
	T(ok)["=="](false)
	ok = pcall(
		shader_module.Register,
		"test_comment",
		{
			Source = "// void update(emitters_t e, uint index, float dt, float t, inout Particle p) {}\n/* float visibility(emitters_t e, uint index, float t, Particle p) { return 1.0; } */",
		}
	)
	T(ok)["=="](false)
	ok = pcall(
		shader_module.Register,
		"test_reserved",
		{
			Params = {{Name = "update", Type = "float", Default = 1}},
			Source = "float visibility(emitters_t e, uint index, float t, Particle p) { return 1.0; }",
		}
	)
	T(ok)["=="](false)
	shader_module.Register(
		"test_visibility",
		{
			Params = {
				{Name = "Gain", Type = "float", Default = 2},
				{Name = "Tilt", Type = "vec3", Default = {0, 1, 0}},
			},
			Source = "float helper(emitters_t e) { return Gain; }\nfloat visibility(emitters_t e, uint index, float t, Particle p) { return helper(e) * Tilt.y; }",
		}
	)
	shader_module.Register(
		"test_update",
		{
			Source = "void update(emitters_t e, uint index, float dt, float t, inout Particle p) {\n}\nvoid shade(emitters_t e, uint index, float t, inout Particle p) {}",
		}
	)
	local glsl = shader_module.GetGLSL()
	local id = shader_module.GetId("test_visibility")
	local other = shader_module.GetId("test_update")
	T(glsl:find("#define visibility shader_" .. id .. "_visibility", 1, true) ~= nil)["=="](true)
	T(glsl:find("#define Gain (e.params[0].x)", 1, true) ~= nil)["=="](true)
	T(
		glsl:find("#define Tilt (vec3(e.params[0].y, e.params[0].z, e.params[0].w))", 1, true) ~= nil
	)["=="](true)
	T(glsl:find("#undef Gain", 1, true) ~= nil)["=="](true)
	T(glsl:find("#line 1 " .. id .. "\n", 1, true) ~= nil)["=="](true)
	T(glsl:find("shader_" .. id .. "_update", 1, true) == nil)["=="](true)
	T(
		glsl:find(
				"case " .. other .. ": shader_" .. other .. "_update(e, index, dt, t, p); break;",
				1,
				true
			) ~= nil
	)["=="](true)
	T(
		glsl:find(
				"case " .. id .. ": return shader_" .. id .. "_visibility(e, index, t, p);",
				1,
				true
			) ~= nil
	)["=="](true)
	T(glsl:find("case " .. id .. ": shader_" .. id .. "_spawn", 1, true) == nil)["=="](true)
	T(shader_module.ParseError("0:3: error: foo\n"))["=="]("0:3: error: foo\n")
	T(shader_module.ParseError(id .. ":2: error: 'x' : undeclared identifier\n"))["=="]("test_visibility line 2: 'x' : undeclared identifier")
	shader_module.Remove("test_visibility")
	shader_module.Remove("test_update")
end)
