local ffi = require("ffi")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local vertex_extras = {}
local TIERS = {65536, 262144, 1048576}
local ATTRIBUTES = vertex_layout.GetAttributes(vertex_layout.EXTRAS_BINDING, "extras")
local defaults = {}

function vertex_extras.GetAttributes()
	return ATTRIBUTES
end

function vertex_extras.New(data, name, mode)
	return VertexBuffer.New(data, ATTRIBUTES, name or "vertex extras", mode)
end

function vertex_extras.GetShared(value, vertex_count)
	for _, tier in ipairs(TIERS) do
		if vertex_count <= tier then
			local key = tier .. "\1" .. value
			local shared = defaults[key]

			if not shared then
				local data = ffi.new("uint8_t[?]", tier * vertex_layout.ExtrasStride)

				for i = 0, tier - 1 do
					ffi.copy(data + i * vertex_layout.ExtrasStride, value, vertex_layout.ExtrasStride)
				end

				shared = vertex_extras.New(data, "shared vertex extras " .. tier, "owned")
				shared.data, shared.owner, shared.vertices = nil, nil, nil
				shared.shared = true
				shared.value = value
				defaults[key] = shared
			end

			return shared
		end
	end

	return nil
end

return vertex_extras
