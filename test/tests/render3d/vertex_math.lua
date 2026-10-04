local T = import("test/environment.lua")
local ffi = require("ffi")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test("vertex_math.BuildTangents matches Polygon3D:BuildTangents", function()
	math.randomseed(5)
	local vertex_count = 60
	local polygon = Polygon3D.New()
	local array = vertex_math.VertexType(vertex_count)

	for i = 0, vertex_count - 1 do
		local pos = Vec3(math.random() * 4 - 2, math.random() * 4 - 2, math.random() * 4 - 2)
		local normal = Vec3(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5):GetNormalized()
		local uv = Vec2(math.random(), math.random())
		polygon.Vertices[i + 1] = {pos = pos, normal = normal, uv = uv}
		array[i].position[0], array[i].position[1], array[i].position[2] = pos.x, pos.y, pos.z
		array[i].normal[0], array[i].normal[1], array[i].normal[2] = normal.x, normal.y, normal.z
		array[i].uv[0], array[i].uv[1] = uv.x, uv.y
	end

	local index_list = {}

	for i = 1, 40 do
		index_list[#index_list + 1] = math.random(0, 49)
		index_list[#index_list + 1] = math.random(0, 49)
		index_list[#index_list + 1] = math.random(0, 49)
	end

	polygon.Vertices[1].uv = Vec2(0.5, 0.5)
	array[0].uv[0], array[0].uv[1] = 0.5, 0.5
	local indices = ffi.new("uint16_t[?]", #index_list, index_list)
	local one_based = {}

	for i, index in ipairs(index_list) do
		one_based[i] = index + 1
	end

	polygon.indices = one_based
	polygon:BuildTangents()
	vertex_math.BuildTangents(array, vertex_count, indices, #index_list)

	for i = 0, vertex_count - 1 do
		local expected = polygon.Vertices[i + 1].tangent
		local tangent = array[i].tangent
		T(math.abs(tangent[0] - expected.x))["<"](1e-4)
		T(math.abs(tangent[1] - expected.y))["<"](1e-4)
		T(math.abs(tangent[2] - expected.z))["<"](1e-4)
		T(tangent[3])["=="](expected.w)
	end
end)
