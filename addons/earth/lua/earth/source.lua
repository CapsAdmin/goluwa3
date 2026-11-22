local ffi = require("ffi")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local Texture = import("goluwa/render/texture.lua")
local geo = import("lua/earth/geo.lua")
local system = import("goluwa/system.lua")
local noise = import("goluwa/terrain/noise.lua")
local water_grid = import("lua/earth/water_grid.lua")
local road_grid = import("lua/earth/road_grid.lua")
local EarthSource = setmetatable({}, {__index = ShaderSource})
EarthSource.__index = EarthSource
local GRID = 9
-- the share of the canopy's height the coarse surface model's ground is lowered by: radar sees into the crowns, so a
-- surface model's forest stands lower than its trees
local CANOPY_SINK = 0.6
EarthSource.CANOPY_SINK = CANOPY_SINK
local MAX_MOSAIC = 1024
-- a height mosaic texel with no land data (the tile does not exist: open sea)
local NO_DATA = -32768
local FloatArray = ffi.typeof("float[?]")
local ByteArray = ffi.typeof("uint8_t[?]")
local NEAREST = {
	min_filter = "nearest",
	mag_filter = "nearest",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}
local LINEAR = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}
-- texture0: the chunk's map, GRID x GRID texels of (height mosaic x, y, imagery mosaic x, y) in mosaic pixels over the
-- chunk's domain and one more row: (origin x, z, grid step, the spacing of the finest height data there),
-- (height mosaic pixel size, the height mosaic's width and height in texels: the texture is a pooled size at least that),
-- (water mosaic texels per height mosaic texel, water mosaic offset x, y, 1 when there is a water mosaic),
-- (the water mosaic's width and height in texels), (land mosaic texels per height mosaic texel, land mosaic offset x, y,
-- 1 when there is a land mosaic), (the land mosaic's width and height in texels), the same two for the road mosaic;
-- texture1: the height mosaic (meters), texture2: the imagery mosaic, texture3: the water mosaic (signed distance to the
-- shore, water level; see water_grid.lua), texture4: the land mosaic (land_grid.lua's classes over 255), texture5: the
-- road mosaic (road_grid.lua's distance and class over 255), texture6: the canopy mosaic (canopy_tiles.lua's tallest and
-- blurred canopy in meters over 255); a second extra row: (canopy mosaic texels per height mosaic texel, offset x, y, 1
-- when there is one), (its width and height in texels)
local HEADER = noise.WORLD .. road_grid.GLSL .. [=[
vec4 earth_info(int x, int y) {
	return texelFetch(TEXTURE(terrain_bake.texture0), ivec2(x, y), 0);
}

vec4 earth_map(vec2 p) {
	vec4 domain = earth_info(0, ]=] .. GRID .. [=[);
	vec2 t = clamp((p - domain.xy) / domain.z, vec2(0.0), vec2(]=] .. (
		GRID - 1
	) .. [=[.0 - 0.0001));
	ivec2 i = ivec2(t);
	vec2 f = t - vec2(i);
	return mix(
		mix(earth_info(i.x, i.y), earth_info(i.x + 1, i.y), f.x),
		mix(earth_info(i.x, i.y + 1), earth_info(i.x + 1, i.y + 1), f.x),
		f.y
	);
}

float earth_height_texel(ivec2 c, ivec2 last) {
	return texelFetch(TEXTURE(terrain_bake.texture1), clamp(c, ivec2(0), last), 0).r;
}

ivec2 earth_height_last() {
	return ivec2(earth_info(1, ]=] .. GRID .. [=[).yz) - 1;
}

vec4 earth_catmull_rom(float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return vec4(
		-0.5 * t3 + t2 - 0.5 * t,
		1.5 * t3 - 2.5 * t2 + 1.0,
		-1.5 * t3 + 2.0 * t2 + 0.5 * t,
		0.5 * t3 - 0.5 * t2
	);
}

float earth_mosaic_height(vec2 m) {
	ivec2 last = earth_height_last();
	vec2 t = m - 0.5;
	ivec2 base = ivec2(floor(t)) - 1;
	vec2 f = fract(t);
	vec4 wx = earth_catmull_rom(f.x);
	vec4 wy = earth_catmull_rom(f.y);
	float h = 0.0;

	for (int y = 0; y < 4; y++) {
		vec4 row = vec4(
			earth_height_texel(base + ivec2(0, y), last),
			earth_height_texel(base + ivec2(1, y), last),
			earth_height_texel(base + ivec2(2, y), last),
			earth_height_texel(base + ivec2(3, y), last)
		);
		h += dot(row, wx) * wy[y];
	}

	return h;
}

vec3 earth_photo(vec2 p) {
	vec2 m = earth_map(p).zw;
	return texture(TEXTURE(terrain_bake.texture2), m / vec2(textureSize(TEXTURE(terrain_bake.texture2), 0))).rgb;
}

int earth_land_texel(ivec2 c, ivec2 last) {
	return int(texelFetch(TEXTURE(terrain_bake.texture4), clamp(c, ivec2(0), last), 0).r * 255.0 + 0.5);
}

// the distance to the nearest road's edge in meters (negative on it, ]=] .. road_grid.RANGE .. [=[ far from roads) and its class
// (0 for none, plus ]=] .. road_grid.UNPAVED .. [=[ when unpaved) at a height mosaic position
vec2 earth_road(vec2 m) {
	vec4 road = earth_info(6, ]=] .. GRID .. [=[);

	if (road.w == 0.0) return vec2(]=] .. road_grid.RANGE .. [=[.0, 0.0);

	ivec2 last = ivec2(earth_info(7, ]=] .. GRID .. [=[).xy) - 1;
	vec2 t = m * road.x + road.yz - 0.5;
	ivec2 i = ivec2(floor(t));
	vec2 f = t - vec2(i);
	float d00 = texelFetch(TEXTURE(terrain_bake.texture5), clamp(i, ivec2(0), last), 0).r;
	float d10 = texelFetch(TEXTURE(terrain_bake.texture5), clamp(i + ivec2(1, 0), ivec2(0), last), 0).r;
	float d01 = texelFetch(TEXTURE(terrain_bake.texture5), clamp(i + ivec2(0, 1), ivec2(0), last), 0).r;
	float d11 = texelFetch(TEXTURE(terrain_bake.texture5), clamp(i + ivec2(1, 1), ivec2(0), last), 0).r;
	float d = mix(mix(d00, d10, f.x), mix(d01, d11, f.x), f.y);
	float class_value = texelFetch(TEXTURE(terrain_bake.texture5), clamp(ivec2(floor(t + 0.5)), ivec2(0), last), 0).g;
	return vec2((d * 2.0 - 1.0) * ]=] .. road_grid.RANGE .. [=[.0, floor(class_value * 255.0 + 0.5));
}

// how much of a texel of the given size a road takes, by its distance and class
float earth_road_area(vec2 road, float texel) {
	int id = int(road.y) % ]=] .. road_grid.UNPAVED .. [=[;
	return (1.0 - smoothstep(-0.5 * texel, 0.5 * texel, road.x)) * min(2.0 * EARTH_ROAD_HALF_WIDTH[id] / texel, 1.0);
}

// how much of a texel the road's colour covers the photo
float earth_road_cover(vec2 road, float texel) {
	return earth_road_area(road, texel) * EARTH_ROAD_COVER[int(road.y) % ]=] .. road_grid.UNPAVED .. [=[];
}

// the tallest canopy in a texel and the canopy around it blurred to the height data's scale, meters, at a height mosaic
// position, 0 without a canopy mosaic
vec2 earth_canopy(vec2 m) {
	vec4 canopy = earth_info(0, ]=] .. (
		GRID + 1
	) .. [=[);

	if (canopy.w == 0.0) return vec2(0.0);

	ivec2 last = ivec2(earth_info(1, ]=] .. (
		GRID + 1
	) .. [=[).xy) - 1;
	vec2 t = m * canopy.x + canopy.yz - 0.5;
	ivec2 i = ivec2(floor(t));
	vec2 f = t - vec2(i);
	vec2 c00 = texelFetch(TEXTURE(terrain_bake.texture6), clamp(i, ivec2(0), last), 0).rg;
	vec2 c10 = texelFetch(TEXTURE(terrain_bake.texture6), clamp(i + ivec2(1, 0), ivec2(0), last), 0).rg;
	vec2 c01 = texelFetch(TEXTURE(terrain_bake.texture6), clamp(i + ivec2(0, 1), ivec2(0), last), 0).rg;
	vec2 c11 = texelFetch(TEXTURE(terrain_bake.texture6), clamp(i + ivec2(1, 1), ivec2(0), last), 0).rg;
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y) * 255.0;
}

// the land classes of the four land mosaic texels around a world position and their bilinear weights, class 0 without
// a land mosaic; the position is moved by a little noise first, so the polygons' straight edges do not show
void earth_land(vec2 p, out ivec4 classes, out vec4 weights) {
	vec4 land = earth_info(4, ]=] .. GRID .. [=[);

	if (land.w == 0.0) {
		classes = ivec4(0);
		weights = vec4(1.0, 0.0, 0.0, 0.0);
		return;
	}

	vec2 warp = vec2(pn_fbm(p / 40.0 + vec2(3.1, 7.7), 3), pn_fbm(p / 40.0 + vec2(-5.3, 1.9), 3)) * 12.0;
	vec2 t = earth_map(p + warp).xy * land.x + land.yz - 0.5;
	ivec2 last = ivec2(earth_info(5, ]=] .. GRID .. [=[).xy) - 1;
	ivec2 i = ivec2(floor(t));
	vec2 f = t - vec2(i);
	classes = ivec4(
		earth_land_texel(i, last),
		earth_land_texel(i + ivec2(1, 0), last),
		earth_land_texel(i + ivec2(0, 1), last),
		earth_land_texel(i + ivec2(1, 1), last)
	);
	weights = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
}
]=]
local HEIGHT_GLSL = [=[
float earth_mosaic_bilinear(vec2 m) {
	ivec2 last = earth_height_last();
	vec2 t = m - 0.5;
	ivec2 i = ivec2(floor(t));
	vec2 f = t - vec2(i);
	return mix(
		mix(earth_height_texel(i, last), earth_height_texel(i + ivec2(1, 0), last), f.x),
		mix(earth_height_texel(i + ivec2(0, 1), last), earth_height_texel(i + ivec2(1, 1), last), f.x),
		f.y
	);
}

vec2 earth_water_texel(ivec2 c, ivec2 last) {
	return texelFetch(TEXTURE(terrain_bake.texture3), clamp(c, ivec2(0), last), 0).rg;
}

// the signed distance to the shore and the water level at a height mosaic position, far from water without a mosaic
vec2 earth_water(vec2 m) {
	vec4 water = earth_info(2, ]=] .. GRID .. [=[);

	if (water.w == 0.0) return vec2(]=] .. water_grid.FAR .. [=[.0, 0.0);

	ivec2 last = ivec2(earth_info(3, ]=] .. GRID .. [=[).xy) - 1;
	vec2 t = m * water.x + water.yz - 0.5;
	ivec2 i = ivec2(floor(t));
	vec2 f = t - vec2(i);
	return mix(
		mix(earth_water_texel(i, last), earth_water_texel(i + ivec2(1, 0), last), f.x),
		mix(earth_water_texel(i + ivec2(0, 1), last), earth_water_texel(i + ivec2(1, 1), last), f.x),
		f.y
	);
}

]=] .. water_grid.GLSL .. [=[

// how much relief finer than the height data each land class has (unknown, forest, shrub, grass, crop, urban, bare,
// sand, rock, wetland, snow)
const float EARTH_LAND_RELIEF[11] = float[](1.0, 1.0, 1.0, 0.7, 0.25, 0.25, 1.0, 0.6, 1.5, 0.3, 1.0);

// coarse height data is a surface model, with the trees in it: it is lowered by a share of the canopy blurred to its
// scale (not near water, whose levels come from the data as it is); then relief finer than the data: noise below the
// data's own spacing, stronger on steep ground and by the land class, none at the sea, near water or on roads (whose ground is the data's, blending to the relief beside over a shoulder); then
// the ground is carved under lakes and rivers
float terrain_height(vec2 p) {
	vec2 m = earth_map(p).xy;
	float ground = earth_mosaic_height(m);
	float h = ground;
	float spacing = earth_info(0, ]=] .. GRID .. [=[).w;
	vec2 water = earth_water(m);

	if (h > 0.0 && spacing >= 4.0) {
		ground -= min(]=] .. CANOPY_SINK .. [=[ * earth_canopy(m).y * earth_water_noise(water.x), max(ground - 0.5, 0.0));
		h = ground;
		float pixel = earth_info(1, ]=] .. GRID .. [=[).x;
		vec2 slope = vec2(
			earth_mosaic_bilinear(m + vec2(1.0, 0.0)) - earth_mosaic_bilinear(m - vec2(1.0, 0.0)),
			earth_mosaic_bilinear(m + vec2(0.0, 1.0)) - earth_mosaic_bilinear(m - vec2(0.0, 1.0))
		) / (2.0 * pixel);
		float wavelength = spacing * 2.0;
		float detail = pn_fbm_lod(p / wavelength + vec2(31.7, -12.3), 4, wavelength, terrain_tile_step());
		ivec4 classes;
		vec4 weights;
		earth_land(p, classes, weights);
		float relief = dot(
			weights,
			vec4(EARTH_LAND_RELIEF[classes.x], EARTH_LAND_RELIEF[classes.y], EARTH_LAND_RELIEF[classes.z], EARTH_LAND_RELIEF[classes.w])
		);
		h += detail * spacing * (0.04 + 0.3 * min(length(slope), 1.0)) * relief * smoothstep(0.0, 4.0, h) * earth_water_noise(water.x);
	}

	vec2 road = earth_road(m);

	if (road.y > 0.0) {
		h = mix(ground, h, smoothstep(0.0, max(EARTH_ROAD_SHOULDER[int(road.y) % ]=] .. road_grid.UNPAVED .. [=[], 0.5), road.x));
	}

	return earth_carve(h, water.x, water.y);
}
]=]
-- the earth's eight layers: grass, forest floor, rock, crop (the four a scatter set reads, so it can grow meadows,
-- woods, scree and fields apart), then sand, snow, dirt and gravel; a land class says which, the photo says how green
-- the ground is within it, and without a class the photo's colour decides alone. Under the canopy map's trees the
-- ground is forest floor, under water the bed is dirt
local LAYERS_GLSL = [=[
// layers 1 to 4 in a, 5 to 8 in b; veg is how green the photo is, snow how snow-like
void earth_class_layers(int land_class, float veg, float snow, float sandy, float low, out vec4 a, out vec4 b) {
	a = vec4(0.0);
	b = vec4(0.0);

	if (land_class == 1) { // forest
		a.y = 0.55 + 0.35 * veg;
		b.z = 1.0 - a.y;
	} else if (land_class == 2) { // shrub
		a.x = 0.5 + 0.3 * veg;
		a.z = 0.1;
		b.z = 0.4 - 0.3 * veg;
	} else if (land_class == 3) { // grass
		a.x = 0.6 + 0.4 * veg;
		b.z = 1.0 - a.x;
	} else if (land_class == 4) { // crop
		a.w = veg;
		b.z = 1.0 - veg;
	} else if (land_class == 5) { // urban
		a.x = 0.8 * veg;
		b.w = 1.0 - a.x;
	} else if (land_class == 6) { // bare
		a.x = 0.5 * veg;
		b.x = sandy * (1.0 - a.x);
		a.z = 0.15;
		b.z = (1.0 - sandy) * (1.0 - a.x);
		b.y = snow;
	} else if (land_class == 7) { // sand
		b.x = 1.0;
	} else if (land_class == 8) { // rock
		a.z = 0.8;
		b.w = 0.2;
		b.y = snow;
	} else if (land_class == 9) { // wetland
		a.x = 0.4 + 0.4 * veg;
		b.z = 1.0 - a.x;
	} else if (land_class == 10) { // snow
		b.y = 1.0;
	} else {
		b.y = snow;
		b.x = max(low, sandy) * (1.0 - b.y);
		a.x = 1.0 - b.x - b.y;
	}
}

void earth_layers(vec2 p, float h, vec3 n, out vec4 a, out vec4 b) {
	vec3 c = earth_photo(p);
	float brightest = max(c.r, max(c.g, c.b));
	float saturation = (brightest - min(c.r, min(c.g, c.b))) / max(brightest, 0.001);
	float veg = smoothstep(0.08, 0.3, (2.0 * c.g - c.r - c.b) / max(c.r + c.g + c.b, 0.001));
	float snow = smoothstep(0.35, 0.55, brightest) * (1.0 - smoothstep(0.1, 0.25, saturation));
	float sandy = smoothstep(0.15, 0.3, brightest) * smoothstep(0.2, 0.35, saturation) * step(c.g, c.r);
	float low = 1.0 - smoothstep(1.0, 4.0, h);
	ivec4 classes;
	vec4 weights;
	earth_land(p, classes, weights);
	a = vec4(0.0);
	b = vec4(0.0);

	for (int k = 0; k < 4; k++) {
		if (weights[k] > 0.0) {
			vec4 ca, cb;
			earth_class_layers(classes[k], veg, snow, sandy, low, ca, cb);
			a += ca * weights[k];
			b += cb * weights[k];
		}
	}

	// under trees the ground is forest floor, whatever the class says
	vec2 m = earth_map(p).xy;
	float cover = smoothstep(2.0, 6.0, earth_canopy(m).x);
	float moved = cover * (a.x + a.w + b.z);
	a.x *= 1.0 - cover;
	a.w *= 1.0 - cover;
	b.z *= 1.0 - cover;
	a.y += moved;
	// steep ground, and grey ground without a class, is rock whatever else
	float rock = max(
		smoothstep(0.3, 0.5, 1.0 - n.y),
		(1.0 - smoothstep(0.08, 0.16, saturation)) * smoothstep(0.08, 0.2, brightest) * (1.0 - b.y) * float(classes == ivec4(0))
	);
	a *= 1.0 - rock;
	b *= 1.0 - rock;
	a.z += rock;
	float sum = max(dot(a, vec4(1.0)) + dot(b, vec4(1.0)), 0.0001);
	a /= sum;
	b /= sum;
	float bed = 1.0 - smoothstep(-1.0, 0.5, earth_water(m).x);
	a *= 1.0 - bed;
	b *= 1.0 - bed;
	b.z += bed;
	// roads take their whole area from the layers scatter grows on: paved ones are gravel (under the road's colour),
	// unpaved ones dirt
	vec2 road = earth_road(m);

	if (road.y > 0.0) {
		float area = earth_road_area(road, terrain_bake_step());
		a *= 1.0 - area;
		b *= 1.0 - area;

		if (road.y >= ]=] .. road_grid.UNPAVED .. [=[.0) {
			b.z += area;
		} else {
			b.w += area;
		}
	}
}

vec4 terrain_splat(vec2 p, float h, vec3 n) {
	vec4 a, b;
	earth_layers(p, h, n, a, b);
	return a;
}
]=]
local SPLAT2_GLSL = [=[
vec4 terrain_splat2(vec2 p, float h, vec3 n) {
	vec4 a, b;
	earth_layers(p, h, n, a, b);
	return b;
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 p, float h, vec3 n) {
	vec3 c = earth_photo(p);
	vec2 road = earth_road(earth_map(p).xy);

	if (road.y > 0.0) {
		int id = int(road.y) % ]=] .. road_grid.UNPAVED .. [=[;
		vec3 surface = road.y >= ]=] .. road_grid.UNPAVED .. [=[.0 ? EARTH_ROAD_UNPAVED : EARTH_ROAD_COLOR[id];
		surface *= 0.85 + 0.3 * smoothstep(0.02, 0.25, dot(c, vec3(0.3, 0.59, 0.11)));
		c = mix(c, surface, earth_road_cover(road, terrain_bake_step()));
	}

	return c;
}
]=]

-- config: Anchor ({lat, lon}), Heights (a TileSet), Imagery (TileSets in the order they are tried: a chunk takes the
-- first whose bounds hold it at a zoom it serves, the next where its tiles are missing; optional), Layers (eight,
-- see LAYERS_GLSL), Bathymetry (a TileSet whose
-- heights fill the sea where Heights has none, optional: with it a missing height tile is sea and a height of exactly 0
-- is the sea's surface, as in Mapterhorn's data), BathymetryMaxZoom,
-- HeightDetailDivisor (the height data's pixels across a chunk are its detail size divided by this, at least its mesh samples);
-- source.Water may be set to an object that carves water into the chunks (PlanMosaic, FillMosaic, see water_bodies.lua),
-- source.Land, source.Roads and source.Canopy to tile grids (tile_grids.lua) of land_grid.lua, road_grid.lua and
-- canopy_tiles.lua
function EarthSource.New(config)
	assert(not config.Layers or #config.Layers == 8, "the earth has eight layers")
	local layer_ids = {0, 1, 2, 3, 4, 5, 6, 7}
	local self = setmetatable(
		ShaderSource.New{
			Header = HEADER,
			HeightGLSL = HEIGHT_GLSL,
			SplatGLSL = config.Layers and LAYERS_GLSL or nil,
			Splat2GLSL = config.Layers and SPLAT2_GLSL or nil,
			SelectChunkLayers = config.Layers and function()
				return config.Layers, layer_ids
			end or nil,
			ColorGLSL = config.Imagery and COLOR_GLSL or nil,
			ColorFormat = "r8g8b8a8_srgb",
			MinHeight = -11000,
			MaxHeight = 9000,
			Layers = config.Layers,
			TriplanarSharpness = config.TriplanarSharpness,
		},
		EarthSource
	)
	self.Anchor = geo.NewAnchor(config.Anchor[1], config.Anchor[2])
	self.Heights = config.Heights
	self.Imagery = config.Imagery
	self.ImageryUse = {}
	self.Bathymetry = config.Bathymetry
	self.BathymetryMaxZoom = config.BathymetryMaxZoom or 10
	self.HeightDetailDivisor = config.HeightDetailDivisor or 2
	self.ResolvesPerFrame = config.ResolvesPerFrame or 8
	self.Waiting = {}
	self.MosaicPool = {}
	return self
end

function EarthSource:WorldToLatLon(x, z)
	return geo.WorldToLatLon(self.Anchor, x, z)
end

function EarthSource:LatLonToWorld(lat, lon)
	return geo.LatLonToWorld(self.Anchor, lat, lon)
end

-- the grid of latitudes and longitudes over a chunk's domain (the chunk and a 16th of it around, where its bakes read)
local function build_domain(self, request)
	local margin = request.size / 16
	local step = (request.size + margin * 2) / (GRID - 1)
	local origin_x, origin_z = request.min_x - margin, request.min_z - margin
	local lats, lons = {}, {}

	for j = 0, GRID - 1 do
		for i = 0, GRID - 1 do
			local lat, lon = geo.WorldToLatLon(self.Anchor, origin_x + i * step, origin_z + j * step)
			lats[j * GRID + i + 1] = lat
			lons[j * GRID + i + 1] = lon
		end
	end

	local center_lat, center_lon = geo.WorldToLatLon(self.Anchor, request.min_x + request.size / 2, request.min_z + request.size / 2)
	return {
		origin_x = origin_x,
		origin_z = origin_z,
		step = step,
		lats = lats,
		lons = lons,
		center_lat = center_lat,
		center_lon = center_lon,
	}
end

-- the mosaic of a tile set at a zoom over the domain: its pixel rectangle and the tiles under it
local function plan_mosaic(set, domain, zoom)
	local size = set.TileSize
	local world = size * 2 ^ zoom
	local xs, ys = {}, {}
	local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge

	for k = 1, GRID * GRID do
		local x, y = geo.ToMercator(domain.lats[k], domain.lons[k], zoom, size)
		xs[k], ys[k] = x, y
		min_x, min_y = math.min(min_x, x), math.min(min_y, y)
		max_x, max_y = math.max(max_x, x), math.max(max_y, y)
	end

	local x0 = math.floor(min_x - 0.5) - 1
	local y0 = math.floor(min_y - 0.5) - 1
	local mosaic = {
		set = set,
		zoom = zoom,
		world = world,
		x0 = x0,
		y0 = y0,
		width = math.floor(max_x - 0.5) + 2 - x0 + 1,
		height = math.floor(max_y - 0.5) + 2 - y0 + 1,
		xs = xs,
		ys = ys,
		tiles = {},
	}
	local tiles_per_side = 2 ^ zoom
	local seen = {}

	for ty = math.clamp(math.floor(y0 / size), 0, tiles_per_side - 1), math.clamp(math.floor((y0 + mosaic.height - 1) / size), 0, tiles_per_side - 1) do
		for column = math.floor(x0 / size), math.floor((x0 + mosaic.width - 1) / size) do
			local tx = column % tiles_per_side

			if not seen[ty * tiles_per_side + tx] then
				seen[ty * tiles_per_side + tx] = true
				mosaic.tiles[#mosaic.tiles + 1] = {tx, ty}
			end
		end
	end

	return mosaic
end

local function choose_zoom(set, domain, request, pixels)
	local zoom = geo.GetZoomFor(domain.center_lat, request.size / pixels, set.TileSize, set.MaxZoom)

	while zoom > 0 do
		local mosaic = plan_mosaic(set, domain, zoom)

		if mosaic.width <= MAX_MOSAIC and mosaic.height <= MAX_MOSAIC then
			return zoom, mosaic
		end

		zoom = zoom - 1
	end

	return 0, plan_mosaic(set, domain, 0)
end

-- "ready" when every tile of the mosaic is decoded, "loading" while any is on its way, "failed" when any will not come
local function mosaic_state(mosaic)
	local set = mosaic.set
	local state = "ready"

	for _, tile in ipairs(mosaic.tiles) do
		local tile_state = set:Request(mosaic.zoom, tile[1], tile[2])

		if
			tile_state == "missing" and
			not set.MissingIsSea or
			tile_state == "unavailable" or
			tile_state == "failed"
		then
			return "failed"
		end

		if tile_state == "missing" then tile_state = "ready" end

		if tile_state ~= "ready" then state = "loading" end
	end

	return state
end

-- the mosaic of the finest zoom at or below the planned one whose tiles all exist, or nil while it is loading
local function resolve_mosaic(item, kind)
	local mosaic = item[kind]

	while true do
		local state = mosaic_state(mosaic)

		if state == "ready" then return mosaic end

		if state == "loading" then return nil end

		if mosaic.zoom == 0 then return false end

		mosaic = plan_mosaic(mosaic.set, item.domain, mosaic.zoom - 1)
		item[kind] = mosaic
	end
end

-- upload data is copied into a staging buffer when it is recorded, so a bake's arrays are reused between bakes
local scratch = {}

local function get_scratch(name, bytes)
	local entry = scratch[name]

	if not entry or entry.bytes < bytes then
		entry = {bytes = bytes, data = ByteArray(bytes)}
		scratch[name] = entry
	end

	return entry.data
end

-- the mosaic's pixels in rows of stride pixels (at least its width), into the named scratch array if one is given
local function compose(mosaic, bytes_per_pixel, stride, rows, scratch_name)
	local set = mosaic.set
	local size = set.TileSize
	local world = mosaic.world
	local width, height = mosaic.width, mosaic.height
	local row_bytes = (stride or width) * bytes_per_pixel
	local pixels = scratch_name and
		get_scratch(scratch_name, row_bytes * (rows or height)) or
		ByteArray(row_bytes * (rows or height))

	for row = 0, height - 1 do
		local gy = math.clamp(mosaic.y0 + row, 0, world - 1)
		local ty = math.floor(gy / size)
		local iy = gy - ty * size
		local column = 0

		while column < width do
			local gx = (mosaic.x0 + column) % world
			local tx = math.floor(gx / size)
			local ix = gx - tx * size
			local run = math.min(size - ix, width - column)
			local tile = set:Get(mosaic.zoom, tx, ty)

			if tile then
				ffi.copy(
					pixels + row * row_bytes + column * bytes_per_pixel,
					ffi.cast("const uint8_t *", tile.data) + (iy * size + ix) * bytes_per_pixel,
					run * bytes_per_pixel
				)
			else
				local floats = ffi.cast("float *", pixels + row * row_bytes + column * bytes_per_pixel)

				for i = 0, run - 1 do
					floats[i] = NO_DATA
				end
			end

			column = column + run
		end
	end

	return pixels
end

-- the sea in a height mosaic (texels of exactly 0, or no data) takes the bathymetry, which near coasts is no higher than the sea
local function fill_sea(pixels, stride, heights, bathymetry)
	local h = ffi.cast("float *", pixels)
	local width = heights.width
	local sea_found = false

	for y = 0, heights.height - 1 do
		for x = 0, width - 1 do
			local v = h[y * stride + x]

			if v == 0 or v == NO_DATA then
				sea_found = true

				break
			end
		end

		if sea_found then break end
	end

	if not sea_found then return end

	local b = ffi.cast("const float *", compose(bathymetry, 4))
	local scale = bathymetry.set.TileSize * 2 ^ bathymetry.zoom / (
			heights.set.TileSize * 2 ^ heights.zoom
		)
	local bw, bh = bathymetry.width, bathymetry.height

	for y = 0, heights.height - 1 do
		local by = math.clamp((heights.y0 + y + 0.5) * scale - bathymetry.y0 - 0.5, 0, bh - 1.001)
		local iy = math.floor(by)
		local fy = by - iy

		for x = 0, width - 1 do
			local i = y * stride + x
			local v = h[i]

			if v == 0 or v == NO_DATA then
				local bx = math.clamp((heights.x0 + x + 0.5) * scale - bathymetry.x0 - 0.5, 0, bw - 1.001)
				local ix = math.floor(bx)
				local fx = bx - ix
				local o = iy * bw + ix
				local sea = math.lerp(fy, math.lerp(fx, b[o], b[o + 1]), math.lerp(fx, b[o + bw], b[o + bw + 1]))
				h[i] = v == 0 and math.min(sea, 0) or sea
			end
		end
	end
end

-- mosaic textures are pooled in sizes rounded up to POOL_STEP, so they keep their bindless slots and are only written
local POOL_STEP = 32

local function pool_size(n)
	return math.ceil(n / POOL_STEP) * POOL_STEP
end

local function acquire_texture(self, width, height, format, sampler)
	local key = width .. ":" .. height .. ":" .. format
	local pool = self.MosaicPool[key]

	if pool and pool[1] then return table.remove(pool) end

	local texture = Texture.New{
		width = width,
		height = height,
		format = format,
		mip_map_levels = 1,
		sampler = sampler,
		image = {usage = {"sampled", "transfer_dst"}},
		cmd = ShaderSource.GetBatchCommandBuffer(self),
	}
	texture.mosaic_key = key
	return texture
end

local function release_texture(self, texture)
	local pool = self.MosaicPool[texture.mosaic_key]

	if not pool then
		pool = {}
		self.MosaicPool[texture.mosaic_key] = pool
	end

	pool[#pool + 1] = texture
end

-- the texture bound where a chunk has no imagery or water mosaic; Finish removes it, as Terrain:Start finishes its source
-- before it bakes
local function get_blank(self)
	self.Blank = self.Blank or
		Texture.New{
			width = 1,
			height = 1,
			format = "r8g8b8a8_srgb",
			buffer = ffi.new("uint8_t[4]", 118, 118, 118, 255),
			mip_map_levels = 1,
			sampler = LINEAR,
		}
	return self.Blank
end

local function bake(self, item, heights, imagery, bathymetry, land, roads, canopy)
	local request = item.request
	local domain = item.domain
	local info = FloatArray(GRID * (GRID + 2) * 4)

	for k = 1, GRID * GRID do
		local o = (k - 1) * 4
		info[o] = heights.xs[k] - heights.x0
		info[o + 1] = heights.ys[k] - heights.y0

		if imagery then
			info[o + 2] = imagery.xs[k] - imagery.x0
			info[o + 3] = imagery.ys[k] - imagery.y0
		end
	end

	local o = GRID * GRID * 4
	local height_width, height_height = pool_size(heights.width), pool_size(heights.height)
	info[o] = domain.origin_x
	info[o + 1] = domain.origin_z
	info[o + 2] = domain.step
	local native_zoom = self.Heights.NativeZoom(domain.center_lat, domain.center_lon)
	info[o + 3] = geo.GetPixelSize(domain.center_lat, math.min(native_zoom, self.Heights.MaxZoom), heights.set.TileSize)
	info[o + 4] = geo.GetPixelSize(domain.center_lat, heights.zoom, heights.set.TileSize)
	info[o + 5] = heights.width
	info[o + 6] = heights.height
	local info_texture = acquire_texture(self, GRID, GRID + 2, "r32g32b32a32_sfloat", NEAREST)
	local height_texture = acquire_texture(self, height_width, height_height, "r32_sfloat", NEAREST)
	local height_pixels = compose(heights, 4, height_width, height_height, "heights")

	if bathymetry then fill_sea(height_pixels, height_width, heights, bathymetry) end

	local blank = get_blank(self)
	local textures = {info_texture, height_texture, blank, blank, blank, blank}
	local uploads = {{info_texture, info}, {height_texture, height_pixels}}
	local water = self.Water and self.Water:PlanMosaic(heights)

	if water then
		local width, height = pool_size(water.width), pool_size(water.height)
		local pixels = ffi.cast("float *", get_scratch("water", width * height * 8))
		self.Water:FillMosaic(water, pixels, width)
		info[o + 8] = water.scale
		info[o + 9] = water.offset_x
		info[o + 10] = water.offset_y
		info[o + 11] = 1
		info[o + 12] = water.width
		info[o + 13] = water.height
		textures[4] = acquire_texture(self, width, height, "r32g32_sfloat", NEAREST)
		uploads[#uploads + 1] = {textures[4], pixels}
	end

	if land then
		local width, height = pool_size(land.width), pool_size(land.height)
		local pixels = get_scratch("land", width * height)
		self.Land:FillMosaic(land, pixels, width)
		info[o + 16] = land.scale
		info[o + 17] = land.offset_x
		info[o + 18] = land.offset_y
		info[o + 19] = 1
		info[o + 20] = land.width
		info[o + 21] = land.height
		textures[5] = acquire_texture(self, width, height, "r8_unorm", NEAREST)
		uploads[#uploads + 1] = {textures[5], pixels}
	end

	if canopy then
		local width, height = pool_size(canopy.width), pool_size(canopy.height)
		local pixels = get_scratch("canopy", width * height * 2)
		self.Canopy:FillMosaic(canopy, pixels, width)
		local c = GRID * (GRID + 1) * 4
		info[c] = canopy.scale
		info[c + 1] = canopy.offset_x
		info[c + 2] = canopy.offset_y
		info[c + 3] = 1
		info[c + 4] = canopy.width
		info[c + 5] = canopy.height
		textures[7] = acquire_texture(self, width, height, "r8g8_unorm", NEAREST)
		uploads[#uploads + 1] = {textures[7], pixels}
	end

	if roads then
		local width, height = pool_size(roads.width), pool_size(roads.height)
		local pixels = get_scratch("roads", width * height * 2)
		self.Roads:FillMosaic(roads, pixels, width)
		info[o + 24] = roads.scale
		info[o + 25] = roads.offset_x
		info[o + 26] = roads.offset_y
		info[o + 27] = 1
		info[o + 28] = roads.width
		info[o + 29] = roads.height
		textures[6] = acquire_texture(self, width, height, "r8g8_unorm", NEAREST)
		uploads[#uploads + 1] = {textures[6], pixels}
	end

	if imagery then
		local width, height = pool_size(imagery.width), pool_size(imagery.height)
		textures[3] = acquire_texture(self, width, height, "r8g8b8a8_srgb", LINEAR)
		uploads[#uploads + 1] = {textures[3], compose(imagery, 4, width, height, "imagery")}
	end

	request.textures = textures
	request.uploads = uploads
	request.height_zoom = heights.zoom
	request.imagery_zoom = imagery and imagery.zoom

	if imagery then self.ImageryUse[imagery.set] = system.GetElapsedTime() end

	local callback = item.callback

	ShaderSource.RequestChunk(self, request, function(chunk)
		for _, texture in ipairs(textures) do
			if texture ~= blank then release_texture(self, texture) end
		end

		request.textures = nil
		request.uploads = nil
		callback(chunk)
	end)
end

local function inside(domain, bounds)
	for k = 1, GRID * GRID do
		local lat, lon = domain.lats[k], domain.lons[k]

		if lat < bounds[1] or lon < bounds[2] or lat > bounds[3] or lon > bounds[4] then
			return false
		end
	end

	return true
end

-- plans the chunk's imagery from the first source from index on whose bounds hold it and that serves its zoom; the last
-- source is taken whatever its bounds and zooms, false when there is no source after index
local function choose_imagery(self, item, index)
	local chain = self.Imagery
	local request = item.request

	for i = index, #chain do
		local set = chain[i]
		local zoom = geo.GetZoomFor(item.domain.center_lat, request.size / request.color_size, set.TileSize, set.MaxZoom)

		if
			i == #chain or
			zoom >= set.MinZoom and
			(
				not set.Bounds or
				inside(item.domain, set.Bounds)
			)
		then
			local _, mosaic = choose_zoom(set, item.domain, request, request.color_size)
			item.imagery = mosaic
			item.imagery_index = i
			return true
		end
	end

	return false
end

-- the imagery mosaic once its tiles are in: missing tiles move it down the chain, at the last source to coarser zooms
local function resolve_imagery(self, item)
	while item.imagery_index < #self.Imagery do
		local state = mosaic_state(item.imagery)

		if state == "ready" then return item.imagery end

		if state == "loading" then return nil end

		choose_imagery(self, item, item.imagery_index + 1)
	end

	return resolve_mosaic(item, "imagery")
end

-- returns true when the item was baked (or dropped)
local function try_resolve(self, item)
	if item.request.cancelled then return true end

	local heights = resolve_mosaic(item, "heights")
	local imagery = false
	local bathymetry = false

	if item.imagery then imagery = resolve_imagery(self, item) end

	if item.bathymetry then bathymetry = resolve_mosaic(item, "bathymetry") end

	-- heights that cannot be had even at zoom 0 wait for the failed tiles' retry, a chunk without imagery is grey
	if not heights or imagery == nil or bathymetry == nil then return false end

	local land = self.Land and self.Land:PlanMosaic(heights)

	if land == nil and self.Land then return false end

	local roads = self.Roads and self.Roads:PlanMosaic(heights)

	if roads == nil and self.Roads then return false end

	local canopy = self.Canopy and self.Canopy:PlanMosaic(heights)

	if canopy == nil and self.Canopy then return false end

	bake(
		self,
		item,
		heights,
		imagery or nil,
		bathymetry or nil,
		land or nil,
		roads or nil,
		canopy or nil
	)
	return true
end

function EarthSource:RequestChunk(request, callback)
	local domain = build_domain(self, request)
	local height_pixels = math.max(
		(request.samples or 2) - 1,
		math.floor((request.detail_size or 0) / self.HeightDetailDivisor)
	)
	local _, heights = choose_zoom(self.Heights, domain, request, height_pixels)
	local item = {
		request = request,
		callback = callback,
		domain = domain,
		heights = heights,
	}

	if self.Bathymetry then
		local zoom = heights.zoom + math.floor(math.log(heights.set.TileSize / self.Bathymetry.TileSize) / math.log(2) + 0.5)
		item.bathymetry = plan_mosaic(
			self.Bathymetry,
			domain,
			math.clamp(zoom, 0, math.min(self.BathymetryMaxZoom, self.Bathymetry.MaxZoom))
		)
	end

	if self.Imagery and request.color_size then choose_imagery(self, item, 1) end

	if not try_resolve(self, item) then self.Waiting[#self.Waiting + 1] = item end
end

function EarthSource:Update()
	self.Heights:Update()

	if self.Bathymetry then self.Bathymetry:Update() end

	if self.Imagery then
		for _, set in ipairs(self.Imagery) do
			set:Update()
		end
	end

	local waiting = self.Waiting
	local resolved = 0
	local count = 0

	for i = 1, #waiting do
		local item = waiting[i]
		waiting[i] = nil

		if resolved < self.ResolvesPerFrame and try_resolve(self, item) then
			if not item.request.cancelled then resolved = resolved + 1 end
		else
			count = count + 1
			waiting[count] = item
		end
	end

	ShaderSource.Update(self)
end

function EarthSource:Finish()
	ShaderSource.Finish(self)

	for _, pool in pairs(self.MosaicPool) do
		for _, texture in ipairs(pool) do
			texture:Remove()
		end
	end

	self.MosaicPool = {}

	if self.Blank then
		self.Blank:Remove()
		self.Blank = nil
	end
end

function EarthSource:GetPendingCount()
	local batches, chunks = ShaderSource.GetPendingCount(self)
	return batches, chunks + #self.Waiting
end

-- a GRID x GRID domain over a latitude, longitude box {south, west, north, east}
local function latlon_domain(box)
	local lats, lons = {}, {}

	for j = 0, GRID - 1 do
		for i = 0, GRID - 1 do
			lats[j * GRID + i + 1] = box.south + (box.north - box.south) * j / (GRID - 1)
			lons[j * GRID + i + 1] = box.west + (box.east - box.west) * i / (GRID - 1)
		end
	end

	return {lats = lats, lons = lons, center_lat = (box.south + box.north) / 2}
end

-- the height data over a latitude, longitude box at a zoom, or the finest coarser one that has it: state = {south,
-- west, north, east, zoom} is kept by the caller between calls; nil while its tiles load, false when not even zoom 0
-- has them, else {pixels (float string, -32768 where there is no land data), x0, y0 (in global mercator pixels),
-- width, height, zoom, tile_size}
function EarthSource:RequestHeights(state)
	if not state.domain then
		state.domain = latlon_domain(state)
		state.heights = plan_mosaic(self.Heights, state.domain, state.zoom)
	end

	local mosaic = resolve_mosaic(state, "heights")

	if not mosaic then return mosaic end

	return {
		pixels = ffi.string(compose(mosaic, 4), mosaic.width * mosaic.height * 4),
		x0 = mosaic.x0,
		y0 = mosaic.y0,
		width = mosaic.width,
		height = mosaic.height,
		zoom = mosaic.zoom,
		tile_size = mosaic.set.TileSize,
	}
end

-- a photo over a latitude, longitude box for colouring things on the ground: state = {south, west, north, east, meters
-- (the pixel size wanted)} is kept by the caller between calls; nil while its tiles load, false when no source of the
-- imagery chain has the box this sharp, else {pixels (rgba string), x0, y0 (in global mercator pixels), width, height,
-- zoom, tile_size, meters}
function EarthSource:RequestPhoto(state)
	if not state.domain then
		state.domain = latlon_domain(state)
		state.index = 0
	end

	local domain = state.domain
	local chain = self.Imagery

	while true do
		if not state.mosaic then
			for i = state.index + 1, #chain do
				local set = chain[i]
				local zoom = geo.GetZoomFor(domain.center_lat, state.meters, set.TileSize, set.MaxZoom)
				state.index = i

				if
					zoom >= set.MinZoom and
					(
						not set.Bounds or
						inside(domain, set.Bounds)
					)
					and
					geo.GetPixelSize(domain.center_lat, zoom, set.TileSize) <= state.meters * 1.5
				then
					state.mosaic = plan_mosaic(set, domain, zoom)

					break
				end
			end

			if not state.mosaic then return false end
		end

		local mosaic = state.mosaic
		local tiles = mosaic_state(mosaic)

		if tiles == "loading" then return nil end

		if tiles == "ready" then
			return {
				pixels = ffi.string(compose(mosaic, 4), mosaic.width * mosaic.height * 4),
				x0 = mosaic.x0,
				y0 = mosaic.y0,
				width = mosaic.width,
				height = mosaic.height,
				zoom = mosaic.zoom,
				tile_size = mosaic.set.TileSize,
				meters = geo.GetPixelSize(domain.center_lat, mosaic.zoom, mosaic.set.TileSize),
			}
		end

		state.mosaic = nil
	end
end

-- the imagery sets a chunk was baked from in the last seconds
function EarthSource:GetImageryInUse(seconds)
	local now = system.GetElapsedTime()
	local used = {}

	for _, set in ipairs(self.Imagery or {}) do
		if self.ImageryUse[set] and now - self.ImageryUse[set] < seconds then
			used[#used + 1] = set
		end
	end

	return used
end

function EarthSource:GetWaitingCount()
	return #self.Waiting
end

local function sample_set(set, lat, lon)
	local size = set.TileSize

	for zoom = set.MaxZoom, 0, -1 do
		local world = size * 2 ^ zoom
		local px, py = geo.ToMercator(lat, lon, zoom, size)
		px = (px - 0.5) % world
		py = math.clamp(py - 0.5, 0, world - 1)
		local tx, ty = math.floor(px / size), math.floor(py / size)
		local tile = set:Get(zoom, tx, ty)

		if tile then
			local fx = math.min(px - tx * size, size - 1.001)
			local fy = math.min(py - ty * size, size - 1.001)
			local ix, iy = math.floor(fx), math.floor(fy)
			local data = tile.data
			local i = iy * size + ix
			return math.lerp(
				fy - iy,
				math.lerp(fx - ix, data[i], data[i + 1]),
				math.lerp(fx - ix, data[i + size], data[i + size + 1])
			)
		end

		if set.MissingIsSea and set:GetState(zoom, tx, ty) == "missing" then
			return nil
		end
	end
end

-- the height above sea level at a world x, z from the finest decoded tiles there, nil when none are
function EarthSource:SampleLocalHeight(x, z)
	return self:SampleLatLonHeight(geo.WorldToLatLon(self.Anchor, x, z))
end

function EarthSource:SampleLatLonHeight(lat, lon)
	local h = sample_set(self.Heights, lat, lon)

	if self.Bathymetry and (h == nil or h == 0) then
		local sea = sample_set(self.Bathymetry, lat, lon)

		if sea then return h and math.min(sea, 0) or sea end
	end

	return h
end

return EarthSource
