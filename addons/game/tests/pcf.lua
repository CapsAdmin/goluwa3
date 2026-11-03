local T = import("test/environment.lua")
local pcf = import("lua/pcf.lua")
local emitter_data = import("goluwa/render3d/emitter_data.lua")

local function build(operators, properties)
	local strings, string_index = {}, {}

	local function intern(text)
		if not string_index[text] then
			strings[#strings + 1] = text
			string_index[text] = #strings - 1
		end

		return string_index[text]
	end

	local function u16(value)
		return string.char(value % 256, math.floor(value / 256))
	end

	local function i32(value)
		return string.char(
			value % 256,
			math.floor(value / 256) % 256,
			math.floor(value / 65536) % 256,
			math.floor(value / 16777216) % 256
		)
	end

	local function f32(value)
		return require("ffi").string(require("ffi").new("float[1]", value), 4)
	end

	local function attribute(name, kind, payload)
		return u16(intern(name)) .. string.char(kind) .. payload
	end

	local function text(value)
		return value .. "\0"
	end

	local function vec3(x, y, z)
		return f32(x) .. f32(y) .. f32(z)
	end

	local elements = {
		{type = "DmElement", name = "root"},
		{type = "DmeParticleSystemDefinition", name = "test_system"},
	}
	local lists = {}

	for category, list in pairs(operators) do
		lists[category] = {}

		for _, operator in ipairs(list) do
			elements[#elements + 1] = {
				type = "DmeParticleOperator",
				name = operator.name,
				attributes = {attribute("functionName", 5, text(operator.name))},
			}

			for _, extra in ipairs(operator.attributes or {}) do
				table.insert(elements[#elements].attributes, attribute(extra[1], extra[2], extra[3]))
			end

			lists[category][#lists[category] + 1] = #elements - 1
		end
	end

	elements[1].attributes = {attribute("particleSystemDefinitions", 15, i32(1) .. i32(1))}
	local system_attributes = {}

	for name, kind_payload in pairs(properties) do
		system_attributes[#system_attributes + 1] = attribute(name, kind_payload[1], kind_payload[2])
	end

	for category, indices in pairs(lists) do
		local payload = i32(#indices)

		for _, index in ipairs(indices) do
			payload = payload .. i32(index)
		end

		system_attributes[#system_attributes + 1] = attribute(category, 15, payload)
	end

	elements[2].attributes = system_attributes
	local out = {"<!-- dmx encoding binary 2 format pcf 1 -->\n\0"}

	for _, element in ipairs(elements) do
		intern(element.type)
	end

	local body = {}

	for _, element in ipairs(elements) do
		body[#body + 1] = u16(intern(element.type)) .. text(element.name) .. string.rep("\0", 16)
	end

	local attribute_data = {}

	for _, element in ipairs(elements) do
		attribute_data[#attribute_data + 1] = i32(#element.attributes) .. table.concat(element.attributes)
	end

	out[#out + 1] = u16(#strings)

	for _, value in ipairs(strings) do
		out[#out + 1] = text(value)
	end

	out[#out + 1] = i32(#elements)
	out[#out + 1] = table.concat(body)
	out[#out + 1] = table.concat(attribute_data)
	return table.concat(out), {f32 = f32, i32 = i32, text = text, vec3 = vec3}
end

T.Test("a pcf system parses its operators and converts them to a gpu emitter", function()
	local _, pack = build({}, {})
	local f32, i32, text, vec3 = pack.f32, pack.i32, pack.text, pack.vec3
	local data = build(
		{
			emitters = {{name = "emit_continuously", attributes = {{"emission_rate", 3, f32(20)}}}},
			initializers = {
				{
					name = "Lifetime Random",
					attributes = {{"lifetime_min", 3, f32(1)}, {"lifetime_max", 3, f32(2)}},
				},
				{
					name = "Radius Random",
					attributes = {{"radius_min", 3, f32(10)}, {"radius_max", 3, f32(20)}},
				},
				{
					name = "Color Random",
					attributes = {{"color1", 8, "\255\0\0\255"}, {"color2", 8, "\0\0\255\255"}},
				},
				{
					name = "Position Within Sphere Random",
					attributes = {
						{"distance_max", 3, f32(10)},
						{"speed_in_local_coordinate_system_min", 10, vec3(0, 0, 50)},
						{"speed_in_local_coordinate_system_max", 10, vec3(0, 0, 100)},
					},
				},
				{
					name = "Rotation Yaw Flip Random",
					attributes = {{"Flip Percentage", 3, f32(0.25)}},
				},
				{
					name = "Velocity Noise",
					attributes = {{"output minimum", 10, vec3(0, 0, 10)}, {"output maximum", 10, vec3(0, 0, 20)}},
				},
				{name = "Mystery Operator"},
			},
			operators = {
				{
					name = "Movement Basic",
					attributes = {{"gravity", 10, vec3(0, 0, -386.4)}, {"drag", 3, f32(0.5)}},
				},
				{
					name = "Radius Scale",
					attributes = {
						{"radius_start_scale", 3, f32(1)},
						{"radius_end_scale", 3, f32(3)},
						{"scale_bias", 3, f32(0.5)},
					},
				},
				{
					name = "Alpha Fade Out Random",
					attributes = {{"fade out time min", 3, f32(0.5)}, {"fade out time max", 3, f32(0.5)}},
				},
				{
					name = "Lifespan Minimum Velocity Decay",
					attributes = {{"minimum velocity", 3, f32(10)}},
				},
			},
			forces = {
				{
					name = "twist around axis",
					attributes = {{"amount of force", 3, f32(100)}, {"twist axis", 10, vec3(0, 0, 1)}},
				},
			},
			renderers = {
				{
					name = "render_animated_sprites",
					attributes = {{"orientation_type", 2, i32(2)}},
				},
			},
		},
		{
			max_particles = {2, i32(300)},
			material = {5, text("particle\\smoke1\\smoke1.vmt")},
			radius = {3, f32(5)},
			color = {8, "\255\255\255\255"},
		}
	)
	local systems = pcf.Parse(data)
	T(#systems)["=="](1)
	T(systems[1].name)["=="]("test_system")
	T(systems[1].properties.max_particles)["=="](300)
	T(#systems[1].operators.initializers)["=="](7)
	T(systems[1].operators.initializers[3].color1[1])["=="](255)
	T(systems[1].operators.operators[1].gravity[3] < -386)["=="](true)
	local converted, notes = pcf.Convert(systems[1])
	T(converted.MaxParticles)["=="](300)
	T(converted.Rate)["=="](20)
	T(converted.Lifetime[1])["=="](1)
	T(converted.Lifetime[2])["=="](2)
	T(math.abs(converted.GravityScale - 386.4 * 0.0254 / 9.81) < 1e-3)["=="](true)
	T(converted.Drag)["=="](0.5)
	T(converted.Shape)["=="]("sphere")
	T(math.abs(converted.ShapeSize[1] - 0.508) < 1e-4)["=="](true)
	T(math.abs(converted.Speed[1] - 60 * 0.0254) < 1e-4)["=="](true)
	T(math.abs(converted.Speed[2] - 120 * 0.0254) < 1e-4)["=="](true)
	T(notes["Velocity Noise"])["=="](nil)
	T(converted.FlipRandom)["=="](0.25)
	T(math.abs(converted.MinSpeed - 0.254) < 1e-4)["=="](true)
	T(math.abs(converted.Swirl - 2.54) < 1e-4)["=="](true)
	T(converted.Orientation)["=="]("ground")
	T(converted.Lit)["=="](true)
	T(converted.ShaderParams.Sprite)["=="]("smoke")
	T(math.abs(converted.Size.Keys[1][2] - 10 * 2 * 0.0254) < 1e-4)["=="](true)
	T(math.abs(converted.Size.Keys[#converted.Size.Keys][2] - 10 * 2 * 3 * 0.0254) < 1e-4)["=="](true)
	T(math.abs(converted.Size.MaxKeys[1][2] - 20 * 2 * 0.0254) < 1e-4)["=="](true)
	T(converted.Color.Keys[1][2][1])["=="](1)
	T(converted.Color.MaxKeys[1][2][3])["=="](1)
	local last = converted.Color.Keys[#converted.Color.Keys]
	T(last[1])["=="](1)
	T(last[2][4])["=="](0)
	T(notes["Mystery Operator"])["=="](1)
	T(pcf.DescribeNotes(systems[1], notes):find("Mystery Operator", 1, true) ~= nil)["=="](true)
	emitter_data.Set("pcf_test", converted)
	T(emitter_data.Has("pcf_test"))["=="](true)
end)

T.Test("a pcf material gives the emitter its sprite sheet texture, its sequence range and its blend", function()
	pcf.SetMaterial(
		"particle\\sheet_test.vmt",
		{
			texture = "materials/particle/sheet_test.vtf",
			additive = true,
			overbright = 3.5,
			sheet = {sequences = {{time = 0.5}, {time = 1.5}, {time = 2.5}}},
		}
	)
	local system = {
		name = "sheet_system",
		properties = {material = "particle\\sheet_test.vmt", max_particles = 10},
		operators = {
			initializers = {
				{name = "Sequence Random", sequence_min = 1, sequence_max = 2},
				{name = "lifetime from sequence"},
			},
			emitters = {{name = "emit_continuously", emission_rate = 5}},
		},
		children = {},
	}
	local data = pcf.Convert(system)
	T(data.Shader)["=="]("sprite")
	T(data.ShaderParams.Sprite)["=="]("materials/particle/sheet_test.vtf")
	T(data.Sequence[1])["=="](1)
	T(data.Sequence[2])["=="](2)
	T(data.Lifetime[1])["=="](1.5)
	T(data.Lit)["=="](false)
	T(data.Emissive)["=="](120000)
	T(data.AlphaFromColor)["=="](true)
	pcf.SetMaterial(
		"particle\\sheet_test.vmt",
		{texture = "materials/particle/sheet_test.vtf", additive = false, overbright = 1}
	)
	data = pcf.Convert(system)
	T(data.Lit)["=="](true)
	T(data.Emissive)["=="](0)
	T(data.AlphaFromColor)["=="](nil)
	pcf.ClearMaterials()
end)
