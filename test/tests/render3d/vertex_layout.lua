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
	local bindings = model_pipeline.GetVertexBindings()
	T(#bindings)["=="](2)
	T(bindings[1].binding)["=="](0)
	T(bindings[2].binding)["=="](vertex_layout.EXTRAS_BINDING)
	T(#bindings[1].attributes + #bindings[2].attributes)["=="](#vertex_layout.Fields)
	local at = 0

	for _, binding in ipairs(bindings) do
		for _, attribute in ipairs(binding.attributes) do
			at = at + 1
			local field = vertex_layout.Fields[at]
			T(attribute[1])["=="]((field.packing and "packed_" or "") .. field.name)
			T(attribute[3])["=="](field.gpu_format)
		end
	end

	local readable = vertex_layout.BuildGlslAccessors("test_vertex", "TestVertexData")
	local writable = vertex_layout.BuildGlslAccessors("test_vertex", "TestVertexData", true)

	for _, field in ipairs(vertex_layout.Fields) do
		local name = field.alias:lower()
		T(
			readable:find(field.glsl .. " test_vertex_" .. name .. "(TestVertexData b, uint vertex)", 1, true)
		)["~="](nil)
		T(readable:find("test_vertex_set_" .. name .. "(", 1, true))["=="](nil)
		T(
			writable:find(
				"void test_vertex_set_" .. name .. "(TestVertexData b, uint vertex, " .. field.glsl .. " value)",
				1,
				true
			)
		)["~="](nil)

		if field.packing then
			T(
				readable:find(
					"floatBitsToUint(b.v[vertex * " .. vertex_layout.CoreFloatStride .. "u + " .. field.group_float_offset .. "u])",
					1,
					true
				)
			)["~="](nil)
		else
			for i = 0, field.count - 1 do
				T(
					readable:find(
						"b.v[vertex * " .. (
								field.group == "core" and
								vertex_layout.CoreFloatStride or
								vertex_layout.ExtrasFloatStride
							) .. "u + " .. field.group_float_offset + i .. "u]",
						1,
						true
					)
				)["~="](nil)
			end
		end
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

T.Test3D("grass blades and crossed cards state their own skeleton unless the caller already has one", function()
	import("lua/foliage/foliage.lua")
	local MeshBuilder = import("lua/foliage/mesh_builder.lua")
	local grass = import("lua/foliage/grass.lua")
	local Random = import("lua/foliage/random.lua")
	local builder = MeshBuilder.New()
	local root = Vec3(1, 0.5, 2)
	grass.AddBlade(builder, root, Vec3(1, 0, 0), 1, 0.05, 0.3, 0.1, 0, 4, 0, 1, 0)
	T(builder:GetChain())["=="](nil)
	local blade_vertices = builder:GetVertexCount()
	grass.AddCrossedCards(builder, Vec3(-1, 0, 0), Vec3(0, 1, 0), 0.6, 1, 0, 1, 0, 1, Random.New(1))
	T(builder:GetChain())["=="](nil)
	local polygon = builder:Build{}
	local vertices = polygon.packed.vertices
	T(builder.chain_vertices)["=="](builder:GetVertexCount())

	for i = 0, blade_vertices - 1 do
		T(vertices[i].pivot[3])["=="](1)
		T(math.abs(vertices[i].pivot[0] - 1) < 1e-5)["=="](true)
		T(math.abs(vertices[i].pivot[1] - 0.5) < 1e-5)["=="](true)
		T(math.abs(vertices[i].pivot[2] - 2) < 1e-5)["=="](true)
		T(math.abs(vertices[i].chain_tip[0] - 1.3) < 1e-5)["=="](true)
		T(math.abs(vertices[i].chain_tip[1] - 1.4) < 1e-5)["=="](true)
		T(vertices[i].chain_mid[1] > 0.5 and vertices[i].chain_mid[1] < 1.4)["=="](true)
	end

	for i = blade_vertices, builder:GetVertexCount() - 1 do
		T(vertices[i].pivot[1])["=="](0)
		T(math.abs(vertices[i].chain_tip[1] - 0.6) < 1e-5)["=="](true)
		T(math.abs(vertices[i].chain_mid[1] - 0.3) < 1e-5)["=="](true)
	end

	local owned = MeshBuilder.New()
	owned:SetChain(9, 9, 9, 8, 8, 8, 7, 7, 7)
	local outer = owned:GetChain()
	grass.AddBlade(owned, root, Vec3(1, 0, 0), 1, 0.05, 0.3, 0.1, 0, 4, 0, 1, 0)
	grass.AddCrossedCards(owned, Vec3(-1, 0, 0), Vec3(0, 1, 0), 0.6, 1, 0, 1, 0, 1, Random.New(1))
	T(owned:GetChain())["=="](outer)
	local owned_vertices = owned:Build{}.packed.vertices

	for i = 0, owned:GetVertexCount() - 1 do
		T(owned_vertices[i].pivot[0])["=="](9)
		T(owned_vertices[i].chain_tip[0])["=="](7)
	end
end)

T.Test("the vertex layout splits into a core and an extras group", function()
	local ffi = require("ffi")
	T(vertex_layout.CoreStride)["=="](28)
	T(vertex_layout.CPUCoreStride + vertex_layout.ExtrasStride)["=="](vertex_layout.Stride)
	local core_names = {}

	for _, field in ipairs(vertex_layout.Fields) do
		if field.group == "core" then
			core_names[#core_names + 1] = field.name
		else
			T(field.group_offset)["=="](field.offset - vertex_layout.CPUCoreStride)
		end
	end

	T(table.concat(core_names, ","))["=="]("position,normal,uv,tangent")

	for _, group in ipairs{"core", "extras"} do
		local attributes = vertex_layout.GetAttributes(5, group)
		local shader = vertex_layout.GetShaderAttributes(group)
		T(#attributes)["=="](#shader)
		T(attributes[1].binding)["=="](5)
		T(attributes[1].offset)["=="](0)
	end

	local count = 5
	local vertices = vertex_layout.ArrayType(count)

	for i = 0, count - 1 do
		vertices[i].position[0] = i
		vertices[i].tangent[3] = 1
		vertices[i].vertex_color[0], vertices[i].vertex_color[1], vertices[i].vertex_color[2], vertices[i].vertex_color[3] = 1, 1, 1, 1
		vertices[i].pivot[3] = 0
	end

	local uniform = vertex_layout.GetUniformExtras(vertices, count)
	T(#uniform)["=="](vertex_layout.ExtrasStride)
	local core, extras = vertex_layout.Split(vertices, count, true)
	T(select(2, vertex_layout.Split(vertices, count)))["=="](nil)
	T(ffi.sizeof(core))["=="](count * vertex_layout.CoreStride)
	T(ffi.sizeof(extras))["=="](count * vertex_layout.ExtrasStride)
	T(ffi.cast("const float *", core)[3 * vertex_layout.CoreFloatStride])["=="](3)
	T(ffi.string(extras + 2 * vertex_layout.ExtrasStride, vertex_layout.ExtrasStride))["=="](uniform)
	vertices[3].pivot[2] = 4
	T(vertex_layout.GetUniformExtras(vertices, count))["=="](nil)
	T(vertex_layout.GetUniformExtras(vertices, 0))["=="](nil)
end)

T.Test("packed normals and tangents survive a split and a join", function()
	local count = 6
	local vertices = vertex_layout.ArrayType(count)
	local normals = {
		{0, 1, 0},
		{0, 0, -1},
		{0.6, -0.8, 0},
		{-0.267, 0.534, -0.802},
		{1, 0, 0},
		{0.577, 0.577, 0.577},
	}
	local signs = {1, -1, 2, -2, 3, -4}

	for i = 0, count - 1 do
		local n = normals[i + 1]
		vertices[i].position[0], vertices[i].position[1], vertices[i].position[2] = i + 0.125, -i, 1e6 + i
		vertices[i].normal[0], vertices[i].normal[1], vertices[i].normal[2] = n[1], n[2], n[3]
		vertices[i].tangent[0], vertices[i].tangent[1], vertices[i].tangent[2], vertices[i].tangent[3] = n[2], n[3], n[1], signs[i + 1]
		vertices[i].uv[0], vertices[i].uv[1] = i * 3.5, -i
	end

	local core = vertex_layout.Split(vertices, count)
	local joined = vertex_layout.Join(
		core,
		vertex_layout.GetUniformExtras(vertices, count) or
			string.rep("\0", vertex_layout.ExtrasStride),
		count
	)

	for i = 0, count - 1 do
		local n = normals[i + 1]

		for k = 0, 2 do
			T(joined[i].position[k])["=="](vertices[i].position[k])
			T(math.abs(joined[i].normal[k] - n[k + 1]))["<"](0.001)
			T(math.abs(joined[i].tangent[k] - vertices[i].tangent[k]))["<"](0.002)
		end

		T(joined[i].tangent[3])["=="](signs[i + 1])
		T(joined[i].uv[0])["=="](vertices[i].uv[0])
		T(joined[i].uv[1])["=="](vertices[i].uv[1])
	end

	local inputs = vertex_layout.GetInputAttributes(vertex_layout.CORE)
	T(inputs[2][1])["=="]("packed_normal")
	T(inputs[2][2])["=="]("uint")
end)

T.Test("a split packed on a worker unpacks to the split of the same vertices", function()
	local packed_mesh = import("goluwa/render3d/packed_mesh.lua")
	local blob = import("goluwa/codecs/internal/blob.lua")
	local count = 5

	for _, varied in ipairs{false, true} do
		local vertices = vertex_layout.ArrayType(count)

		for i = 0, count - 1 do
			vertices[i].position[0], vertices[i].position[1], vertices[i].position[2] = i, i * 2, -i
			vertices[i].normal[1] = 1
			vertices[i].tangent[0], vertices[i].tangent[3] = 1, 1
			vertices[i].uv[0] = i * 0.5
			vertices[i].texture_blend = varied and i * 0.25 or 0.5
		end

		local indices = ffi.new("uint16_t[3]", 0, 1, 2)
		local builder = blob.New()
		local info = packed_mesh.PackArrays(builder, vertices, count, indices, 3, 2)
		packed_mesh.PackSplit(builder, info, vertices)
		local data = builder:Finish()
		local split = packed_mesh.UnpackSplit(info, {ptr = data})
		local uniform = vertex_layout.GetUniformExtras(vertices, count)
		local core, extras = vertex_layout.Split(vertices, count, not uniform)
		T(split.uniform)["=="](uniform)
		T(ffi.string(split.core, ffi.sizeof(split.core)))["=="](ffi.string(core, ffi.sizeof(core)))
		T(split.extras and ffi.string(split.extras, ffi.sizeof(split.extras)))["=="](extras and ffi.string(extras, ffi.sizeof(extras)))
		T(uniform == nil)["=="](varied)
	end
end)
