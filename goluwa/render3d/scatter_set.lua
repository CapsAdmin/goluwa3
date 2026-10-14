-- sets of models scattered over surfaces, an object like a material. a material has one (ScatterSet), and
-- scatter.lua grows the set's prototypes on the material's ground, on the gpu, every frame, wherever the
-- prototype's rules say
--
-- local meadow = ScatterSet.New{
--     Name = "meadow",
--     Prototypes = {
--         {
--             model = "objects/natural/ground_plants/grass/grass_a.cgf",
--             density = 4,
--             ...
--         },
--     },
-- }
--
-- a set also has DensityMultiplier and DistanceMultiplier (both 1 by default), which scale the density and
-- the max_distance and full_density_distance of all its prototypes, and can be changed while it is in use
-- with set:SetDensityMultiplier(2). setting Prototypes builds them again, set.protos are the ones built
--
-- a prototype is one of the models and the rules for where and how it is grown. every key is optional
-- but model. a key that is not listed here is an error. ranges are a number or {min, max}, angles are
-- degrees, lengths meters
--
--   model: a model path, or a function returning the list of {mesh = polygon3d, material = material} the
--     model is made of (called once, when the set is first used)
--   density: instances per square meter where nothing holds it back
--   max_instances: leave it out for the room of the prototype to follow what it needs, which scatter.lua
--     estimates from the rules and then adjusts to what the gpu wanted. a number holds it there, instances over it
--     are dropped. 65536 instances is 4 MB
--   max_distance: no instances beyond it. past full_density_distance the instances thin out the further
--     they are, and the last 30% of max_distance they dither away
--   distance_scale: how much the instances grow wider as they thin out with distance, 0 not at all and 1
--     keeps the ground covered, for things that read as a carpet like grass
--   billboard: {distance = meters, fade = 0.15}, or true for 150 m. the model beyond the distance is drawn as the
--     baked billboard of render3d/billboard.lua (a few crossed quads with the model's picture on, made when the model
--     has loaded), crossfading with the model over fade (a share of the distance) around it. it casts shadows in the model's place.
--     the r_scatter_billboards pvar turns them off, and r_scatter_billboard_distance scales the distance. only for
--     models that are a path
--   shadow: the instances are drawn in the shadow maps, all of them, in view or not, so the ones behind the camera cast
--     shadows into it, and the shadow maps decide how far that goes. past the billboard's distance it is the billboard
--     that casts, which is much cheaper to draw in every cascade
--   bvh: the instances near the camera (r_scatter_gi_distance) are in the scene bvh as simple geometry that is not
--     drawn: the billboard when the prototype has one, else the model's lowest level of detail. that is what gives
--     them shadows from the soup, global illumination and reflections. for what is big enough to matter to light
--   density_response: the same for the set's DensityMultiplier, 1 by default and above it is fine: at 3 a
--     multiplier of 2 makes the density 4 times, so grass can grow denser than the trees do. the result is
--     `proto.density_multiplier`
--   distance_response: how much of the set's DistanceMultiplier this takes, 0 to 1 (1 by default). the multiplier
--     is what a prototype's distances are multiplied by, at 0.1 a multiplier of 10 makes them 1.9 times, so
--     grass can stay near while trees reach the horizon. the result is `proto.distance_multiplier`
--   conform: true makes the instance's base follow the ground under its footprint. a rigid copy of a wide model
--     aimed along the ground's normal at its root pokes through or floats off ground that curves, so at bake time
--     (needs ray queries) the ground is measured under the four edges of its footprint, and the vertex stage moves
--     the vertices near its base along its up axis to meet it, less the higher they are, so the tips stay free. for
--     models that are wide and low, grass and ground plants
--   animation_distance: beyond it the instances stand still, their wind bending is skipped. 60 m by default, not
--     scaled by the set
--   cluster: {scale = meters, amount = 0 to 1}. noise patches across the ground that the density follows,
--     amount 1 leaves bare ground between clumps of the size of scale
--   layers: {r, g, b, a}, how much each channel of the surface's layer mask (the terrain's splat
--     weights) grows it, so one set can put grass on the grass layer and stones on the rock layer
--   slope: {min, max, fade} the angle of the ground to the horizon it grows on, with the density going to
--     zero over fade degrees outside of that
--   altitude: {min, max, fade} the same for the world height
--   scale: size, uniform, and height: an extra stretch along the up axis
--   yaw: random rotation around the up axis, 360 is any
--   align: how much the up axis follows the ground's normal instead of the world up, 0 to 1
--   align_steep: how much of align is left on a steep slope, 1 for all of it (the default). `align` stands the
--     model on the ground's normal, which on a wall of 50 degrees lays it nearly flat out of it, so this fades
--     the alignment to align * align_steep between 30 and 55 degrees of slope
--   tilt: random lean away from the up axis
--   sink: how far it is pushed into the ground along its up axis, before scaling
--   color: {surface, saturation, brightness, variation, tint = {a, b}, tint_scale, tint_amount}. the
--     instance is tinted by the color of the ground under it, surface is how much (0 to 1), saturation
--     pushes the ground's color away from grey (1 is as is), brightness how much of the ground's
--     brightness it keeps (0 only keeps the hue), variation is a random brightness range per instance.
--     tint is two colors (rgb 0 to 2, 1 leaves it as is) blended between by patches of tint_scale meters,
--     tint_amount is how strongly
--   bending: the wind bending of the model's materials, see the Bending material param. it is set on the
--     model's materials, which are shared with every other use of the model
local objects = import("goluwa/objects/objects.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scatter_grass_mesh = import("goluwa/render3d/scatter_grass_mesh.lua")
local ScatterSet = objects.CreateTemplate("render3d_scatter_set")
ScatterSet.MAX_PROTOTYPES = 256
-- bumps whenever the list of prototypes or one of their models changes
ScatterSet.version = 0
local next_uid = 0
local set_count = 0
-- the sets that are in use
local active = {}
-- the prototypes of those, in a list
local prototypes = {}
local DEFAULTS = {
	density = 1,
	max_distance = 80,
	full_density_distance = 10,
	distance_scale = 0,
	distance_response = 1,
	density_response = 1,
	conform = false,
	shadow = false,
	bvh = false,
	animation_distance = 60,
	billboard = false,
	cluster = {scale = 8, amount = 0},
	layers = {1, 1, 1, 1},
	slope = {0, 90, 10},
	altitude = {-1e9, 1e9, 5},
	scale = {1, 1},
	height = {1, 1},
	yaw = 360,
	align = 0,
	align_steep = 1,
	tilt = 0,
	sink = {0, 0},
	color = {
		surface = 0,
		saturation = 1,
		brightness = 0,
		variation = 0.1,
		tint = {{1, 1, 1}, {1, 1, 1}},
		tint_scale = 20,
		tint_amount = 0,
	},
}
local COLOR_KEYS = {
	surface = true,
	saturation = true,
	brightness = true,
	variation = true,
	tint = true,
	tint_scale = true,
	tint_amount = true,
}
local CLUSTER_KEYS = {scale = true, amount = true}

local function to_range(value, name)
	if type(value) == "number" then return {value, value} end

	assert(
		type(value) == "table" and
			type(value[1]) == "number" and
			type(value[2]) == "number",
		name .. " is a number or {min, max}"
	)
	return {value[1], value[2]}
end

local function check_keys(tbl, allowed, name)
	for key in pairs(tbl) do
		if not allowed[key] then
			error("unknown " .. name .. " key " .. tostring(key), 4)
		end
	end
end

local function normalize_prototype(definition, set_name, index)
	local name = set_name .. "." .. index
	assert(definition.model, name .. " has no model")

	for key in pairs(definition) do
		if key ~= "model" and key ~= "bending" and key ~= "max_instances" and DEFAULTS[key] == nil then
			error("unknown prototype key " .. tostring(key) .. " in " .. name, 3)
		end
	end

	local function get(key)
		local value = definition[key]

		if value == nil then return DEFAULTS[key] end

		return value
	end

	local cluster = get("cluster")
	check_keys(cluster, CLUSTER_KEYS, "cluster")
	local color = get("color")
	check_keys(color, COLOR_KEYS, "color")
	local scale = to_range(get("scale"), name .. ".scale")
	local height = to_range(get("height"), name .. ".height")
	local sink = to_range(get("sink"), name .. ".sink")
	local slope = get("slope")
	local altitude = get("altitude")
	local layers = get("layers")
	local tint = color.tint or DEFAULTS.color.tint

	local function field(tbl, key)
		if tbl[key] == nil then return DEFAULTS.color[key] end

		return tbl[key]
	end

	next_uid = next_uid + 1
	local proto = {
		uid = next_uid,
		name = name,
		model = definition.model,
		bending = definition.bending,
		state = "unloaded",
		parts = {},
		density = get("density"),
		max_instances = definition.max_instances,
		max_distance = get("max_distance"),
		full_density_distance = get("full_density_distance"),
		distance_scale = get("distance_scale"),
		distance_response = get("distance_response"),
		density_response = get("density_response"),
		conform = get("conform"),
		shadow = get("shadow"),
		bvh = get("bvh"),
		animation_distance = get("animation_distance"),
		billboard_distance = 0,
		billboard_fade = 0.15,
		cluster_scale = cluster.scale or DEFAULTS.cluster.scale,
		cluster_amount = cluster.amount or DEFAULTS.cluster.amount,
		layers = {layers[1], layers[2], layers[3], layers[4]},
		slope_min = math.rad(slope[1] or DEFAULTS.slope[1]),
		slope_max = math.rad(slope[2] or DEFAULTS.slope[2]),
		slope_fade = math.rad(slope[3] or DEFAULTS.slope[3]),
		altitude_min = altitude[1] or DEFAULTS.altitude[1],
		altitude_max = altitude[2] or DEFAULTS.altitude[2],
		altitude_fade = altitude[3] or DEFAULTS.altitude[3],
		scale_min = scale[1],
		scale_max = scale[2],
		height_min = height[1],
		height_max = height[2],
		yaw = math.rad(get("yaw")),
		align = get("align"),
		align_steep = get("align_steep"),
		tilt = math.rad(get("tilt")),
		sink_min = sink[1],
		sink_max = sink[2],
		color_surface = field(color, "surface"),
		color_saturation = field(color, "saturation"),
		color_brightness = field(color, "brightness"),
		color_variation = field(color, "variation"),
		tint_a = tint[1],
		tint_b = tint[2],
		tint_scale = field(color, "tint_scale"),
		tint_amount = field(color, "tint_amount"),
	}
	local billboard = get("billboard")

	if billboard then
		assert(type(proto.model) == "string", name .. " has a billboard but its model is not a path")
		billboard = billboard == true and {} or billboard
		proto.billboard_distance = billboard.distance or 150
		proto.billboard_fade = billboard.fade or 0.15
		assert(proto.billboard_distance > 0 and proto.billboard_fade > 0 and proto.billboard_fade < 1, name .. ".billboard needs a distance and a fade between 0 and 1")
	end

	assert(proto.density > 0, name .. ".density must be above zero")
	assert(proto.max_instances == nil or proto.max_instances > 0, name .. ".max_instances must be above zero")
	assert(
		proto.full_density_distance > 0 and proto.max_distance > 0,
		name .. " distances must be above zero"
	)
	return proto
end


ScatterSet:StartStorable()
ScatterSet:GetSet("DensityMultiplier", 1, {callback = "UpdateMultipliers"})
ScatterSet:GetSet("DistanceMultiplier", 1, {callback = "UpdateMultipliers"})
ScatterSet:EndStorable()
-- the definitions of the prototypes, see above
ScatterSet:GetSet("Prototypes", {}, {callback = "BuildPrototypes"})

function ScatterSet:OnConstruct()
	set_count = set_count + 1
	self.order = set_count
	self.protos = {}
end

local CONFIG_KEYS = {"Name", "DensityMultiplier", "DistanceMultiplier", "Prototypes"}

function ScatterSet.New(config)
	local self = ScatterSet:CreateObject()
	local known = {}

	for _, key in ipairs(CONFIG_KEYS) do
		known[key] = true

		if config[key] ~= nil then self["Set" .. key](self, config[key]) end
	end

	for key in pairs(config) do
		if not known[key] then error("unknown scatter set key " .. tostring(key), 2) end
	end

	return self
end

local function apply_multipliers(set, proto)
	proto.distance_multiplier = 1 + (set.DistanceMultiplier - 1) * proto.distance_response
	proto.density_multiplier = 1 + (set.DensityMultiplier - 1) * proto.density_response
end

function ScatterSet:UpdateMultipliers()
	for _, proto in ipairs(self.protos) do
		apply_multipliers(self, proto)
	end
end

function ScatterSet:BuildPrototypes()
	local name = self.Name ~= "" and self.Name or "scatter_set"
	local built = {}

	for i, definition in ipairs(self.Prototypes) do
		built[i] = normalize_prototype(definition, name, i)
	end

	assert(built[1], "scatter set " .. name .. " has no prototypes")
	self.protos = built

	for _, proto in ipairs(built) do
		proto.set = self
		apply_multipliers(self, proto)
	end

	if active[self] then ScatterSet.Rebuild() end
end

function ScatterSet:OnRemove()
	if active[self] then
		active[self] = nil
		ScatterSet.Rebuild()
	end
end

local function finish_loading(proto, entries)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
	proto.parts = {}
	proto.lod_parts = nil
	local lod_level = 0

	for _, entry in ipairs(entries) do
		local polygon = entry.mesh
		local mesh = polygon:GetMesh()

		-- the lower levels of detail are other polygons of the same model
		if polygon:GetLODLevel() == 0 and not polygon:GetLODBillboard() and mesh:IsValid() then
			assert(mesh.index_buffer, proto.name .. " has a mesh without indices")
			local material = entry.material or render3d.GetDefaultMaterial()
			local aabb = polygon:GetAABB()
			min_x, min_y, min_z = math.min(min_x, aabb.min_x),
			math.min(min_y, aabb.min_y),
			math.min(min_z, aabb.min_z)
			max_x, max_y, max_z = math.max(max_x, aabb.max_x),
			math.max(max_y, aabb.max_y),
			math.max(max_z, aabb.max_z)

			if proto.bending then material:SetBending(proto.bending) end

			proto.parts[#proto.parts + 1] = {mesh = mesh, polygon = polygon, material = material}
		elseif mesh:IsValid() and not polygon:GetLODBillboard() and mesh.index_buffer then
			-- the lowest level of detail there is is what stands in for the model in the bvh
			local level = polygon:GetLODLevel()

			if level > lod_level then
				lod_level = level
				proto.lod_parts = {}
			end

			if level == lod_level then
				proto.lod_parts[#proto.lod_parts + 1] = {mesh = mesh, polygon = polygon, material = entry.material or render3d.GetDefaultMaterial()}
			end
		end
	end

	if not proto.parts[1] then
		proto.state = "failed"
		logf("scatter prototype %s has no meshes\n", proto.name)
	else
		proto.state = "ready"

		if proto.billboard_distance > 0 then
			import("goluwa/render3d/billboard.lua").Request(proto.model, function(polygon, material)
				proto.billboard_part = {mesh = polygon:GetMesh(), polygon = polygon, material = material}
				ScatterSet.version = ScatterSet.version + 1
			end)
		end
		-- how far from its origin the model reaches, and how tall it is, unscaled
		proto.height = math.max(max_y, 0.01)
		-- the mean half width of the model, how far the ground is measured from its root when it conforms
		proto.footprint = 0.25 * ((max_x - min_x) + (max_z - min_z))
		proto.radius = math.sqrt(
			math.max(min_x * min_x, max_x * max_x) + math.max(min_y * min_y, max_y * max_y) + math.max(min_z * min_z, max_z * max_z)
		)
	end

	ScatterSet.version = ScatterSet.version + 1
end

local function load_prototype(proto)
	proto.state = "loading"
	local source = proto.model

	if type(source) == "function" then source = source() end

	if type(source) == "string" then
		model_loader.LoadModel(
			source,
			function(entries)
				finish_loading(proto, entries)
			end,
			nil,
			function(err)
				proto.state = "failed"
				logf("scatter prototype %s failed to load %s: %s\n", proto.name, source, err)
				ScatterSet.version = ScatterSet.version + 1
			end
		)
	else
		finish_loading(proto, source)
	end
end

function ScatterSet.Rebuild()
	list.clear(prototypes)
	local sets = {}

	for set in pairs(active) do
		sets[#sets + 1] = set
	end

	table.sort(sets, function(a, b)
		return a.order < b.order
	end)

	for _, set in ipairs(sets) do
		for _, proto in ipairs(set.protos) do
			assert(#prototypes < ScatterSet.MAX_PROTOTYPES, "too many scatter prototypes in use")
			prototypes[#prototypes + 1] = proto
			proto.index = #prototypes - 1
		end
	end

	ScatterSet.version = ScatterSet.version + 1

	for _, proto in ipairs(prototypes) do
		if proto.state == "unloaded" then load_prototype(proto) end
	end
end

-- marks the set as in use, which starts loading its models
function ScatterSet:Use()
	if not active[self] then
		active[self] = true
		ScatterSet.Rebuild()
	end

	return self
end

-- the prototypes of the sets that are in use, proto.index is the place in this list (from 0)
function ScatterSet.GetPrototypes()
	return prototypes
end

local TUFT_VARIANTS = {
	{blades = 14, height = 0.16, width = 0.016, radius = 0.1, lean = 1.2},
	{blades = 18, height = 0.28, width = 0.02, radius = 0.14, lean = 1.4},
	{blades = 22, height = 0.5, width = 0.026, radius = 0.2, lean = 1.6},
}

-- the grass that needs no assets, tufts of blades made in lua
local grass

function ScatterSet.GetGrass()
	if grass then return grass end

	local variants = {}

	for i, variant in ipairs(TUFT_VARIANTS) do
		variants[i] = function()
			return scatter_grass_mesh.Build{
				blades = variant.blades,
				height = variant.height,
				width = variant.width,
				radius = variant.radius,
				lean = variant.lean,
				seed = i,
			}
		end
	end

	local color = {
		surface = 1,
		saturation = 1.4,
		brightness = 0.5,
		variation = 0.25,
		tint = {{1.35, 1.12, 0.6}, {1, 1, 1}},
		tint_scale = 25,
		tint_amount = 0.5,
	}
	grass = ScatterSet.New{
		Name = "grass",
		Prototypes = {
			{
				model = variants[1],
				density = 22,
				max_distance = 45,
				full_density_distance = 6,
				cluster = {scale = 6, amount = 0.5},
				slope = {0, 40, 10},
				scale = {0.7, 1.3},
				height = {0.8, 1.3},
				align = 1,
				tilt = 6,
				color = color,
			},
			{
				model = variants[2],
				density = 12,
				max_distance = 55,
				full_density_distance = 8,
				cluster = {scale = 9, amount = 0.6},
				slope = {0, 40, 10},
				scale = {0.7, 1.3},
				height = {0.8, 1.3},
				align = 1,
				tilt = 8,
				color = color,
			},
			{
				model = variants[3],
				density = 2,
				max_distance = 70,
				full_density_distance = 10,
				cluster = {scale = 14, amount = 0.8},
				slope = {0, 35, 10},
				scale = {0.7, 1.3},
				height = {0.8, 1.2},
				align = 0.3,
				tilt = 8,
				color = color,
			},
		},
	}
	return grass
end

return ScatterSet:Register()
