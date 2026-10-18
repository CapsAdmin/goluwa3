local ffi = require("ffi")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local emitters = {}
emitters.DOUBLE_SIDED = 0x80000000
local EMITTER_WORDS = 4
local sqrt = math.sqrt
emitters.EMITTER_WORDS = EMITTER_WORDS
local list = {count = 0, power = 0, version = -1}

-- visits the triangles of a mesh on the cpu in the world of the instance: f(primitive, area, v0, e1, e2)
local function get_triangles(mesh, count)
	local vertex_buffer = mesh.vertex_buffer
	local vertices = ffi.cast("float*", vertex_buffer.data)
	local stride = vertex_buffer.stride / 4
	local index_buffer = mesh.index_buffer
	local indices

	if index_buffer then
		local data = index_buffer:GetData()

		if type(data) == "cdata" then
			indices = ffi.cast(index_buffer:GetIndexTypeFFI() .. "*", data)
		else
			indices = setmetatable({}, {__index = function(_, i) return data[i + 1] end})
		end
	end

	return vertices, stride, indices
end

-- the emitting triangles of every visible emissive instance, drawn by power: for each its instance, primitive (the top
-- bit set for a double sided material), the cumulative share of the power and the power
function emitters.Get(include_additive)
	if list.version == bridge.emitter_version and list.additive == include_additive then
		return list
	end

	local words = {}
	local count = 0
	local power_total = 0
	local excluded_count, excluded_power = 0, 0

	for visual in pairs(bridge.GetEmissiveVisuals()) do
		if visual.Visible then
			for _, item in ipairs(visual.scene_instances) do
				local material = item.material
				local r, g, b = materials.GetEmissive(material)
				local luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b

				if luminance > 0 then
					local m = item.matrix
					local additive = material:GetAdditive() and
						not material:GetAlbedoAlphaIsEmissive()
						and
						material:GetEmissiveTexture() == nil
					local flag = material:GetDoubleSided() and emitters.DOUBLE_SIDED or 0
					local vertices, stride, indices = get_triangles(item.mesh)
					local triangle_count = indices and
						math.floor(item.mesh.index_buffer:GetIndexCount() / 3) or
						math.floor(item.mesh.vertex_buffer:GetVertexCount() / 3)

					for i = 0, triangle_count - 1 do
						local a = (indices and indices[i * 3] or i * 3) * stride
						local bi = (indices and indices[i * 3 + 1] or i * 3 + 1) * stride
						local c = (indices and indices[i * 3 + 2] or i * 3 + 2) * stride
						local ax, ay, az = vertices[a], vertices[a + 1], vertices[a + 2]
						local e1x, e1y, e1z = vertices[bi] - ax, vertices[bi + 1] - ay, vertices[bi + 2] - az
						local e2x, e2y, e2z = vertices[c] - ax, vertices[c + 1] - ay, vertices[c + 2] - az
						local w1x = e1x * m.m00 + e1y * m.m10 + e1z * m.m20
						local w1y = e1x * m.m01 + e1y * m.m11 + e1z * m.m21
						local w1z = e1x * m.m02 + e1y * m.m12 + e1z * m.m22
						local w2x = e2x * m.m00 + e2y * m.m10 + e2z * m.m20
						local w2y = e2x * m.m01 + e2y * m.m11 + e2z * m.m21
						local w2z = e2x * m.m02 + e2y * m.m12 + e2z * m.m22
						local nx = w1y * w2z - w1z * w2y
						local ny = w1z * w2x - w1x * w2z
						local nz = w1x * w2y - w1y * w2x
						local power = 0.5 * sqrt(nx * nx + ny * ny + nz * nz) * luminance

						if additive and not include_additive then
							excluded_count = excluded_count + 1
							excluded_power = excluded_power + power
						elseif power > 0 then
							power_total = power_total + power
							words[count * 4 + 1] = item.id
							words[count * 4 + 2] = i + flag
							words[count * 4 + 3] = power_total
							words[count * 4 + 4] = power
							count = count + 1
						end
					end
				end
			end
		end
	end

	list.count = count
	list.weight = power_total
	list.additive = include_additive
	list.excluded_count = excluded_count
	list.excluded_power = excluded_power
	list.version = bridge.emitter_version
	list.words_version = (list.words_version or 0) + 1
	-- header: the total power and the count, then 4 words per emitter
	local header = 2
	local total_words = header + count * EMITTER_WORDS
	local data = ffi.new("uint32_t[?]", math.max(total_words, 1))
	local floats = ffi.cast("float*", data)
	floats[0] = power_total
	data[1] = count

	for i = 0, count - 1 do
		local g = header + i * EMITTER_WORDS
		data[g] = words[i * 4 + 1]
		data[g + 1] = words[i * 4 + 2]
		floats[g + 2] = words[i * 4 + 3] / power_total
		floats[g + 3] = words[i * 4 + 4]
	end

	if count > 0 then floats[header + (count - 1) * EMITTER_WORDS + 2] = 1 end

	list.words = data
	list.word_count = total_words
	return list
end

return emitters
