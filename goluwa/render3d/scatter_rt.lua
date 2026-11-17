local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local scene_parts = import("goluwa/render3d/scene/parts.lua")
local scatter_rt = {}
local Part = ffi.typeof([[struct {
	uint32_t mesh_row;
	uint32_t material_row;
	uint32_t record_flags;
	uint32_t mask_flags;
	uint32_t part;
}]])
pvars.StartGroup("Rendering", "Scatter ray tracing", {store = false})
local enabled = pvars.Setup2{
	key = "r_scatter_rt",
	default = true,
	help = "what scatter grows is in the ray traced scene (global illumination, reflections, fog), as the model near the camera and the billboard beyond its distance, like the real scene draws it",
}
local max_distance = pvars.Setup2{
	key = "r_scatter_rt_distance",
	default = 1500,
	min = 0,
	help = "how far from the camera what scatter grows is in the ray traced scene, in meters",
}
pvars.EndGroup()
scatter_rt.NONE = 0xFFFFFFFF
local MIN_ROWS = 256
local RESERVE_MARGIN = 1.5
local parts_table
local entries = {}

local function needs_rows(have, need)
	return have < need or (have > MIN_ROWS * 4 and need * 4 < have)
end

function scatter_rt.GetDistance()
	return max_distance:Get()
end

function scatter_rt.GetPartsAddress()
	if not parts_table then
		parts_table = store.CreateTable{name = "scatter_rt_parts", ctype = Part, capacity = 1024}
	end

	return parts_table:GetAddress()
end

local function release_parts(entry)
	for _, part in ipairs(entry.held) do
		scene_parts.Release(part)
	end

	if entry.parts_first then
		parts_table:FreeRange(entry.parts_first, entry.parts_size)
	end

	entry.held = {}
	entry.parts_first = nil
	entry.parts_count = 0
end

local released = {}

local function release_rows(entry)
	if entry.model_base then
		released[#released + 1] = {entry.model_base, entry.model_rows}
	end

	if entry.billboard_base then
		released[#released + 1] = {entry.billboard_base, entry.billboard_rows}
	end

	entry.model_base, entry.model_rows = nil, 0
	entry.billboard_base, entry.billboard_rows = nil, 0
end

-- the rows of the instances scatter writes for each prototype: the gpu cull pass writes one tlas row per part of every instance in a prototype's shadow list (model) and one per instance in its billboard list, at slot * parts + part, and a row not written for a frame stops being shown. rows are replaced by a new range before the old one is freed, and a freed range is only reused from the next frame on, so a flush that clears the old rows never lands on rows the cull wrote this frame. the parts they are made from are replaced by new ranges whose old ones are freed a few frames later, so frames in flight keep reading what they were recorded with. out[i] gets {model_base, billboard_base, parts_first, parts_count} (NONE for no billboard rows) for the prototype buffer
function scatter_rt.Update(protos, out)
	parts_table = parts_table or
		store.CreateTable{name = "scatter_rt_parts", ctype = Part, capacity = 1024}
	local on = enabled:Get() and render.GetDevice().ray_tracing_supported

	for _, entry in pairs(entries) do
		entry.seen = false
	end

	for i, proto in ipairs(protos) do
		local row = out[i]
		row[1], row[2], row[3], row[4] = 0, scatter_rt.NONE, 0, 0

		if on and proto.state == "ready" and proto.shadow and proto.bvh then
			local entry = entries[proto]

			if not entry then
				entry = {held = {}, parts_count = 0, model_rows = 0, billboard_rows = 0}
				entries[proto] = entry
			end

			entry.seen = true
			local billboard_part = proto.sized_switch > 0 and proto.billboard_part or nil

			if
				entry.source ~= proto.parts or
				entry.source_count ~= #proto.parts or
				entry.billboard_part ~= billboard_part or
				not entry.complete
			then
				release_parts(entry)
				entry.complete = true
				local resolved = {}

				for _, part in ipairs(proto.parts) do
					local mesh_row = meshes.Get(part.mesh)

					if mesh_row then
						resolved[#resolved + 1] = {part = part, mesh_row = mesh_row}
					else
						entry.complete = false
					end
				end

				entry.parts_count = #resolved
				local billboard_mesh_row = billboard_part and meshes.Get(billboard_part.mesh)

				if billboard_part and not billboard_mesh_row then entry.complete = false end

				if billboard_mesh_row then
					resolved[#resolved + 1] = {part = billboard_part, mesh_row = billboard_mesh_row}
				end

				entry.parts_size = #resolved
				entry.parts_first = #resolved > 0 and parts_table:AllocRange(#resolved) or nil

				for k, item in ipairs(resolved) do
					local part = item.part
					local flags, mask = instances.GetMaterialFlags(part.material)
					local scene_part = scene_parts.Acquire(item.mesh_row, part.material, part.polygon)
					entry.held[#entry.held + 1] = scene_part
					local data = parts_table:Get()[entry.parts_first + k - 1]
					data.mesh_row = item.mesh_row
					data.material_row = materials.GetID(part.material)
					data.record_flags = instances.GetRecordFlags(flags)
					data.mask_flags = mask + flags * 256
					data.part = scene_part.id
				end

				entry.source = proto.parts
				entry.source_count = #proto.parts
				entry.billboard_part = billboard_part
				entry.has_billboard = billboard_mesh_row ~= nil
			end

			local model_rows = proto.shadow_room * entry.parts_count
			local billboard_rows = entry.has_billboard and proto.shadow_billboard_room or 0

			if
				needs_rows(entry.model_rows, model_rows) or
				needs_rows(entry.billboard_rows, billboard_rows)
			then
				release_rows(entry)
				entry.model_rows = model_rows > 0 and
					math.max(math.ceil(model_rows * RESERVE_MARGIN), MIN_ROWS) or
					0
				entry.billboard_rows = billboard_rows > 0 and
					math.max(math.ceil(billboard_rows * RESERVE_MARGIN), MIN_ROWS) or
					0
				entry.model_base = entry.model_rows > 0 and instances.AllocRange(entry.model_rows) or nil
				entry.billboard_base = entry.billboard_rows > 0 and instances.AllocRange(entry.billboard_rows) or nil
			end

			if entry.parts_count > 0 then
				row[1] = entry.model_base
				row[3] = entry.parts_first
				row[4] = entry.parts_count
			end

			if entry.has_billboard then
				row[2] = entry.billboard_base
				row[3] = entry.parts_first
			end
		end
	end

	for proto, entry in pairs(entries) do
		if not entry.seen then
			release_parts(entry)
			release_rows(entry)
			entries[proto] = nil
		end
	end

	for i = #released, 1, -1 do
		instances.FreeRange(released[i][1], released[i][2], true)
		released[i] = nil
	end
end

return scatter_rt
