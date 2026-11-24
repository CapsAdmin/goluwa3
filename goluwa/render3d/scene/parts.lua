local ffi = require("ffi")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local opacity_micromaps = import("goluwa/render3d/scene/opacity_micromaps.lua")
local deformed_copies = import("goluwa/render3d/scene/deformed_copies.lua")
local parts = {}
local Part = ffi.typeof([[struct {
	uint32_t trace_row;
	uint32_t bend_pool;
}]])
parts.GLSL = [[
	struct scene_part {
		uint trace_row;
		uint bend_pool;
	};
]]
local rows
local keys = {}
local live = {}
local trace_version = -1

function parts.GetTable()
	if not rows then
		rows = store.CreateTable{name = "parts", ctype = Part, capacity = 1024}
		rows:Alloc()
	end

	return rows
end

local function write(part)
	local trace_row = opacity_micromaps.GetRow(part.record, part.material)
	part.trace_row = trace_row
	local row = parts.GetTable():Get()[part.id]
	row.trace_row = trace_row
	row.bend_pool = part.pool and part.pool.id or 0

	if part.pool then part.pool.trace_row = trace_row end
end

function parts.Acquire(mesh_row, material, polygon, max_copies)
	local bends = material:HasVertexAnimation()
	polygon = bends and polygon or false
	local by_material = keys[mesh_row]

	if not by_material then
		by_material = {}
		keys[mesh_row] = by_material
	end

	local by_polygon = by_material[material]

	if not by_polygon then
		by_polygon = {}
		by_material[material] = by_polygon
	end

	local part = by_polygon[polygon]

	if not part then
		part = {
			id = parts.GetTable():Alloc(),
			row = mesh_row,
			record = meshes.GetRecord(mesh_row),
			material = material,
			polygon = polygon,
			refs = 0,
		}

		if bends then
			part.pool = deformed_copies.GetPool(mesh_row, material, polygon, max_copies)
			deformed_copies.RefPool(part.pool)
		end

		by_polygon[polygon] = part
		live[part] = true
		write(part)
	end

	part.refs = part.refs + 1
	return part
end

function parts.Release(part)
	part.refs = part.refs - 1

	if part.refs > 0 then return end

	if part.pool then deformed_copies.UnrefPool(part.pool) end

	parts.GetTable():Free(part.id)
	keys[part.row][part.material][part.polygon] = nil
	live[part] = nil
end

function parts.Update()
	if trace_version == opacity_micromaps.version then return end

	trace_version = opacity_micromaps.version

	for part in pairs(live) do
		write(part)
	end
end

return parts
