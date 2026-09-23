local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local ddgi = library()
-- Dynamic diffuse global illumination (Majercik et al. 2019) over hardware ray
-- tracing. A camera-centred grid of probes each trace RAYS_PER_PROBE rays per
-- frame; the hits are shaded (direct light plus last frame's probe irradiance
-- for the infinite bounce) and blended into two octahedral atlases per probe:
-- irradiance, and the mean/mean^2 hit distance used for the Chebyshev
-- visibility test that keeps light from leaking through walls.
ddgi.enabled = true
ddgi.PROBES_PER_AXIS = 24
ddgi.PROBE_SPACING = 1.0
-- Nested volumes of the same P^3 probes, each twice the spacing of the one
-- inside it, so the probes reach far while the view stays on the fine ones.
-- A point is shaded by the finest cascade that holds it, fading into the next
-- over CASCADE_BLEND cells before that cascade's edge.
ddgi.CASCADES = 4
ddgi.CASCADE_BLEND = 2.0
-- The cascades are fitted to the scene's bounds. Each cascade has a budget of
-- P^3 probes at its fixed spacing; an axis the scene is short along (the
-- height of a flat level) only gets the probes that cover it plus a cell on
-- each side, and the rest of the budget spreads the cascade further along the
-- other axes. Coarse cascades are skipped while a finer one holds the whole
-- scene, and each cascade stays over the scene instead of empty space around
-- a camera that left it. The fitted region reaches at most MAX_COVERAGE
-- metres from the camera (infinite terrain, a stray far away object) and at
-- least MIN_COVERAGE metres from its centre to each side (a single small
-- model). Changing an axis' probe count throws the cascade's history away.
ddgi.MIN_COVERAGE = 4
ddgi.MAX_COVERAGE = 192
ddgi.MIN_PROBES_PER_AXIS = 4
ddgi.RAYS_PER_PROBE = 128
-- Emissive surfaces light the probes only through emitter samples: per probe
-- and frame, EMITTER_SAMPLES shadow rays to points on emissive triangles. A
-- small or partly hidden emitter is rarely hit by the uniform rays, which
-- made it flicker (and the brightest ray clamp mostly dropped it). Each sample
-- draws EMITTER_CANDIDATES points in proportion to their triangle's power and
-- keeps one by how much light it would bring the probe (resampled importance
-- sampling), so samples aren't spent on faces turned away or far off.
ddgi.EMITTER_SAMPLES = 32
ddgi.EMITTER_CANDIDATES = 8
-- octahedral tile sizes including the one texel border that makes bilinear
-- sampling wrap correctly across the octahedron's edges
ddgi.IRRADIANCE_TEXELS = 8
ddgi.DISTANCE_TEXELS = 16
ddgi.MAX_RAY_DISTANCE = 1000.0
-- How much of a probe texel's history survives a frame, given for 60 fps and
-- scaled by the frame time, so light takes as long to settle at any frame
-- rate. A texel whose per frame estimates jump around (a doorway that one or
-- two rays see through) keeps HYSTERESIS, a steady one MIN_HYSTERESIS, which
-- follows gradual changes (the sun moving) sooner. NOISE_RANGE is the mean
-- relative deviation from the texel's average at which it counts as fully
-- noisy. A probe that just scrolled in averages its frames evenly until it
-- has had enough of them for the hysteresis to take over.
ddgi.HYSTERESIS = 0.99
ddgi.MIN_HYSTERESIS = 0.95
ddgi.NOISE_RANGE = 0.25
-- a texel whose every frame grew or shrank by more than this factor against
-- its history, ADAPT_FRAMES frames in a row, catches up quickly
ddgi.IRRADIANCE_THRESHOLD = 2.0
ddgi.ADAPT_FRAMES = 6
-- local lights are treated as spheres of this radius (in probe spacings) when
-- lighting ray hits. A probe can't resolve a hot spot smaller than this, and a
-- ray landing right next to a lamp would otherwise outweigh all the others
-- and light up the whole probe for a frame
ddgi.LIGHT_RADIUS = 0.1
-- sharpness of the cosine lobe the hit distances are averaged with
ddgi.DISTANCE_EXPONENT = 50.0
-- surface bias along the normal and towards the viewer, in probe spacings
ddgi.NORMAL_BIAS = 0.1
ddgi.VIEW_BIAS = 0.3
-- probes whose rays mostly hit back faces are inside geometry and are skipped
ddgi.BACKFACE_THRESHOLD = 0.25
-- Probes move off their grid point (by at most PROBE_MAX_OFFSET spacings) to
-- get out of geometry they landed in and away from surfaces closer than
-- RELOCATION_DISTANCE spacings. A probe inside a box would otherwise be
-- disabled, and the probes that take over its corner may be behind a wall.
ddgi.RELOCATION = true
ddgi.RELOCATION_DISTANCE = 0.25
ddgi.PROBE_MAX_OFFSET = 0.45
ddgi.SKY_INTENSITY = 1.0
ddgi.RANDOM_ROTATION = true
ddgi.RESOLVE_SCALE = 1.0
-- The screen blends the 3x3x3 probes around a point with quadratic B-spline
-- weights instead of the 2x2x2 around it trilinearly. Trilinear is only
-- continuous, its slope jumps at every cell face, which draws the grid into
-- light that falls off steeply (lamps at night). The B-spline's slope is
-- continuous too, at the cost of a little extra blur and 27 probe lookups.
-- Probe rays always use trilinear; their light is blurred into the probes.
ddgi.SMOOTH_BLEND = true
-- 0 off, 1 probe irradiance, 2 probe mean hit distance (see passes/ddgi.lua)
ddgi.DEBUG_PROBES = 0
-- brightness of the debug view's markers, which have no light of their own
ddgi.DEBUG_SCALE = 1.0
-- the cascade whose probes the debug view draws
ddgi.DEBUG_CASCADE = 0
-- stored in a ray's distance slot when it missed everything
ddgi.MISS_DISTANCE = 1e27

function ddgi.GetCascadeSpacing(cascade)
	return ddgi.PROBE_SPACING * 2 ^ cascade
end

function ddgi.GetProbeCount()
	return ddgi.PROBES_PER_AXIS ^ 3 * ddgi.CASCADES
end

function ddgi.GetRayCount()
	return ddgi.GetProbeCount() * (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES)
end

function ddgi.IsActive()
	return ddgi.enabled
end

-- rgb = irradiance, a = sky visibility: the contract the lighting pass reads
-- through gi_screen_tex
function ddgi.GetScreenTexture()
	local resolve = render3d.pipelines.ddgi_resolve
	return resolve and resolve:GetFramebuffer(1):GetAttachment(1) or nil
end

-- drawn over the lit image by the lighting pass; rgb = colour, a = coverage
function ddgi.GetDebugOverlayTexture()
	if ddgi.DEBUG_PROBES == 0 then return nil end

	return render3d.pipelines.ddgi_probe_debug:GetFramebuffer(1):GetAttachment(1)
end

function ddgi.RTSupported()
	return render.GetDevice().ray_tracing_supported
end

function ddgi.ResetHistory()
	ddgi.force_reset = true
end

do
	local state = {
		frame = -1,
		cascades = {},
		cascade_count = 0,
		region = {},
		rotation = {x = 0, y = 0, z = 0, w = 1},
		reset_mask = 0,
		rt_ready = false,
	}

	-- Shoemake's uniform random rotation
	local function random_rotation(q)
		local u1, u2, u3 = math.random(), math.random() * 2 * math.pi, math.random() * 2 * math.pi
		local a, b = math.sqrt(1 - u1), math.sqrt(u1)
		q.x = a * math.sin(u2)
		q.y = a * math.cos(u2)
		q.z = b * math.sin(u3)
		q.w = b * math.cos(u3)
	end

	-- one axis of the region the cascades are fitted to
	local function fit_region(axis, camera, bounds_min, bounds_max)
		local lo, hi = camera - ddgi.MIN_COVERAGE, camera + ddgi.MIN_COVERAGE

		if bounds_min then
			lo = math.max(bounds_min[axis], camera - ddgi.MAX_COVERAGE)
			hi = math.min(bounds_max[axis], camera + ddgi.MAX_COVERAGE)

			-- the scene lies entirely beyond MAX_COVERAGE
			if hi < lo then
				lo, hi = camera - ddgi.MIN_COVERAGE, camera + ddgi.MIN_COVERAGE
			end
		end

		if hi - lo < ddgi.MIN_COVERAGE * 2 then
			local mid = (lo + hi) / 2
			lo, hi = mid - ddgi.MIN_COVERAGE, mid + ddgi.MIN_COVERAGE
		end

		return lo, hi
	end

	-- Probes a cascade needs along an axis to cover size metres at spacing:
	-- the cells it spans (one more when it straddles cell boundaries) plus a
	-- cell of padding on each side. The current count is kept while it is
	-- enough and not much more, so a region that wobbles does not keep
	-- resetting the cascade.
	local function fit_need(size, spacing, current)
		local need = math.ceil(size / spacing) + 4

		if current and current >= need and current <= need + math.max(2, need * 0.25) then
			return current
		end

		return need
	end

	-- Splits the P^3 budget over the axes: the axis that needs the fewest
	-- probes takes what it needs (or its cube root share), the next the square
	-- root of what is left, and the last the rest.
	local function distribute(cascade)
		local budget = ddgi.PROBES_PER_AXIS ^ 3
		local a, b, c = "x", "y", "z"
		local need = cascade.need

		if need[a] > need[b] then a, b = b, a end

		if need[b] > need[c] then b, c = c, b end

		if need[a] > need[b] then a, b = b, a end

		local n = math.max(math.min(need[a], math.floor(budget ^ (1 / 3) + 1e-6)), ddgi.MIN_PROBES_PER_AXIS)
		cascade.size[a] = n
		budget = math.floor(budget / n)
		n = math.max(math.min(need[b], math.floor(math.sqrt(budget) + 1e-6)), ddgi.MIN_PROBES_PER_AXIS)
		cascade.size[b] = n
		budget = math.floor(budget / n)
		cascade.size[c] = math.max(math.min(need[c], budget), ddgi.MIN_PROBES_PER_AXIS)
	end

	-- The lowest probe coordinate of a cascade with count probes along one
	-- axis: centred on the region (padded by a cell) when it can hold all of
	-- it, otherwise centred on the camera but kept inside the padded region.
	-- The second result is whether it holds all of it.
	local function fit_base(camera, lo, hi, spacing, count)
		local lo_cell, hi_cell = math.floor(lo / spacing) - 1, math.ceil(hi / spacing) + 1

		if hi_cell - lo_cell <= count - 1 then
			return lo_cell - math.floor((count - 1 - (hi_cell - lo_cell)) / 2), true
		end

		return math.clamp(math.floor(camera / spacing) - math.floor(count / 2), lo_cell, hi_cell - (count - 1)),
		false
	end

	-- Everything the passes of one frame must agree on: where each cascade is,
	-- its probe counts and how many cascades are in use, how this frame's rays
	-- are rotated, and which cascades' history is garbage (fresh atlases, a
	-- cascade that was skipped, or one whose layout changed) and must be
	-- overwritten instead of blended.
	function ddgi.GetFrameState()
		local frame = system.GetFrameNumber()

		if state.frame == frame then return state end

		state.frame = frame
		local position = render3d.GetRenderCamera():GetPosition()
		local bounds_min, bounds_max = scene_bvh.GetBounds()
		local region = state.region
		region.min_x, region.max_x = fit_region(0, position.x, bounds_min, bounds_max)
		region.min_y, region.max_y = fit_region(1, position.y, bounds_min, bounds_max)
		region.min_z, region.max_z = fit_region(2, position.z, bounds_min, bounds_max)
		local irradiance = render3d.pipelines.ddgi_irradiance
		local framebuffers = irradiance and irradiance.framebuffers
		local reset_mask = 0

		if ddgi.force_reset or framebuffers ~= state.history_framebuffers then
			reset_mask = bit.lshift(1, ddgi.CASCADES) - 1
		end

		local count = ddgi.CASCADES

		for c = 1, ddgi.CASCADES do
			local spacing = ddgi.GetCascadeSpacing(c - 1)
			local cascade = state.cascades[c] or {need = {}, size = {}}
			local need, size = cascade.need, cascade.size
			local old_x, old_y, old_z = size.x, size.y, size.z

			-- a cube until the scene is built
			if bounds_min then
				need.x = fit_need(region.max_x - region.min_x, spacing, need.x)
				need.y = fit_need(region.max_y - region.min_y, spacing, need.y)
				need.z = fit_need(region.max_z - region.min_z, spacing, need.z)
				distribute(cascade)
			else
				size.x, size.y, size.z = ddgi.PROBES_PER_AXIS, ddgi.PROBES_PER_AXIS, ddgi.PROBES_PER_AXIS
			end

			-- every probe of the cascade changed slot, or it comes back into use
			-- holding whatever it had when it was dropped
			if
				c > state.cascade_count or
				spacing ~= cascade.spacing or
				size.x ~= old_x or
				size.y ~= old_y or
				size.z ~= old_z
			then
				reset_mask = bit.bor(reset_mask, bit.lshift(1, c - 1))
			end

			cascade.spacing = spacing
			local holds_x, holds_y, holds_z
			cascade.x, holds_x = fit_base(position.x, region.min_x, region.max_x, spacing, size.x)
			cascade.y, holds_y = fit_base(position.y, region.min_y, region.max_y, spacing, size.y)
			cascade.z, holds_z = fit_base(position.z, region.min_z, region.max_z, spacing, size.z)
			-- only before the scene is built does a cube not know where it ends
			cascade.holds = bounds_min and
				(
					(
						holds_x and
						1 or
						0
					) + (
						holds_y and
						2 or
						0
					) + (
						holds_z and
						4 or
						0
					)
				)
				or
				0
			state.cascades[c] = cascade

			-- the first cascade that holds the whole scene is the last one needed
			if
				bounds_min and
				c < count and
				size.x >= need.x and
				size.y >= need.y and
				size.z >= need.z
			then
				count = c
			end
		end

		state.cascade_count = count
		state.reset_mask = reset_mask

		if ddgi.RANDOM_ROTATION then
			random_rotation(state.rotation)
		else
			state.rotation.x, state.rotation.y, state.rotation.z, state.rotation.w = 0, 0, 0, 1
		end

		state.history_framebuffers = framebuffers
		state.rt_ready = false
		ddgi.force_reset = false
		return state
	end
end

-- The same spherical fibonacci + rotation as ddgi_ray_direction in GLSL.
function ddgi.GetRayDirection(index, rotation)
	local n = ddgi.RAYS_PER_PROBE
	local golden = (math.sqrt(5) - 1) / 2
	local phi = 2 * math.pi * ((index * golden) % 1)
	local cos_theta = 1 - (2 * index + 1) / n
	local sin_theta = math.sqrt(math.max(0, 1 - cos_theta * cos_theta))
	local x, y, z = math.cos(phi) * sin_theta, math.sin(phi) * sin_theta, cos_theta
	local qx, qy, qz, qw = rotation.x, rotation.y, rotation.z, rotation.w
	-- v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v)
	local cx = qy * z - qz * y + qw * x
	local cy = qz * x - qx * z + qw * y
	local cz = qx * y - qy * x + qw * z
	return x + 2 * (qy * cz - qz * cy),
	y + 2 * (qz * cx - qx * cz),
	z + 2 * (qx * cy - qy * cx)
end

function ddgi.GetDefinesGLSL()
	return (
		[[
		#define DDGI_P %d
		#define DDGI_CASCADES %d
		#define DDGI_RAYS %d
		#define DDGI_EMITTER_SAMPLES %d
		#define DDGI_EMITTER_CANDIDATES %d
		// ddgi_emitter.triangle: the soup index, and the material's double sidedness
		#define DDGI_EMITTER_DOUBLE_SIDED 0x80000000u
		// a probe's uniform rays followed by its emitter samples
		#define DDGI_RAY_STRIDE (DDGI_RAYS + DDGI_EMITTER_SAMPLES)
		#define DDGI_IRRADIANCE_TEXELS %d
		#define DDGI_DISTANCE_TEXELS %d
		#define DDGI_MISS_DISTANCE %.1e
		#define DDGI_SUN_VISIBLE_BIT 0x80000000u
		#define DDGI_SHADOW_OFFSET 0.02
		#define DDGI_MAX_LIGHTS %d
		#define DDGI_BACKFACE_SCALE 0.2
		// GLSL leaves %% undefined for negative operands (NVIDIA treats them
		// as unsigned), so shift into the positive range before wrapping
		#define DDGI_WRAP(v, n) (((v) + (n) * 65536) %% (n))
	]]
	):format(
		ddgi.PROBES_PER_AXIS,
		ddgi.CASCADES,
		ddgi.RAYS_PER_PROBE,
		ddgi.EMITTER_SAMPLES,
		ddgi.EMITTER_CANDIDATES,
		ddgi.IRRADIANCE_TEXELS,
		ddgi.DISTANCE_TEXELS,
		ddgi.MISS_DISTANCE,
		scene_lights.MAX_LIGHTS
	)
end

function ddgi.GetRayDirectionGLSL()
	return [[
		vec3 ddgi_ray_direction(uint index, vec4 q) {
			const float golden = 0.61803398875;
			float phi = 6.28318530718 * fract(float(index) * golden);
			float cos_theta = 1.0 - (2.0 * float(index) + 1.0) / float(DDGI_RAYS);
			float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
			vec3 v = vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
			return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
		}
	]]
end

-- total probe weight below which a lookup is darkened rather than normalized
local MIN_WEIGHT = "0.05"

-- Probe addressing. A probe is named by its cascade c and integer world
-- coordinate w (it sits at w * the cascade's spacing) and stored in slot
-- w mod the cascade's probe count on each axis, so when a cascade scrolls the
-- probes that stay keep their slot and history; only the planes that wrapped
-- around land on a slot whose stored coordinate no longer matches. A slot's
-- linear index picks its tile; each cascade has P rows of P * P tiles in the
-- atlases, finest on top, and uses as many as its probe count needs.
function ddgi.GetEmitterDeclarationsGLSL(binding)
	return (
		[[
		struct ddgi_emitter {
			uint triangle;
			// running sum of the emitters' power up to and including this one,
			// normalized to 1
			float cdf;
		};

		layout(set = 0, binding = %d) readonly buffer DDGIEmitters {
			ddgi_emitter ddgi_emitters[];
		};
	]]
	):format(binding)
end

-- Picking and placing an emitter sample, shared by the ray generation shader
-- (which traces it) and the shade pass (which lights with it); both derive the
-- same random numbers from the sample's ray index and the frame. Needs
-- ddgi_emitters and scene_bvh_triangles.
function ddgi.GetEmitterGLSL()
	return [[
		// pcg4d (Jarzynski and Olano 2020)
		vec4 ddgi_emitter_random(uint index, uint frame, uint candidate) {
			uvec4 v = uvec4(index, frame, candidate, 0x9E3779B9u) * 1664525u + 1013904223u;
			v.x += v.y * v.w;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v.w += v.y * v.z;
			v ^= v >> 16u;
			v.x += v.y * v.w;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v.w += v.y * v.z;
			return vec4(v >> 8u) / 16777216.0;
		}

		int ddgi_pick_emitter(float u, int count) {
			int lo = 0;
			int hi = count - 1;

			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (ddgi_emitters[mid].cdf < u) {
					lo = mid + 1;
				} else {
					hi = mid;
				}
			}

			return lo;
		}

		vec3 ddgi_emitter_point(scene_bvh_triangle tri, vec2 u) {
			if (u.x + u.y > 1.0) u = 1.0 - u;

			return tri.v0 + tri.e1 * u.x + tri.e2 * u.y;
		}
	]]
end

function ddgi.GetCommonGLSL()
	return ddgi.GetDefinesGLSL() .. ddgi.GetRayDirectionGLSL() .. [[
		ivec3 ddgi_volume_base(int c) {
			return ivec3(ddgi_data.ddgi_cascades[c].xyz);
		}

		float ddgi_spacing(int c) {
			return ddgi_data.ddgi_cascades[c].w;
		}

		// probes along each axis
		ivec3 ddgi_volume_size(int c) {
			return ivec3(ddgi_data.ddgi_cascade_size[c].xyz);
		}

		int ddgi_probe_count(int c) {
			ivec3 n = ddgi_volume_size(c);
			return n.x * n.y * n.z;
		}

		ivec3 ddgi_slot(ivec3 world, int c) {
			return DDGI_WRAP(world, ddgi_volume_size(c));
		}

		// index of a slot within its cascade
		int ddgi_probe_index(ivec3 slot, int c) {
			ivec3 n = ddgi_volume_size(c);
			return slot.x + n.x * (slot.y + n.y * slot.z);
		}

		ivec3 ddgi_slot_from_index(int index, int c) {
			ivec3 n = ddgi_volume_size(c);
			return ivec3(index % n.x, (index / n.x) % n.y, index / (n.x * n.y));
		}

		// a ray's texel in the shade pass output: one column block per cascade
		ivec2 ddgi_ray_texel(uint ray, ivec3 slot, int c) {
			return ivec2(int(ray) + DDGI_RAY_STRIDE * c, ddgi_probe_index(slot, c));
		}

		// the probe of this frame's volume that is stored in slot
		ivec3 ddgi_world_from_slot(ivec3 slot, int c) {
			ivec3 base = ddgi_volume_base(c);
			return base + DDGI_WRAP(slot - ddgi_slot(base, c), ddgi_volume_size(c));
		}

		ivec2 ddgi_tile_from_index(int index, int c) {
			return ivec2(index % (DDGI_P * DDGI_P), index / (DDGI_P * DDGI_P) + DDGI_P * c);
		}

		ivec2 ddgi_tile(ivec3 slot, int c) {
			return ddgi_tile_from_index(ddgi_probe_index(slot, c), c);
		}

		// inside the outermost cascade in use
		bool ddgi_in_volume(vec3 P) {
			int c = ddgi_data.ddgi_cascade_count - 1;
			vec3 grid = P / ddgi_spacing(c) - vec3(ddgi_volume_base(c));
			return all(greaterThanEqual(grid, vec3(0.0))) && all(lessThanEqual(grid, vec3(ddgi_volume_size(c) - 1)));
		}

		vec3 ddgi_ray(uint index) {
			return ddgi_ray_direction(index, ddgi_data.ddgi_rotation);
		}

		vec2 ddgi_oct_encode(vec3 n) {
			n /= abs(n.x) + abs(n.y) + abs(n.z);
			vec2 p = n.xy;

			if (n.z < 0.0) p = (1.0 - abs(p.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);

			return p;
		}

		vec3 ddgi_oct_decode(vec2 p) {
			vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));

			if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);

			return normalize(n);
		}

		// 12 bits per octahedral axis, small enough to sit exactly in a float
		float ddgi_pack_direction(vec3 d) {
			uvec2 q = uvec2((ddgi_oct_encode(d) * 0.5 + 0.5) * 4095.0 + 0.5);
			return float(q.x | (q.y << 12u));
		}

		vec3 ddgi_unpack_direction(float packed) {
			uint v = uint(packed);
			return ddgi_oct_decode(vec2(v & 4095u, v >> 12u) / 4095.0 * 2.0 - 1.0);
		}

		// direction of texel (x, y) in a bordered octahedral tile; border texels
		// mirror the interior texel they duplicate so bilinear filtering across
		// an octahedron edge reads the right neighbour
		vec3 ddgi_texel_direction(ivec2 texel, int texels) {
			int last = texels - 1;
			ivec2 src = texel;

			if (texel.y == 0 || texel.y == last) {
				src.x = last - texel.x;
				src.y = texel.y == 0 ? 1 : last - 1;
			}

			if (texel.x == 0 || texel.x == last) {
				src.y = last - src.y;
				src.x = texel.x == 0 ? 1 : last - 1;
			}

			vec2 uv = (vec2(src - 1) + 0.5) / float(texels - 2);
			return ddgi_oct_decode(uv * 2.0 - 1.0);
		}

		vec2 ddgi_atlas_uv(ivec3 slot, int c, vec3 dir, int texels) {
			vec2 atlas_size = vec2(DDGI_P * DDGI_P * texels, DDGI_P * DDGI_CASCADES * texels);
			vec2 oct = ddgi_oct_encode(dir) * 0.5 + 0.5;
			vec2 pixel = vec2(ddgi_tile(slot, c) * texels) + 1.0 + oct * float(texels - 2);
			return pixel / atlas_size;
		}

		// xyz = world coordinate last written into the slot plus the probe's
		// relocation offset in spacings (under 0.5, so rounding recovers the
		// coordinate), w = 1 + back face ray fraction (0 when never written)
		vec4 ddgi_probe_data(ivec3 slot, int c) {
			return texelFetch(TEXTURE(ddgi_data.ddgi_probe_data_tex), ddgi_tile(slot, c), 0);
		}

		bool ddgi_probe_is_current(vec4 data, ivec3 world) {
			return data.w >= 1.0 && ivec3(round(data.xyz)) == world;
		}

		// where the probe's rays start; one that just scrolled into its slot
		// sits on its grid point
		vec3 ddgi_probe_origin(ivec3 slot, int c, ivec3 world) {
			vec4 data = ddgi_probe_data(slot, c);
			return (ddgi_probe_is_current(data, world) ? data.xyz : vec3(world)) * ddgi_spacing(c);
		}

		vec3 ddgi_sky(vec3 dir) {
			return textureLod(
				TEXTURE(ddgi_data.ddgi_env_tex),
				dir_to_equirect_uv(correct_environment_lookup_dir(dir)),
				1.0
			).rgb * ddgi_data.ddgi_sky_intensity;
		}

		bool ddgi_cascade_reset(int c) {
			return (ddgi_data.ddgi_reset_mask & (1 << c)) != 0;
		}

		vec4 ddgi_sample_cascade(int c, vec3 P, vec3 N, vec3 V, bool smooth_blend, out float weight) {
			weight = 0.0;

			if (ddgi_cascade_reset(c)) return vec4(0.0);

			float spacing = ddgi_spacing(c);
			vec3 biased = P + (N * ddgi_data.ddgi_normal_bias + V * ddgi_data.ddgi_view_bias) * spacing;
			vec3 grid = biased / spacing;
			int side = smooth_blend ? 3 : 2;
			// the B-spline's lowest probe is one below the nearest
			ivec3 base_world = smooth_blend ? ivec3(floor(grid + 0.5)) - 1 : ivec3(floor(grid));
			vec3 alpha = grid - vec3(base_world) - (smooth_blend ? 1.0 : 0.0);
			vec3 below = 0.5 * (0.5 - alpha) * (0.5 - alpha);
			vec3 middle = 0.75 - alpha * alpha;
			vec3 above = 0.5 * (0.5 + alpha) * (0.5 + alpha);
			ivec3 volume_min = ddgi_volume_base(c);
			ivec3 volume_max = volume_min + ddgi_volume_size(c) - 1;
			vec4 sum = vec4(0.0);

			for (int i = 0; i < side * side * side; i++) {
				ivec3 offset = ivec3(i % side, (i / side) % side, i / (side * side));
				ivec3 world = base_world + offset;

				if (any(lessThan(world, volume_min)) || any(greaterThan(world, volume_max))) continue;

				ivec3 slot = ddgi_slot(world, c);
				vec4 data = ddgi_probe_data(slot, c);

				if (!ddgi_probe_is_current(data, world) || data.w - 1.0 > ddgi_data.ddgi_backface_threshold) continue;

				vec3 probe_pos = data.xyz * spacing;
				vec3 kernel = smooth_blend ? mix(mix(below, middle, equal(offset, ivec3(1))), above, equal(offset, ivec3(2))) : mix(1.0 - alpha, alpha, vec3(offset));
				vec3 to_probe = normalize(probe_pos - P);
				float w = (dot(to_probe, N) + 1.0) * 0.5;
				w = w * w + 0.2;

				vec3 probe_to_point = biased - probe_pos;
				float dist = length(probe_to_point);
				vec2 moments = texture(
					TEXTURE(ddgi_data.ddgi_distance_tex),
					ddgi_atlas_uv(slot, c, probe_to_point / max(dist, 1e-4), DDGI_DISTANCE_TEXELS)
				).rg;
				float chebyshev = 1.0;

				if (dist > moments.x) {
					float variance = abs(moments.x * moments.x - moments.y);
					float d = dist - moments.x;
					chebyshev = variance / (variance + d * d);
					chebyshev = chebyshev * chebyshev * chebyshev;
				}

				w *= max(0.05, chebyshev);
				w = max(1e-6, w);

				// crush tiny weights so a barely visible probe cannot tint the result
				if (w < 0.2) w *= w * w / 0.04;

				w *= kernel.x * kernel.y * kernel.z;
				sum += texture(
					TEXTURE(ddgi_data.ddgi_irradiance_tex),
					ddgi_atlas_uv(slot, c, N, DDGI_IRRADIANCE_TEXELS)
				) * w;
				weight += w;
			}

			// When every probe is all but hidden (a point inside geometry, or
			// on an edge where the reconstructed position slips behind a wall)
			// dividing by the tiny total would blow up whichever hidden probe
			// is least hidden, often one outside. Such points fade out instead.
			return sum / max(weight, ]] .. MIN_WEIGHT .. [[);
		}

		// 1 deep inside cascade c, falling to 0 a cell (the B-spline reaches
		// half a cell further) before its edge where the biased lookup would
		// start missing probes. An edge past the end of
		// the scene has nothing beyond it, so it does not fade.
		float ddgi_cascade_blend(int c, vec3 P, bool smooth_blend) {
			vec3 grid = P / ddgi_spacing(c) - vec3(ddgi_volume_base(c));
			vec3 edge = min(grid, vec3(ddgi_volume_size(c) - 1) - grid);
			int holds = int(ddgi_data.ddgi_cascade_size[c].w);

			if ((holds & 1) != 0) edge.x = 1e9;

			if ((holds & 2) != 0) edge.y = 1e9;

			if ((holds & 4) != 0) edge.z = 1e9;

			return clamp((min(edge.x, min(edge.y, edge.z)) - (smooth_blend ? 1.5 : 1.0)) / ddgi_data.ddgi_cascade_blend, 0.0, 1.0);
		}

		// Irradiance at P with normal N, seen from direction V (towards the
		// viewer). rgb = irradiance, a = sky visibility. weight is 0 when no
		// probe could contribute.
		vec4 ddgi_sample_irradiance(vec3 P, vec3 N, vec3 V, bool smooth_blend, out float weight) {
			weight = 0.0;

			int count = ddgi_data.ddgi_cascade_count;

			for (int c = 0; c < count; c++) {
				float fine = c == count - 1 ? 1.0 : ddgi_cascade_blend(c, P, smooth_blend);

				if (fine <= 0.0) continue;

				vec4 result = ddgi_sample_cascade(c, P, N, V, smooth_blend, weight);

				if (fine >= 1.0) return result;

				float coarse_weight;
				vec4 coarse = ddgi_sample_cascade(c + 1, P, N, V, smooth_blend, coarse_weight);

				// fitted cascades are not always nested
				if (coarse_weight <= 0.0) return result;

				weight = mix(coarse_weight, weight, fine);
				return mix(coarse, result, fine);
			}

			return vec4(0.0);
		}
	]]
end

function ddgi.GetBlockLayout()
	return {
		render3d.camera_block,
		render3d.gbuffer_block,
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
		-- xyz = volume base (the lowest probe's world coordinate), w = spacing
		{"ddgi_cascades", "vec4", ddgi.CASCADES},
		-- xyz = probes along each axis, w = bits of the axes (1 x, 2 y, 4 z)
		-- along which the cascade holds the whole scene
		{"ddgi_cascade_size", "vec4", ddgi.CASCADES},
		{"ddgi_rotation", "vec4"},
		{"ddgi_sun_direction", "vec4"},
		{"ddgi_sun_radiance", "vec4"},
		{"ddgi_max_distance", "float"},
		{"ddgi_hysteresis", "float"},
		{"ddgi_min_hysteresis", "float"},
		{"ddgi_noise_range", "float"},
		{"ddgi_irradiance_threshold", "float"},
		{"ddgi_adapt_frames", "float"},
		{"ddgi_distance_exponent", "float"},
		{"ddgi_normal_bias", "float"},
		{"ddgi_view_bias", "float"},
		{"ddgi_backface_threshold", "float"},
		{"ddgi_relocation_distance", "float"},
		{"ddgi_max_offset", "float"},
		{"ddgi_sky_intensity", "float"},
		{"ddgi_light_radius", "float"},
		{"ddgi_cascade_blend", "float"},
		{"ddgi_debug_scale", "float"},
		{"ddgi_debug_probes", "int"},
		{"ddgi_debug_cascade", "int"},
		{"ddgi_smooth_blend", "int"},
		{"ddgi_cascade_count", "int"},
		-- bit c: cascade c's history is garbage
		{"ddgi_reset_mask", "int"},
		{"ddgi_rt_ready", "int"},
		{"ddgi_env_tex", "int"},
		{"ddgi_env_irradiance_tex", "int"},
		{"ddgi_ray_tex", "int"},
		{"ddgi_irradiance_tex", "int"},
		{"ddgi_distance_tex", "int"},
		{"ddgi_probe_data_tex", "int"},
		{"ddgi_emitter_count", "int"},
		-- the summed power of all emitters
		{"ddgi_emitter_weight", "float"},
		{"ddgi_frame", "int"},
	}
end

local function pipeline_texture_index(self, name)
	local pipeline = render3d.pipelines[name]
	return pipeline and
		self:GetTextureIndex(pipeline:GetFramebuffer(1):GetAttachment(1)) or
		-1
end

function ddgi.WriteBlock(self, block)
	local state = ddgi.GetFrameState()
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	-- every light, not just those in view: probes see what the camera doesn't,
	-- and the shadow rays make that safe
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	local sun_color = directional_shadows.GetPrimarySunColor(lights)
	-- A sun below the horizon would light the scene from underneath: the
	-- underside of the ground, and so the probes below it, at full daylight.
	-- Faded like the sky and fog do.
	local sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, sun_direction.y)
	sun_direction:CopyToFloatPointer(block.ddgi_sun_direction)
	block.ddgi_sun_direction[3] = 0
	block.ddgi_sun_radiance[0] = sun_color.x * sun_illuminance
	block.ddgi_sun_radiance[1] = sun_color.y * sun_illuminance
	block.ddgi_sun_radiance[2] = sun_color.z * sun_illuminance
	block.ddgi_sun_radiance[3] = 0

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		block.ddgi_cascades[c - 1][0] = cascade.x
		block.ddgi_cascades[c - 1][1] = cascade.y
		block.ddgi_cascades[c - 1][2] = cascade.z
		block.ddgi_cascades[c - 1][3] = cascade.spacing
		block.ddgi_cascade_size[c - 1][0] = cascade.size.x
		block.ddgi_cascade_size[c - 1][1] = cascade.size.y
		block.ddgi_cascade_size[c - 1][2] = cascade.size.z
		block.ddgi_cascade_size[c - 1][3] = cascade.holds
	end

	block.ddgi_rotation[0] = state.rotation.x
	block.ddgi_rotation[1] = state.rotation.y
	block.ddgi_rotation[2] = state.rotation.z
	block.ddgi_rotation[3] = state.rotation.w
	block.ddgi_max_distance = ddgi.MAX_RAY_DISTANCE
	-- a hitch shouldn't throw the history away
	local frames = math.min(system.GetFrameTime(), 0.1) * 60
	block.ddgi_hysteresis = ddgi.HYSTERESIS ^ frames
	block.ddgi_min_hysteresis = ddgi.MIN_HYSTERESIS ^ frames
	block.ddgi_noise_range = ddgi.NOISE_RANGE
	block.ddgi_irradiance_threshold = ddgi.IRRADIANCE_THRESHOLD
	block.ddgi_adapt_frames = ddgi.ADAPT_FRAMES
	block.ddgi_distance_exponent = ddgi.DISTANCE_EXPONENT
	block.ddgi_normal_bias = ddgi.NORMAL_BIAS
	block.ddgi_view_bias = ddgi.VIEW_BIAS
	block.ddgi_backface_threshold = ddgi.BACKFACE_THRESHOLD
	-- in spacings, like the biases and the light radius
	block.ddgi_relocation_distance = ddgi.RELOCATION and ddgi.RELOCATION_DISTANCE or 0
	block.ddgi_max_offset = ddgi.RELOCATION and ddgi.PROBE_MAX_OFFSET or 0
	block.ddgi_sky_intensity = ddgi.SKY_INTENSITY
	block.ddgi_light_radius = ddgi.LIGHT_RADIUS
	block.ddgi_cascade_blend = ddgi.CASCADE_BLEND
	block.ddgi_debug_scale = ddgi.DEBUG_SCALE
	block.ddgi_debug_probes = ddgi.DEBUG_PROBES
	block.ddgi_debug_cascade = ddgi.DEBUG_CASCADE
	block.ddgi_smooth_blend = ddgi.SMOOTH_BLEND and 1 or 0
	block.ddgi_cascade_count = state.cascade_count
	block.ddgi_reset_mask = state.reset_mask
	block.ddgi_rt_ready = state.rt_ready and 1 or 0
	block.ddgi_env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.ddgi_env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	block.ddgi_ray_tex = pipeline_texture_index(self, "ddgi_shade")
	block.ddgi_irradiance_tex = pipeline_texture_index(self, "ddgi_irradiance")
	block.ddgi_distance_tex = pipeline_texture_index(self, "ddgi_distance")
	block.ddgi_probe_data_tex = pipeline_texture_index(self, "ddgi_probe_data")
	local emitters = ddgi.GetEmitters()
	block.ddgi_emitter_count = emitters.count
	block.ddgi_emitter_weight = emitters.weight
	block.ddgi_frame = state.frame
	return block
end

-- One (hit distance, primitive id) pair per ray, written by the ray
-- generation shader. A miss stores a negative distance.
local ray_hit_buffer = nil

function ddgi.GetRayHitBuffer()
	if not ray_hit_buffer then
		ray_hit_buffer = render.CreateBuffer{
			byte_size = ddgi.GetRayCount() * 8,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "device_local"},
			label = "ddgi_ray_hits",
		}
	end

	return ray_hit_buffer
end

-- One uint per ray: bit i % 32 is cleared when light i reaches the hit but a
-- shadow ray towards it is blocked. Lights sharing a bit darken each other
-- only when both reach the same hit, which needs more than 32 lights.
local light_mask_buffer = nil

function ddgi.GetLightMaskBuffer()
	if not light_mask_buffer then
		light_mask_buffer = render.CreateBuffer{
			byte_size = ddgi.GetRayCount() * 4,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "ddgi_light_masks",
		}
	end

	return light_mask_buffer
end

-- Every emissive triangle of the scene soup, with the running sum of its
-- power (area x emission luminance) for picking one in proportion to it.
-- weight is the total power. Rescanned whenever the soup changes.
do
	local Emitter = ffi.typeof([[struct {
		uint32_t triangle;
		float cdf;
	}]])
	local EmitterArray = ffi.typeof("$[?]", Emitter)
	local emitters = {array = EmitterArray(1), capacity = 1, count = 0, weight = 0, version = -1}
	local buffers = {}
	local buffer_versions = {}

	function ddgi.GetEmitters()
		if emitters.version == scene_bvh.version then return emitters end

		local tris = scene_bvh.triangles
		local count, weight = 0, 0

		for _, block in ipairs(scene_bvh.emissive_blocks) do
			for i = block.tri_base, block.tri_base + block.total - 1 do
				local tri = tris[i]
				local luminance = 0.2126 * tri.emissive[0] + 0.7152 * tri.emissive[1] + 0.0722 * tri.emissive[2]

				if luminance > 0 then
					local e1, e2 = tri.e1, tri.e2
					local nx = e1[1] * e2[2] - e1[2] * e2[1]
					local ny = e1[2] * e2[0] - e1[0] * e2[2]
					local nz = e1[0] * e2[1] - e1[1] * e2[0]
					weight = weight + 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz) * luminance

					if count == emitters.capacity then
						local array = EmitterArray(count * 2)
						ffi.copy(array, emitters.array, count * ffi.sizeof(Emitter))
						emitters.array = array
						emitters.capacity = count * 2
					end

					emitters.array[count].triangle = scene_bvh.materials[tri.material + 1]:GetDoubleSided() and
						i + 0x80000000 or
						i
					emitters.array[count].cdf = weight
					count = count + 1
				end
			end
		end

		for i = 0, count - 1 do
			emitters.array[i].cdf = emitters.array[i].cdf / weight
		end

		emitters.count = count
		emitters.weight = weight
		emitters.version = scene_bvh.version
		return emitters
	end

	-- one host-visible copy per frame in flight
	function ddgi.GetEmitterBuffer()
		local emitters = ddgi.GetEmitters()
		local frame = render.GetCurrentFrame()
		local buffer = buffers[frame]
		local bytes = math.max(emitters.count, 1) * ffi.sizeof(Emitter)

		if not buffer or buffer:GetSize() < bytes then
			if buffer then buffer:Remove() end

			buffer = render.CreateBuffer{
				byte_size = bytes * 2,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_emitters",
				data = EmitterArray(math.max(emitters.count, 1) * 2),
			}
			buffers[frame] = buffer
			buffer_versions[frame] = nil
		end

		if buffer_versions[frame] ~= emitters.version then
			buffer:CopyData(emitters.array, bytes)
			buffer_versions[frame] = emitters.version
		end

		return buffer
	end
end

-- The per-material data the shade pass reads through the soup's material id,
-- one host-visible copy per frame in flight.
local Material = ffi.typeof([[struct {
	float albedo[3];
	int32_t albedo_tex;
	int32_t double_sided;
}]])
local MaterialArray = ffi.typeof("$[?]", Material)
local MaterialPointer = ffi.typeof("$*", Material)
local MATERIAL_SIZE = 20
local material_buffers = {}

function ddgi.WriteMaterialBuffer(self)
	local frame = render.GetCurrentFrame()
	local count = math.max(#scene_bvh.materials, 1)
	local buffer = material_buffers[frame]

	if not buffer or buffer:GetSize() < count * MATERIAL_SIZE then
		if buffer then buffer:Remove() end

		buffer = render.CreateBuffer{
			byte_size = count * 2 * MATERIAL_SIZE,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "ddgi_materials",
			data = MaterialArray(count * 2),
		}
		material_buffers[frame] = buffer
	end

	local out = ffi.cast(MaterialPointer, buffer:Map(0, buffer:GetSize()))

	for i, material in ipairs(scene_bvh.materials) do
		local entry = out[i - 1]
		local color = material:GetColorMultiplier()
		local albedo = material:GetAlbedoTexture()
		entry.albedo[0] = color.r
		entry.albedo[1] = color.g
		entry.albedo[2] = color.b
		entry.albedo_tex = albedo and self:GetTextureIndex(albedo) or -1
		entry.double_sided = material:GetDoubleSided() and 1 or 0
	end

	return buffer
end

-- Ray generation parameters, one host-visible copy per frame in flight since
-- the previous frame may still be tracing while this one is written.
local RTParams = ffi.typeof(
	(
		[[struct {
	float cascades[%d][4];
	float size[%d][4];
	float rotation[4];
	float sun_direction[4];
	float max_ray_distance;
	float tmin;
	int32_t light_count;
	int32_t emitter_count;
	uint32_t frame;
	float light_radius;
	float padding[2];
	float lights[%d][4];
	float light_directions[%d][4];
}]]
	):format(ddgi.CASCADES, ddgi.CASCADES, scene_lights.MAX_LIGHTS, scene_lights.MAX_LIGHTS)
)
local RTParamsPointer = ffi.typeof("$*", RTParams)
local rt_params = {}

function ddgi.WriteRTParams()
	local frame = render.GetCurrentFrame()
	local buffer = rt_params[frame]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = ffi.sizeof(RTParams),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "ddgi_rt_params",
			data = RTParams(),
		}
		rt_params[frame] = buffer
	end

	local state = ddgi.GetFrameState()
	local p = ffi.cast(RTParamsPointer, buffer:Map(0, ffi.sizeof(RTParams)))

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		p.cascades[c - 1][0] = cascade.x
		p.cascades[c - 1][1] = cascade.y
		p.cascades[c - 1][2] = cascade.z
		p.cascades[c - 1][3] = cascade.spacing
		p.size[c - 1][0] = cascade.size.x
		p.size[c - 1][1] = cascade.size.y
		p.size[c - 1][2] = cascade.size.z
	end

	p.rotation[0] = state.rotation.x
	p.rotation[1] = state.rotation.y
	p.rotation[2] = state.rotation.z
	p.rotation[3] = state.rotation.w
	local lights = render3d.GetLights()
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	p.sun_direction[0] = sun_direction.x
	p.sun_direction[1] = sun_direction.y
	p.sun_direction[2] = sun_direction.z
	p.sun_direction[3] = directional_shadows.GetPrimarySunIlluminance(lights) > 0 and 1 or 0
	p.max_ray_distance = ddgi.MAX_RAY_DISTANCE
	p.tmin = 0.0
	p.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	p.emitter_count = ddgi.GetEmitters().count
	p.frame = state.frame
	p.light_radius = ddgi.LIGHT_RADIUS

	-- the same lights in the same order as ddgi_data.lights
	for i = 1, p.light_count do
		local light = lights[i]
		light.Owner.transform:GetPosition():CopyToFloatPointer(p.lights[i - 1])
		p.lights[i - 1][3] = light.Type == "light_sun" and 0 or light:GetEffectiveRange()

		if light.Type == "light_directional" then
			light.Owner.transform:GetRotation():GetBackward():CopyToFloatPointer(p.light_directions[i - 1])
			p.light_directions[i - 1][3] = 1
		else
			p.light_directions[i - 1][3] = 0
		end
	end

	return buffer
end

local payload_glsl = [[
struct Payload
{
    float hit_t;
    uint primitive;
};
]]
local raygen_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
]] .. ddgi.GetDefinesGLSL() .. ddgi.GetRayDirectionGLSL() .. payload_glsl .. scene_bvh.GetDeclarationsGLSL(7, 5) .. ddgi.GetEmitterDeclarationsGLSL(6) .. ddgi.GetEmitterGLSL() .. [[
layout(set = 0, binding = 0) uniform Params
{
    // see ddgi_cascades and ddgi_cascade_size
    vec4 cascades[DDGI_CASCADES];
    vec4 size[DDGI_CASCADES];
    vec4 rotation;
    vec4 sun_direction;
    float max_ray_distance;
    float tmin;
    int light_count;
    int emitter_count;
    uint frame;
    // in spacings, see ddgi.LIGHT_RADIUS
    float light_radius;
    // xyz = position, w = range (0 for the sun, which has its own ray)
    vec4 lights[DDGI_MAX_LIGHTS];
    // xyz = direction back towards a local directional light's source, w = 1
    // for those; their light travels in parallel rather than from a point
    vec4 light_directions[DDGI_MAX_LIGHTS];
} params;
layout(set = 0, binding = 1) writeonly buffer Hits
{
    uvec2 hits[];
};
layout(set = 0, binding = 4) writeonly buffer LightMasks
{
    uint light_masks[];
};
layout(set = 0, binding = 2) uniform accelerationStructureEXT scene;
// see ddgi_probe_data
layout(set = 0, binding = 3) uniform sampler2D probe_data;
layout(location = 0) rayPayloadEXT Payload payload;

void main()
{
    uint ray = gl_LaunchIDEXT.x;
    int probe = int(gl_LaunchIDEXT.y);
    int c = int(gl_LaunchIDEXT.z);
    ivec3 n = ivec3(params.size[c].xyz);

    if (probe >= n.x * n.y * n.z) return;

    ivec3 base = ivec3(params.cascades[c].xyz);
    ivec3 slot = ivec3(probe % n.x, (probe / n.x) % n.y, probe / (n.x * n.y));
    ivec3 world = base + DDGI_WRAP(slot - DDGI_WRAP(base, n), n);
    vec4 data = texelFetch(probe_data, ivec2(probe % (DDGI_P * DDGI_P), probe / (DDGI_P * DDGI_P) + DDGI_P * c), 0);
    bool current = data.w >= 1.0 && ivec3(round(data.xyz)) == world;
    vec3 origin = (current ? data.xyz : vec3(world)) * params.cascades[c].w;
    uint index = uint(probe + DDGI_P * DDGI_P * DDGI_P * c) * uint(DDGI_RAY_STRIDE) + ray;
    const uint shadow_flags = gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT;

    // An emitter sample. Candidates are drawn in proportion to their
    // triangle's power, and one is kept with a probability proportional to
    // the light it would bring unshadowed (facing / distance^2, inside the
    // light radius flattened like the local lights), relative to the power
    // it was drawn by, which leaves just that. Only the kept one is traced.
    // Stores the candidates' summed weight and which one was kept (the shade
    // pass rebuilds its point from the same random numbers), or a negative
    // weight when it is blocked.
    if (ray >= DDGI_RAYS) {
        uvec2 result = uvec2(floatBitsToUint(-1.0), 0u);

        if (params.emitter_count > 0) {
            float radius = params.light_radius * params.cascades[c].w;
            float weight_sum = 0.0;
            uint kept = 0u;
            int kept_emitter = 0;
            vec3 kept_point = vec3(0.0);

            for (uint j = 0u; j < uint(DDGI_EMITTER_CANDIDATES); j++) {
                vec4 u = ddgi_emitter_random(index, params.frame, j);
                int e = ddgi_pick_emitter(u.x, params.emitter_count);
                uint triangle = ddgi_emitters[e].triangle;
                scene_bvh_triangle tri = scene_bvh_triangles[triangle & ~DDGI_EMITTER_DOUBLE_SIDED];
                vec3 point = ddgi_emitter_point(tri, u.yz);
                vec3 to_point = point - origin;
                float dist2 = dot(to_point, to_point);
                // tri.normal points away from the visible side
                float facing = dot(tri.normal, to_point) * inversesqrt(dist2);

                if ((triangle & DDGI_EMITTER_DOUBLE_SIDED) != 0u) facing = abs(facing);

                float weight = max(facing, 0.0) / max(dist2, radius * radius);
                weight_sum += weight;

                if (weight > 0.0 && u.w * weight_sum < weight) {
                    kept = j;
                    kept_emitter = e;
                    kept_point = point;
                }
            }

            vec3 to_point = kept_point - origin;
            float dist = length(to_point);

            if (weight_sum > 0.0 && dist > DDGI_SHADOW_OFFSET) {
                payload.hit_t = 1.0;
                traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, origin, 0.0, to_point / dist, dist - DDGI_SHADOW_OFFSET, 0);

                if (payload.hit_t < 0.0) result = uvec2(floatBitsToUint(weight_sum), uint(kept_emitter) | (kept << 28u));
            }
        }

        hits[index] = result;
        return;
    }

    vec3 dir = ddgi_ray_direction(ray, params.rotation);
    traceRayEXT(scene, gl_RayFlagsOpaqueEXT, 0xFF, 0, 0, 0, origin, params.tmin, dir, params.max_ray_distance, 0);
    float hit_t = payload.hit_t;
    uint primitive = payload.primitive;
    uint light_mask = 0xFFFFFFFFu;

    // Light visibility from the hit, exact rather than from shadow maps that
    // only cover the view (or don't exist for a light) and let light into
    // sealed rooms. The shadow rays skip the closest hit shader, so only a
    // miss changes the payload.
    if (hit_t >= 0.0) {
        vec3 hit_pos = origin + dir * max(hit_t - DDGI_SHADOW_OFFSET, 0.0);

        if (params.sun_direction.w > 0.0) {
            payload.hit_t = 1.0;
            traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, hit_pos, 0.0, normalize(params.sun_direction.xyz), params.max_ray_distance, 0);

            if (payload.hit_t < 0.0) primitive |= DDGI_SUN_VISIBLE_BIT;
        }

        for (int i = 0; i < params.light_count; i++) {
            vec3 to_light = params.lights[i].xyz - hit_pos;
            float dist = length(to_light);

            if (dist >= params.lights[i].w || dist <= DDGI_SHADOW_OFFSET) continue;

            vec3 L = to_light / dist;

            if (params.light_directions[i].w > 0.0) {
                L = params.light_directions[i].xyz;
                dist = dot(to_light, L);

                if (dist <= DDGI_SHADOW_OFFSET) continue;
            }

            payload.hit_t = 1.0;
            // stops short of the light so a bulb mesh around it doesn't shadow it
            traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, hit_pos, 0.0, L, dist - DDGI_SHADOW_OFFSET, 0);

            if (payload.hit_t >= 0.0) light_mask &= ~(1u << uint(i & 31));
        }
    }

    hits[index] = uvec2(floatBitsToUint(hit_t), primitive);
    light_masks[index] = light_mask;
}
]]
local closesthit_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;

void main()
{
    payload.hit_t = gl_HitTEXT;
    payload.primitive = uint(gl_PrimitiveID);
}
]]
local miss_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;

void main()
{
    payload.hit_t = -1.0;
    payload.primitive = 0u;
}
]]
local rt_pipeline = nil

function ddgi.GetRTPipeline()
	if not rt_pipeline then
		local RayTracingPipeline = import("goluwa/render/vulkan/ray_tracing_pipeline.lua")
		rt_pipeline = RayTracingPipeline.New(
			render.GetDevice(),
			{
				stages = {
					{name = "raygeneration", code = raygen_glsl},
					{name = "closesthit", code = closesthit_glsl},
					{name = "miss", code = miss_glsl},
				},
				max_recursion_depth = 1,
				max_ray_payload_size = 8,
				DescriptorSetCount = render.GetSwapchainImageCount() * 16,
				descriptor_sets = {
					{
						{binding_index = 0, type = "uniform_buffer", stageFlags = "all"},
						{binding_index = 1, type = "storage_buffer", stageFlags = "all"},
						{binding_index = 2, type = "acceleration_structure_khr", stageFlags = "all"},
						{binding_index = 3, type = "combined_image_sampler", stageFlags = "all"},
						{binding_index = 4, type = "storage_buffer", stageFlags = "all"},
						{binding_index = 5, type = "storage_buffer", stageFlags = "all"},
						{binding_index = 6, type = "storage_buffer", stageFlags = "all"},
						{binding_index = 7, type = "storage_buffer", stageFlags = "all"},
					},
				},
			}
		)
	end

	return rt_pipeline
end

commands.Add("ddgi_reset", function()
	ddgi.ResetHistory()
end)

commands.Add("ddgi_hysteresis=number[0.99]", function(value)
	ddgi.HYSTERESIS = value
end)

commands.Add("ddgi_min_hysteresis=number[0.95]", function(value)
	ddgi.MIN_HYSTERESIS = value
end)

commands.Add("ddgi_noise_range=number[0.25]", function(value)
	ddgi.NOISE_RANGE = value
end)

commands.Add("ddgi_irradiance_threshold=number[2]", function(value)
	ddgi.IRRADIANCE_THRESHOLD = value
end)

commands.Add("ddgi_adapt_frames=number[6]", function(value)
	ddgi.ADAPT_FRAMES = value
end)

commands.Add("ddgi_light_radius=number[0.1]", function(value)
	ddgi.LIGHT_RADIUS = value
end)

commands.Add("ddgi_debug_probes=number[1]", function(value)
	ddgi.DEBUG_PROBES = value
end)

commands.Add("ddgi_debug_scale=number[1]", function(value)
	ddgi.DEBUG_SCALE = value
end)

commands.Add("ddgi_smooth_blend=boolean[true]", function(value)
	ddgi.SMOOTH_BLEND = value
end)

commands.Add("ddgi_debug_cascade=number[0]", function(value)
	ddgi.DEBUG_CASCADE = value
end)

commands.Add("ddgi_info", function()
	local state = ddgi.GetFrameState()
	local region = state.region
	logf(
		"ddgi: %d of %d cascades in use, region %.1f..%.1f %.1f..%.1f %.1f..%.1f\n",
		state.cascade_count,
		ddgi.CASCADES,
		region.min_x,
		region.max_x,
		region.min_y,
		region.max_y,
		region.min_z,
		region.max_z
	)

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		logf(
			"  cascade %d%s: spacing %.2f, %d x %d x %d probes (%d), spans %.1f %.1f %.1f m from %.1f %.1f %.1f\n",
			c - 1,
			c > state.cascade_count and " (unused)" or "",
			cascade.spacing,
			cascade.size.x,
			cascade.size.y,
			cascade.size.z,
			cascade.size.x * cascade.size.y * cascade.size.z,
			cascade.spacing * (cascade.size.x - 1),
			cascade.spacing * (cascade.size.y - 1),
			cascade.spacing * (cascade.size.z - 1),
			cascade.x * cascade.spacing,
			cascade.y * cascade.spacing,
			cascade.z * cascade.spacing
		)
	end
end)

commands.Add("ddgi_probe_spacing=number[2]", function(value)
	ddgi.PROBE_SPACING = value
end)

commands.Add("ddgi_min_coverage=number[4]", function(value)
	ddgi.MIN_COVERAGE = value
end)

commands.Add("ddgi_max_coverage=number[192]", function(value)
	ddgi.MAX_COVERAGE = value
end)

commands.Add("ddgi_relocation=boolean[true]", function(value)
	ddgi.RELOCATION = value
end)

return ddgi
