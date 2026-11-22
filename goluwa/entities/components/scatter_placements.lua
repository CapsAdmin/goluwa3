local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local timer = import("goluwa/timer.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local META = objects.CreateTemplate("scatter_placements")
META:StartStorable()
META:GetSet("Model", "", {asset = "models", callback = "Refresh"})
META:GetSet("MaterialOverride", "", {callback = "Refresh"})
META:GetSet("Bending", 0, {validate = "number", callback = "Refresh"})
META:GetSet("Billboard", false, {callback = "Refresh"})
META:GetSet("BillboardRadii", 56, {validate = "number", callback = "Refresh"})
META:GetSet("MaxDistance", 4000, {validate = "number", callback = "Refresh"})
META:GetSet("Shadow", true, {callback = "Refresh"})
META:GetSet("Conform", false, {callback = "Refresh"})
META:GetSet("Records", "", {callback = "Refresh", Hidden = true})
META:EndStorable()
local Record = ffi.typeof("struct { float x, y, z, scale, yaw, nx, ny, nz; }")
local RecordPtr = ffi.typeof("$ *", Record)
local FloatArray = ffi.typeof("float[?]")

function META:Place()
	local count = math.floor(#self.Records / ffi.sizeof(Record))

	if self.handle or self.Model == "" or count == 0 then return end

	local scatter = import("goluwa/render3d/scatter.lua")
	local records = ffi.cast(RecordPtr, self.Records)
	local matrices = FloatArray(count * 16)

	for i = 0, count - 1 do
		local r = records[i]
		scatter.WritePlacement(matrices, i * 16, r.x, r.y, r.z, r.scale, r.yaw, r.nx, r.ny, r.nz)
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

function META:Unplace()
	if self.handle then
		import("goluwa/render3d/scatter.lua").RemovePlacements(self.handle)
		self.handle = nil
	end

	if self.set then
		self.set:Remove()
		self.set = nil
	end
end

-- places again at the end of the frame, after every property of an edit is set
function META:Refresh()
	if self.refresh_pending then return end

	self.refresh_pending = true

	timer.Delay(0, function()
		if not self:IsValid() then return end

		self.refresh_pending = false
		self:Unplace()
		self:Place()
	end)
end

META.OnEntityConstructed = META.Refresh
META.OnDeserialized = META.Refresh
META.OnRemove = META.Unplace
META.RECORD_SIZE = ffi.sizeof(Record)
META.Record = Record
META.RecordArray = ffi.typeof("$[?]", Record)
return META:Register()
