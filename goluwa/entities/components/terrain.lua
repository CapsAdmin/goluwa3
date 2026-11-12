local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local timer = import("goluwa/timer.lua")
local event = import("goluwa/event.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local HeightmapSource = import("goluwa/terrain/heightmap_source.lua")
local heightmap_file = import("goluwa/terrain/heightmap_file.lua")
local META = objects.CreateTemplate("terrain")
local LAYER_COUNT = 4
local HeightArray = ffi.typeof("uint16_t[?]")
local IndexArray = ffi.typeof("uint8_t[?]")
local layer_definitions = {}
META.Built = setmetatable({}, {__mode = "k"})

-- a detail layer the Layer properties can name: {albedo, normal, height (texture paths), scale, height_scale,
-- surface, ...} as heightmap_source.lua takes them
function META.RegisterLayer(name, definition)
	layer_definitions[name] = definition
end

local function get_layer_names()
	local names = {""}

	for name in pairs(layer_definitions) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

local function get_scatter_set_names()
	local names = {""}

	for _, name in ipairs(import("goluwa/render3d/scatter_set.lua").GetNames()) do
		if not name:starts_with("placed ") then names[#names + 1] = name end
	end

	return names
end

META:StartStorable()
META:GetSet("Path", "", {asset = "terrains", callback = "Rebuild"})
META:GetSet("Size", 256, {callback = "Rebuild", validate = "number"})
META:GetSet("Resolution", 257, {callback = "Rebuild", validate = "number"})
META:GetSet("MinHeight", -16, {callback = "Rebuild", validate = "number"})
META:GetSet("MaxHeight", 48, {callback = "Rebuild", validate = "number"})
META:GetSet("ScatterSet", "", {callback = "Rebuild", get_enums = get_scatter_set_names})

for i = 1, LAYER_COUNT do
	META:GetSet(
		"Layer" .. i,
		i == 1 and "grass" or "",
		{callback = "Rebuild", get_enums = get_layer_names}
	)
	META:GetSet(
		"Layer" .. i .. "Scatter",
		i == 1 and 1 or 0,
		{callback = "Rebuild", validate = "number"}
	)
end

META:GetSet("Heights", "", {callback = "OnMapsChanged", Hidden = true})
META:GetSet("LayerMap", "", {callback = "OnMapsChanged", Hidden = true})
META:EndStorable()

function META:GetData()
	return self.data
end

-- true when the maps are the Heights and LayerMap properties, so editing them is saved with the scene
function META:IsEditable()
	return self.data ~= nil and self.data_from_properties == true
end

function META:Clear()
	META.Built[self] = nil

	if self.renderer then
		self.renderer:Stop()
		self.renderer = nil
	end

	local world = self.Owner.static_world or static_world.Find(self.Owner)

	if world and world.TerrainHeight == self.height_function then
		world.TerrainHeight = nil
	end

	self.height_function = nil
end

-- the terrain of a heightmap source's data, see heightmap_source.lua. Data that is not read from
-- Path or made from the properties is saved by writing it to a file first (heightmap_file.Save) and setting Path.
function META:SetData(data, scatter_set)
	self.data = data
	self.data_from_properties = false
	self.scatter_set = scatter_set
	self.build_id = (self.build_id or 0) + 1
	self:Clear()

	if not RENDER_3D then return end

	local world = self.Owner.static_world or static_world.Find(self.Owner)

	if world then
		self.height_function = function(x, z)
			return HeightmapSource.SampleHeight(data, x, z)
		end
		world.TerrainHeight = self.height_function
	end

	local build_id = self.build_id

	data.color:AddOnReady(function()
		timer.Delay(0, function()
			if self:IsValid() and self.build_id == build_id then self:Build() end
		end)
	end)
end

function META:Build()
	local Terrain = import("goluwa/terrain/terrain.lua")
	local data = self.data
	local source = HeightmapSource.New(data)
	self.source = source
	self.renderer = Terrain.New{
		Name = "terrain",
		Source = source,
		ScatterSet = self.scatter_set,
		Levels = 6,
		GridSize = 4,
		BaseChunkSize = 64,
		Samples = 65,
		DetailSize = 256,
		ColorSize = 256,
		BuildsPerFrame = 2,
		Physics = {chunk_size = 64, samples = 65, radius = 2},
	}:Start()
	self.renderer.Root:SetName("terrain")
	self.Owner:AddChild(self.renderer.Root)
	self:AnchorRoot()
	META.Built[self] = true
end

-- the terrain is in world space wherever its entity is: the tiles' root undoes the entity's transform
function META:AnchorRoot()
	local owner = self.Owner.transform

	if not owner then return end

	local rotation = owner:GetWorldMatrix():GetRotation():GetConjugated()
	local root = self.renderer.Root.transform
	root:SetRotation(rotation)
	root:SetPosition(rotation:VecMul(-owner:GetWorldPosition()))
end

event.AddListener("OnTransformChanged", "terrain_anchor", function(transform)
	local terrain = transform.Owner.terrain

	if terrain and terrain.renderer then terrain:AnchorRoot() end
end)

do
	local color_texture

	local function get_color_texture()
		if not color_texture then
			local Texture = import("goluwa/render/texture.lua")
			local pixels = ffi.new("uint8_t[?]", 16 * 16 * 4)
			ffi.fill(pixels, 16 * 16 * 4, 188)
			color_texture = Texture.New{
				buffer = pixels,
				width = 16,
				height = 16,
				format = "r8g8b8a8_srgb",
				srgb = true,
				sampler = {
					min_filter = "linear",
					mag_filter = "linear",
					wrap_s = "clamp_to_edge",
					wrap_t = "clamp_to_edge",
				},
			}
		end

		return color_texture
	end

	-- a square map of Size meters centered on the world origin, Resolution samples a side, flat at 0 when there are no Heights
	function META:CreateDataFromProperties()
		local resolution = math.max(math.floor(self.Resolution), 2)
		local count = resolution * resolution
		local heights = HeightArray(count)

		if #self.Heights == count * 2 then
			ffi.copy(heights, self.Heights, count * 2)
		else
			local base = math.floor(math.clamp(-self.MinHeight / (self.MaxHeight - self.MinHeight), 0, 1) * 65535 + 0.5)

			for i = 0, count - 1 do
				heights[i] = base
			end
		end

		local indices = IndexArray(count)

		if #self.LayerMap == count then
			ffi.copy(indices, self.LayerMap, count)
		else
			ffi.fill(indices, count, 1)
		end

		local layers = {}

		for i = 1, LAYER_COUNT do
			local definition = layer_definitions[self["Layer" .. i]]

			if definition then
				layers[i] = table.merge(table.copy(definition), {scatter = self["Layer" .. i .. "Scatter"]})
			end
		end

		return {
			size = self.Size,
			origin = {-self.Size / 2, -self.Size / 2},
			uv = {1, 0, 0, 1},
			outside = "clamp",
			min_height = self.MinHeight,
			max_height = self.MaxHeight,
			height = {width = resolution, height = resolution, samples = heights},
			color = get_color_texture(),
			indices = {width = resolution, height = resolution, samples = indices},
			layers = layers,
		}
	end
end

-- builds once at the end of the frame, after every property of a load or an edit is set
function META:Rebuild()
	if self.rebuild_pending then return end

	self.rebuild_pending = true
	local build_id = self.build_id

	timer.Delay(0, function()
		if not self:IsValid() then return end

		self.rebuild_pending = false

		if self.build_id ~= build_id then return end

		if self.Path ~= "" then
			self:SetData(heightmap_file.Load(self.Path))
			return
		end

		local ScatterSet = import("goluwa/render3d/scatter_set.lua")
		self:SetData(
			self:CreateDataFromProperties(),
			self.ScatterSet ~= "" and ScatterSet.Get(self.ScatterSet) or nil
		)
		self.data_from_properties = true
	end)
end

function META:OnMapsChanged()
	if self.committing then return end

	local data = self:IsEditable() and self.data

	if
		data and
		#self.Heights == data.height.width * data.height.height * 2 and
		#self.LayerMap == data.indices.width * data.indices.height
	then
		ffi.copy(data.height.samples, self.Heights, #self.Heights)
		ffi.copy(data.indices.samples, self.LayerMap, #self.LayerMap)
		self:UpdateRegion(-math.huge, -math.huge, math.huge, math.huge)
		return
	end

	self:Rebuild()
end

-- after data.height or data.indices samples were changed inside a world box
function META:UpdateRegion(min_x, min_z, max_x, max_z)
	if not self.renderer then return end

	HeightmapSource.UploadMaps(self.source)
	self.renderer:Invalidate(min_x, min_z, max_x, max_z)
end

-- writes the edited samples back into Heights and LayerMap, returns the old and new values
function META:CommitMaps()
	local data = self.data
	local old_heights, old_layers = self.Heights, self.LayerMap
	self.committing = true
	self:SetHeights(ffi.string(data.height.samples, data.height.width * data.height.height * 2))
	self:SetLayerMap(ffi.string(data.indices.samples, data.indices.width * data.indices.height))
	self.committing = false
	return old_heights, old_layers
end

function META:OnAdd()
	self:Rebuild()
end

function META:OnRemove()
	self.build_id = (self.build_id or 0) + 1
	self:Clear()
end

return META:Register()
