local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
-- instances of one model that stand where they were put (a level's painted vegetation), drawn by the scatter system
-- instead of an entity for each one: the model's prototype, a set of its own, and the instances as 32 byte records
local META = objects.CreateTemplate("scatter_placements")
META:StartStorable()
META:GetSet("Model", "")
META:GetSet("MaterialOverride", "")
META:GetSet("Bending", 0, {validate = "number"})
META:GetSet("Billboard", false)
-- the lod system switches to a billboard at 14 radii, the pvar r_scatter_billboard_distance (0.75) scales this to 42
META:GetSet("BillboardRadii", 56, {validate = "number"})
META:GetSet("MaxDistance", 4000, {validate = "number"})
META:GetSet("Shadow", true)
-- the base of each follows the ground under it (needs ray queries)
META:GetSet("Conform", false)
-- position, scale, yaw and the up axis of each: x, y, z, scale, yaw, nx, ny, nz as float32
META:GetSet("Records", "")
META:EndStorable()
local Record = ffi.typeof("struct { float x, y, z, scale, yaw, nx, ny, nz; }")
local RecordPtr = ffi.typeof("$ *", Record)
local FloatArray = ffi.typeof("float[?]")
-- no tint: 0.5 in the three color channels (the tint is stored at half scale) and 1 in alpha, as unorm8
local TINT_WORD = 0xFF808080

-- the matrix of an instance as the cull pass reads it, see the bottom row in scatter.lua
local function write_matrix(out, words, at, r)
	local nx, ny, nz = r.nx, r.ny, r.nz
	-- two vectors that with the up axis make an orthonormal basis (Duff et al.)
	local sign = nz >= 0 and 1 or -1
	local a = -1 / (sign + nz)
	local b = nx * ny * a
	local b1x, b1y, b1z = 1 + sign * nx * nx * a, sign * b, -sign * nx
	local b2x, b2y, b2z = b, sign + ny * ny * a, -ny
	local c, s = math.cos(r.yaw), math.sin(r.yaw)
	local xx, xy, xz = b1x * c + b2x * s, b1y * c + b2y * s, b1z * c + b2z * s
	local zx, zy, zz = xy * nz - xz * ny, xz * nx - xx * nz, xx * ny - xy * nx
	local scale = r.scale
	out[at], out[at + 1], out[at + 2], out[at + 3] = xx * scale, xy * scale, xz * scale, 0
	out[at + 4], out[at + 5], out[at + 6] = nx * scale, ny * scale, nz * scale
	words[at + 7] = TINT_WORD
	out[at + 8], out[at + 9], out[at + 10], out[at + 11] = zx * scale, zy * scale, zz * scale, 0
	out[at + 12], out[at + 13], out[at + 14], out[at + 15] = r.x, r.y, r.z, 1
end

function META:Place()
	local count = math.floor(#self.Records / ffi.sizeof(Record))

	if self.handle or self.Model == "" or count == 0 then return end

	local scatter = import("goluwa/render3d/scatter.lua")
	local records = ffi.cast(RecordPtr, self.Records)
	local matrices = FloatArray(count * 16)
	local words = ffi.cast("uint32_t *", matrices)

	for i = 0, count - 1 do
		write_matrix(matrices, words, i * 16, records[i])
	end

	self.set = ScatterSet.New{
		Name = "placed " .. self.Model,
		Prototypes = {
			{
				model = self.Model,
				placed = true,
				material_override = self.MaterialOverride ~= "" and self.MaterialOverride or nil,
				bending = self.Bending,
				billboard = self.Billboard and {radii = self.BillboardRadii} or false,
				max_distance = self.MaxDistance,
				shadow = self.Shadow,
				conform = self.Conform,
			},
		},
	}
	self.set:Use()
	self.handle = scatter.AddPlacements(self.set.protos[1], matrices, count)
	self:RefreshHidden()
end

function META:RefreshHidden()
	if self.handle then
		import("goluwa/render3d/scatter.lua").SetPlacementsHidden(self.handle, self.Owner.visibility_hidden or false)
	end
end

META.OnHide = META.RefreshHidden
META.OnShow = META.RefreshHidden
META.OnEntityConstructed = META.Place
META.OnDeserialized = META.Place

function META:OnRemove()
	if self.handle then
		import("goluwa/render3d/scatter.lua").RemovePlacements(self.handle)
		self.handle = nil
	end

	if self.set then
		self.set:Remove()
		self.set = nil
	end
end

META.RECORD_SIZE = ffi.sizeof(Record)
META.Record = Record
META.RecordArray = ffi.typeof("$[?]", Record)
return META:Register()
