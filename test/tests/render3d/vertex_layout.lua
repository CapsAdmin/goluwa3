local T = import("test/environment.lua")
local ffi = require("ffi")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local vegetation_pivots = import("goluwa/render3d/vegetation_pivots.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

T.Test("the vertex layout is tightly packed and every consumer reads it from there", function()
	local floats = 0

	for _, field in ipairs(vertex_layout.Fields) do
		T(field.float_offset)["=="](floats)
		T(ffi.offsetof(vertex_layout.Type, field.name))["=="](field.offset)
		floats = floats + field.count
	end

	T(vertex_layout.FloatStride)["=="](floats)
	T(ffi.sizeof(vertex_layout.Type))["=="](vertex_layout.Stride)
	T(vertex_layout.Stride)["=="](floats * 4)
	local binding = model_pipeline.GetVertexBufferBinding(0)
	T(binding.stride)["=="](vertex_layout.Stride)
	T(model_pipeline.GetVertexStride())["=="](vertex_layout.Stride)
	local attributes = model_pipeline.GetVertexAttributeLayout(0)
	T(#attributes)["=="](#vertex_layout.Fields)

	for i, field in ipairs(vertex_layout.Fields) do
		T(attributes[i].offset)["=="](field.offset)
		T(attributes[i].location)["=="](i - 1)
		T(attributes[i].format)["=="](field.format)
		T(model_pipeline.GetVertexAttributes()[i][1])["=="](field.name)
	end

	local defines = vertex_layout.BuildGlslDefines("TEST_VERTEX")
	T(
		defines:find("#define TEST_VERTEX_STRIDE " .. vertex_layout.FloatStride .. "u", 1, true)
	)["~="](nil)

	for _, field in ipairs(vertex_layout.Fields) do
		T(
			defines:find(
				"#define TEST_VERTEX_" .. field.alias .. " " .. field.float_offset .. "u",
				1,
				true
			)
		)["~="](nil)
	end

	local ok, err = pcall(vertex_layout.Get, "nope")
	T(ok)["=="](false)
	T(tostring(err))["contains"]("unknown vertex field")
end)

local function strip(stiffness_of, columns, rows)
	local vertices, indices = {}, {}

	for row = 0, rows do
		for column = 0, columns do
			local index = row * (columns + 1) + column + 1
			vertices[index] = {
				pos = Vec3(row * 0.5, 0, column * 0.1),
				vertex_color = {r = 0, g = 0, b = stiffness_of(row, rows), a = 1},
			}
		end
	end

	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local a = row * (columns + 1) + column + 1
			local b, c, d = a + 1, a + columns + 2, a + columns + 1
			indices[#indices + 1], indices[#indices + 2], indices[#indices + 3] = a, b, c
			indices[#indices + 1], indices[#indices + 2], indices[#indices + 3] = a, c, d
		end
	end

	return vertices, indices
end

T.Test("pivots of a branch are the centre of its stiff root, for every vertex of it", function()
	local vertices, indices = strip(function(row, rows)
		return 1 - row / rows
	end, 2, 8)
	T(vegetation_pivots.ComputeTables(vertices, indices))["=="](true)

	for _, vertex in ipairs(vertices) do
		T(vertex.pivot)["~="](nil)
		T(vertex.pivot[1])["=="](0)
		T(math.abs(vertex.pivot[3] - 0.1) < 1e-6)["=="](true)
	end
end)

T.Test("pieces that are not connected get their own pivots", function()
	local first_vertices, first_indices = strip(function(row, rows)
		return 1 - row / rows
	end, 1, 4)
	local second_vertices, second_indices = strip(function(row, rows)
		return 1 - row / rows
	end, 1, 4)
	local vertices, indices = {}, {}

	for i, vertex in ipairs(first_vertices) do
		vertices[i] = vertex
	end

	for i, vertex in ipairs(second_vertices) do
		vertices[#first_vertices + i] = {
			pos = Vec3(vertex.pos.x + 10, 5, vertex.pos.z),
			vertex_color = vertex.vertex_color,
		}
	end

	for _, index in ipairs(first_indices) do
		indices[#indices + 1] = index
	end

	for _, index in ipairs(second_indices) do
		indices[#indices + 1] = index + #first_vertices
	end

	vegetation_pivots.ComputeTables(vertices, indices)
	T(vertices[1].pivot[1])["=="](0)
	T(math.abs(vertices[#first_vertices + 1].pivot[1] - 10) < 1e-5)["=="](true)
	T(vertices[#first_vertices + 1].pivot[2])["=="](5)
	T(vertices[#first_vertices].pivot[2])["=="](0)
end)

T.Test("a piece without stiffness data turns about its lowest vertices", function()
	local vertices, indices = strip(function()
		return 1
	end, 1, 8)

	for row = 0, 8 do
		for column = 0, 1 do
			local pos = vertices[row * 2 + column + 1].pos
			pos.x, pos.y, pos.z = column * 0.1, row * 0.5, 0
		end
	end

	T(vegetation_pivots.ComputeTables(vertices, indices))["=="](true)

	for _, vertex in ipairs(vertices) do
		T(vertex.pivot)["~="](nil)
		T(math.abs(vertex.pivot[2]) < 1e-5)["=="](true)
		T(math.abs(vertex.chain_tip[2] - 4) < 1e-5)["=="](true)
		T(vertex.chain_mid[2] > 1.5 and vertex.chain_mid[2] < 2.5)["=="](true)
	end
end)

T.Test("vertices that share a position keep one piece across a seam", function()
	local vertices, indices = strip(function(row, rows)
		return 1 - row / rows
	end, 1, 4)
	local seam = #vertices + 1
	vertices[seam] = {
		pos = Vec3(vertices[6].pos.x, vertices[6].pos.y, vertices[6].pos.z),
		vertex_color = vertices[6].vertex_color,
	}

	for i = 1, #indices do
		if indices[i] == 6 and i > #indices / 2 then indices[i] = seam end
	end

	vegetation_pivots.ComputeTables(vertices, indices)
	T(vertices[seam].pivot[1])["=="](0)
end)

T.Test("pivots of a packed vertex array are written through the layout", function()
	local count = 6
	local vertices = vertex_layout.ArrayType(count)
	local indices = ffi.new("uint16_t[?]", 12)
	local positions = {{0, 0, 0}, {0, 0, 0.1}, {0.5, 0, 0}, {0.5, 0, 0.1}, {1, 0, 0}, {1, 0, 0.1}}
	local stiffness = {1, 1, 0.5, 0.5, 0, 0}

	for i = 1, count do
		local vertex = vertices[i - 1]
		vertex.position[0], vertex.position[1], vertex.position[2] = positions[i][1], positions[i][2], positions[i][3]
		vertex.vertex_color[2] = stiffness[i]
	end

	local quads = {0, 2, 3, 0, 3, 1, 2, 4, 5, 2, 5, 3}

	for i = 1, 12 do
		indices[i - 1] = quads[i]
	end

	T(vegetation_pivots.ComputeArray(vertices, count, indices, 12))["=="](true)

	for i = 0, count - 1 do
		T(vertices[i].pivot[3])["=="](1)
		T(math.abs(vertices[i].pivot[0] - 0) < 1e-6)["=="](true)
		T(math.abs(vertices[i].pivot[2] - 0.05) < 1e-6)["=="](true)
	end
end)

T.Test("the chain of a bent piece ends at its tip and passes through the bend", function()
	local vertices, indices = strip(function(row, rows)
		return 1 - row / rows
	end, 1, 8)

	for row = 0, 8 do
		for column = 0, 1 do
			local pos = vertices[row * 2 + column + 1].pos
			pos.y = row > 4 and (row - 4) * 0.5 or 0
		end
	end

	T(vegetation_pivots.ComputeTables(vertices, indices))["=="](true)
	local vertex = vertices[1]
	T(vertex.chain_tip)["~="](nil)
	T(math.abs(vertex.chain_tip[1] - 4) < 1e-5)["=="](true)
	T(math.abs(vertex.chain_tip[2] - 2) < 1e-5)["=="](true)
	T(vertex.chain_mid[1] > 1.8 and vertex.chain_mid[1] < 2.8)["=="](true)
	T(vertex.chain_mid[2] > 0 and vertex.chain_mid[2] < 1)["=="](true)

	for _, other in ipairs(vertices) do
		T(other.chain_tip[1])["=="](vertex.chain_tip[1])
		T(other.chain_mid[2])["=="](vertex.chain_mid[2])
	end
end)

local function piece(base, length, count)
	local vertices = {}

	for i = 1, count do
		local pivot = {base[1], base[2], base[3]}
		vertices[i] = {
			pivot = pivot,
			chain_mid = {base[1], base[2] + length * 0.5, base[3]},
			chain_tip = {base[1], base[2] + length, base[3]},
		}
	end

	return vertices
end

T.Test("the root of a model is its long piece at the lowest base", function()
	local trunk, crown, twig = piece({0, 0, 0}, 5, 3), piece({0, 5, 0}, 3, 4), piece({1, 0.1, 0}, 0.2, 2)
	local entries = {
		{lod_level = 0, vertices = crown},
		{lod_level = 0, vertices = trunk},
		{lod_level = 0, vertices = twig},
		{lod_level = 1, vertices = piece({0, 2, 0}, 1, 2)},
	}
	local root = vegetation_pivots.FindRoot(entries, 0)
	T(root)["~="](nil)
	T(root.pivot[2])["=="](0)
	T(root.tip[2])["=="](5)
	T(vegetation_pivots.FindRoot(entries, 1).pivot[2])["=="](2)
	T(vegetation_pivots.FindRoot(entries, 2))["=="](nil)
	T(vegetation_pivots.FindRoot({{lod_level = 0, vertices = twig}}, 0))["=="](nil)
end)

T.Test3D("a mesh builder writes the chain it was given into every vertex and the root into the mesh", function()
	local MeshBuilder = import("lua/foliage/mesh_builder.lua")
	local builder = MeshBuilder.New()
	builder:SetChain(0, 1, 0, 0.5, 1, 0, 1, 1, 0)
	builder:SetColor(0, 0, 1)
	local a = builder:Vertex(0, 1, 0, 0, 1, 0, 0, 0)
	local b = builder:Vertex(1, 1, 0, 0, 1, 0, 1, 0)
	local c = builder:Vertex(1, 2, 0, 0, 1, 0, 1, 1)
	builder:ClearChain()
	local loose = builder:Vertex(5, 5, 5, 0, 1, 0, 0, 0)
	builder:Triangle(a, b, c)
	builder:Triangle(a, c, loose)
	local root = {pivot = {0, 0, 0}, mid = {0, 1, 0}, tip = {0, 2, 0}, flex = 0.2}
	local polygon = builder:Build{root_chain = root}
	T(polygon:GetRootChain())["=="](root)
	local vertices = polygon.packed.vertices

	for i = 0, 2 do
		T(vertices[i].pivot[3])["=="](1)
		T(vertices[i].pivot[1])["=="](1)
		T(vertices[i].chain_mid[0])["=="](0.5)
		T(vertices[i].chain_tip[0])["=="](1)
	end

	T(builder.chain_vertices)["=="](3)
	T(vertices[3].pivot[3])["=="](1)
end)
