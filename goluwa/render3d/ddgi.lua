local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local glass_tint = import("goluwa/render3d/glass_tint.lua")
local ddgi = library()
-- Dynamic diffuse global illumination (Majercik et al. 2019) over hardware ray
-- tracing. A camera-centred grid of probes each trace RAYS_PER_PROBE rays per
-- frame; the hits are shaded (direct light plus last frame's probe irradiance
-- for the infinite bounce) and blended into two octahedral atlases per probe:
-- irradiance, and the mean/mean^2 hit distance used for the Chebyshev
-- visibility test that keeps light from leaking through walls.
pvars.StartGroup("ddgi", {store = false})
-- Off, the probe passes are skipped (the trace pass still builds the TLAS
-- ssr and the fog trace against) and surfaces fall back to the environment's
-- irradiance, unoccluded. Back on, the probes start over.
local was_enabled = true
local enabled = pvars.Setup2{
	key = "ddgi_enabled",
	default = true,
	help = "off, the probe passes are skipped and surfaces fall back to the environment's irradiance",
	callback = function(value)
		if value and not was_enabled then ddgi.ResetHistory() end

		was_enabled = value
	end,
}
ddgi.PROBES_PER_AXIS = 24
local probe_spacing = pvars.Setup2{
	key = "ddgi_probe_spacing",
	default = 1.0,
	min = 0.1,
	help = "meters between the finest cascade's probes",
}
-- Nested volumes of the same P^3 probes, each twice the spacing of the one
-- inside it, so the probes reach far while the view stays on the fine ones.
-- A point is shaded by the finest cascade that holds it, fading into the next
-- over CASCADE_BLEND cells before that cascade's edge.
ddgi.CASCADES = 4
ddgi.CASCADE_BLEND = 2.0
-- How often each cascade traces its rays and blends them into its probes, in
-- frames: cascade i updates every UPDATE_INTERVALS[i]th frame, staggered so the
-- cascades' frames do not all coincide. The outer cascades' light changes
-- slowly, so they can update rarely and cost a fraction of the finest one. A
-- cascade updates early when its volume scrolled to a new cell or its history
-- was reset. Hysteresis is scaled by the time since the cascade's last update,
-- so light settles as fast in real time at any interval.
local update_intervals = {}

for c, frames in ipairs{1, 2, 4, 8} do
	update_intervals[c] = pvars.Setup2{
		key = "ddgi_update_interval_" .. c - 1,
		default = frames,
		integer = true,
		min = 1,
		max = 64,
		help = "frames between updates of cascade " .. c - 1,
	}
end

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
local min_coverage = pvars.Setup2{
	key = "ddgi_min_coverage",
	default = 4,
	min = 0,
	help = "least meters the fitted region reaches from its centre to each side",
}
local max_coverage = pvars.Setup2{
	key = "ddgi_max_coverage",
	default = 192,
	min = 0,
	help = "most meters the fitted region reaches from the camera",
}
ddgi.MIN_PROBES_PER_AXIS = 4
ddgi.RAYS_PER_PROBE = 128
-- The probe rays (ddgi_shade) in a half float texture instead of a full float
-- one, which halves it (142 MB to 71 MB at the defaults). A half float holds
-- at most 65504, so ray radiance is clamped to DDGI_RAY_MAX, a miss is stored
-- as 60000 m instead of 1e27, and an emitter sample's direction is packed in 6
-- bits per octahedral axis instead of 12.
ddgi.HALF_PRECISION_RAYS = true
-- static: the probe rays and the sun's shadow ray from their hits see through
-- alpha tested materials (leaves, fences) by sampling the albedo alpha in an
-- any hit shader, instead of hitting them as solids. everything else, the
-- translucent materials included, stays solid. needs scene_bvh.SOUP_UVS and
-- ray tracing. set to false to measure what it costs
ddgi.ALPHA_TEST = scene_bvh.SOUP_UVS
-- static: a ray hit's albedo is the albedo texture sampled at the hit's uv, at
-- the mip where the texture is about ALBEDO_UV_TEXELS wide, instead of the
-- texture's average colour. terrain keeps its own lookup. needs
-- scene_bvh.SOUP_UVS. set to false to compare with the average
ddgi.ALBEDO_UVS = scene_bvh.SOUP_UVS
ddgi.ALBEDO_UV_TEXELS = 8
-- Emissive surfaces light the probes only through emitter samples: per probe
-- and frame, EMITTER_SAMPLES shadow rays to points on emissive triangles. A
-- small or partly hidden emitter is rarely hit by the uniform rays, which
-- made it flicker (and the brightest ray clamp mostly dropped it). Each sample
-- draws ddgi_emitter_candidates points in proportion to their triangle's power and
-- keeps one by how much light it would bring the probe (resampled importance
-- sampling), so samples aren't spent on faces turned away or far off.
ddgi.EMITTER_SAMPLES = 32
local emitters_enabled = pvars.Setup2{
	key = "ddgi_emitters",
	default = true,
	help = "emissive surfaces light the probes, off is for telling whether they cause noise",
}
-- Drawing the candidates by power alone, wherever the emitters are, means that
-- with many tiny emitters spread over a map (glowing crystals) a probe seldom
-- draws the few that are near it. So the emitters are binned into a grid of
-- EMITTER_CELL_SIZE cells, and this share of the candidates is drawn from the 27
-- cells around the probe, a cell in proportion to its power over its distance
-- squared and then an emitter of it by power. The rest are still drawn by power
-- alone, which keeps the far emitters in (and the estimate unbiased: every
-- candidate is weighted by the density it was drawn with, see
-- ddgi_pick_emitter_sample). 0 is by power alone.
local emitter_grid = pvars.Setup2{
	key = "ddgi_emitter_grid",
	default = 0.75,
	min = 0,
	max = 1,
	help = "share of emitter candidates drawn from the cells around the probe, 0 is by power alone",
}
-- Materials that are only emissive because they are additive (light shafts,
-- waterfall foam, sparkles, flames) are effects drawn over the scene, but
-- would light the probes as surfaces at full emissive luminance. A single
-- light shaft billboard was 99.9% of one map's emitter power.
local additive_emitters = pvars.Setup2{
	key = "ddgi_additive_emitters",
	default = true,
	help = "additive materials light the probes like emissive surfaces do",
}
local emitter_cell_size = pvars.Setup2{
	key = "ddgi_emitter_cell_size",
	default = 4,
	min = 0.25,
	help = "meters across a cell of the grid the emitter candidates are drawn from",
}
-- At most 63: the kept one's index shares a word with the emitter's (see DDGI_EMITTER_SHIFT).
local emitter_candidates = pvars.Setup2{
	key = "ddgi_emitter_candidates",
	default = 8,
	integer = true,
	min = 1,
	max = 63,
	help = "emitters drawn per emitter sample, one is kept by how much light it brings the probe",
}
-- A ray hit is lit by LIGHT_SAMPLES of the local lights in its light grid
-- cell with a shadow ray each, not all of them: each picked in proportion to
-- the light it would bring unshadowed and weighted back by that probability,
-- so the probes' blending averages out the noise. At most 4.
ddgi.LIGHT_SAMPLES = 2
-- octahedral tile sizes including the one texel border that makes bilinear
-- sampling wrap correctly across the octahedron's edges
ddgi.IRRADIANCE_TEXELS = 8
ddgi.DISTANCE_TEXELS = 16
-- How much of a probe texel's history survives a frame, given for 60 fps and
-- scaled by the frame time, so light takes as long to settle at any frame
-- rate. A texel whose per frame estimates jump around (a doorway that one or
-- two rays see through) keeps HYSTERESIS, a steady one MIN_HYSTERESIS, which
-- follows gradual changes (the sun moving) sooner. NOISE_RANGE is the mean
-- relative deviation from the texel's average at which it counts as fully
-- noisy. A probe that just scrolled in averages its frames evenly until it
-- has had enough of them for the hysteresis to take over.
local hysteresis = pvars.Setup2{
	key = "ddgi_hysteresis",
	default = 0.99,
	min = 0,
	max = 1,
	help = "how much of a noisy texel's history survives a frame at 60 fps",
}
local min_hysteresis = pvars.Setup2{
	key = "ddgi_min_hysteresis",
	default = 0.95,
	min = 0,
	max = 1,
	help = "how much of a steady texel's history survives a frame at 60 fps",
}
local noise_range = pvars.Setup2{
	key = "ddgi_noise_range",
	default = 0.25,
	min = 0.001,
	help = "mean relative deviation at which a texel counts as fully noisy",
}
-- a texel whose every frame grew or shrank by more than this factor against
-- its history, ADAPT_FRAMES frames in a row, catches up quickly
local irradiance_threshold = pvars.Setup2{
	key = "ddgi_irradiance_threshold",
	default = 2.0,
	min = 1,
	help = "factor against its history a texel must differ by to adapt quickly",
}
local adapt_frames = pvars.Setup2{
	key = "ddgi_adapt_frames",
	default = 6,
	integer = true,
	min = 1,
	help = "frames in a row a texel must differ by the threshold to adapt quickly",
}
-- Caps every ray's radiance at this many times the probe's mean ray luminance
-- (see IRRADIANCE_INTEGRATE in passes/ddgi.lua), 0 is off. The mean leaves the
-- probe's brightest ray out, so a hot spot that one or two rays hit (a lit room
-- seen through a doorway, right next to a lamp) counts like a typical ray
-- instead of flashing the whole probe, while light that many rays see raises
-- the mean and passes through. The light above the cap is lost, so small bright
-- sources come out dimmer: the lower the factor, the calmer and the darker.
local ray_clamp = pvars.Setup2{
	key = "ddgi_ray_clamp",
	default = 0,
	min = 0,
	help = "cap each ray's radiance at this many times the probe's mean ray luminance, 0 is off",
}
-- Rays are steered by what the probe has seen. Each probe keeps an octahedral
-- map of the radiance its rays returned (see pass_guide in passes/ddgi.lua), and
-- this share of its rays is aimed at the cells in proportion to it, so a small
-- bright opening that one uniform ray in fifty goes through gets many. Every ray
-- carries the inverse of the density it was drawn with, so the estimate stays
-- unbiased. 0 is uniform rays only.
local guided_ray_fraction = pvars.Setup2{
	key = "ddgi_guided_rays",
	default = 0.5,
	min = 0,
	max = 0.75,
	help = "share of each probe's rays aimed by its own radiance map, 0 is uniform rays only",
}

function ddgi.GetUniformRays()
	return ddgi.RAYS_PER_PROBE - math.floor(ddgi.RAYS_PER_PROBE * guided_ray_fraction:Get() + 0.5)
end

-- local lights are treated as spheres of this radius (in probe spacings) when
-- lighting ray hits. A probe can't resolve a hot spot smaller than this, and a
-- ray landing right next to a lamp would otherwise outweigh all the others
-- and light up the whole probe for a frame
local light_radius = pvars.Setup2{
	key = "ddgi_light_radius",
	default = 0.1,
	min = 0,
	help = "radius of local lights in probe spacings when lighting ray hits",
}
-- sharpness of the cosine lobe the hit distances are averaged with
ddgi.DISTANCE_EXPONENT = 50.0
-- surface bias along the normal and towards the viewer, in probe spacings
ddgi.NORMAL_BIAS = 0.1
ddgi.VIEW_BIAS = 0.3
-- probes whose rays mostly hit back faces are inside geometry and are skipped
ddgi.BACKFACE_THRESHOLD = 0.25
-- Probes that land inside geometry move out of it (by at most
-- PROBE_MAX_OFFSET spacings), so that a probe inside a box does not get
-- disabled while the probes that take over its corner may be behind a wall.
-- Probes are not pushed off nearby surfaces: the rays are rotated every frame,
-- so that push is noisy, and visibility rays already stop the leaks it targeted.
local relocation = pvars.Setup2{
	key = "ddgi_relocation",
	default = true,
	help = "move probes out of geometry",
	callback = function()
		ddgi.ResetHistory()
	end,
}
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
local smooth_blend = pvars.Setup2{
	key = "ddgi_smooth_blend",
	default = true,
	help = "blend 3x3x3 probes with quadratic B-spline weights",
}
-- Probes a point blends are checked with a ray from the point, and dropped
-- when something is in the way (see ddgi_sample_cascade): 0 none, 1 relocated
-- probes (which can come out of a wall on its far side), 2 all of them (walls
-- thinner than the distance test can resolve). Needs ray queries.
local visibility_rays = pvars.Setup2{
	key = "ddgi_visibility_rays",
	default = 2,
	enums = {0, 1, 2},
	help = "probes checked with a ray: 0 none, 1 relocated ones, 2 all",
}
-- Visibility rays only hit front faces. The TLAS is rebuilt a few frames behind
-- a moving object, so a point on a face that moves away from its probes sits
-- just inside the object's stale copy and would otherwise see every probe
-- through that copy's back face (a black shadow trailing the object). The cost
-- is that fast moving objects can leak light where a back face should block.
local visibility_front_faces_only = pvars.Setup2{
	key = "ddgi_visibility_front_faces_only",
	default = true,
	help = "visibility rays only hit front faces",
}
-- 0 off, 1 probe irradiance, 2 probe mean hit distance (see passes/ddgi.lua)
local debug_probes = pvars.Setup2{
	key = "ddgi_debug_probes",
	default = 0,
	enums = {0, 1, 2},
	help = "0 off, 1 probe irradiance, 2 probe mean hit distance",
}
-- 0 off, 1 albedo, 2 normals, 3 hit distance (see passes/ddgi.lua)
local debug_scene = pvars.Setup2{
	key = "ddgi_debug_scene",
	default = 0,
	enums = {0, 1, 2, 3},
	help = "0 off, 1 albedo, 2 normals, 3 hit distance of the scene the probe rays trace",
}
-- 1 makes the lighting pass show only the gi irradiance
local debug_gi = pvars.Setup2{
	key = "ddgi_debug_gi",
	default = false,
	help = "show only the gi irradiance",
}
-- brightness of the debug view, which is shown in display units: 1 is about as
-- bright as the image gets before it would bloom
local debug_scale = pvars.Setup2{
	key = "ddgi_debug_scale",
	default = 1.0,
	min = 0,
	help = "brightness of the debug markers",
}
-- the cascade whose probes the debug view draws
local debug_cascade = pvars.Setup2{
	key = "ddgi_debug_cascade",
	default = 0,
	integer = true,
	min = 0,
	max = ddgi.CASCADES - 1,
	help = "the cascade whose probes the debug view draws",
}
local max_ray_distance = pvars.Setup2{
	key = "ddgi_max_ray_distance",
	default = 1000,
	integer = true,
	min = 0,
	help = "max distance a ray can travel",
}
pvars.EndGroup()
-- stored in a ray's distance slot when it missed everything, far past
-- MAX_RAY_DISTANCE
ddgi.MISS_DISTANCE = ddgi.HALF_PRECISION_RAYS and 60000 or 1e27

function ddgi.GetDebugProbes()
	return debug_probes:Get()
end

function ddgi.IsDebugGI()
	return debug_gi:Get()
end

function ddgi.GetCascadeSpacing(cascade)
	return probe_spacing:Get() * 2 ^ cascade
end

function ddgi.GetProbeCount()
	return ddgi.PROBES_PER_AXIS ^ 3 * ddgi.CASCADES
end

function ddgi.GetRayCount()
	return ddgi.GetProbeCount() * (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES)
end

function ddgi.IsEnabled()
	return enabled:Get()
end

-- rgb = irradiance, a = sky visibility: the contract the lighting pass reads
-- through gi_screen_tex
function ddgi.GetScreenTexture()
	if not enabled:Get() then return nil end

	local resolve = render3d.pipelines.ddgi_resolve
	return resolve and resolve:GetFramebuffer(1):GetAttachment(1) or nil
end

function ddgi.GetDebugSceneMode()
	return debug_scene:Get()
end

-- drawn over the lit image by the lighting pass; rgb = colour, a = coverage
function ddgi.GetDebugOverlayTexture()
	if debug_probes:Get() == 0 then return nil end

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
		update_mask = 0,
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
		local lo, hi = camera - min_coverage:Get(), camera + min_coverage:Get()

		if bounds_min then
			lo = math.max(bounds_min[axis], camera - max_coverage:Get())
			hi = math.min(bounds_max[axis], camera + max_coverage:Get())

			-- the scene lies entirely beyond MAX_COVERAGE
			if hi < lo then
				lo, hi = camera - min_coverage:Get(), camera + min_coverage:Get()
			end
		end

		if hi - lo < min_coverage:Get() * 2 then
			local mid = (lo + hi) / 2
			lo, hi = mid - min_coverage:Get(), mid + min_coverage:Get()
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
		local position = render3d.GetCamera():GetPosition()
		local bounds_min, bounds_max = scene_bvh.GetBounds()
		local region = state.region
		region.min_x, region.max_x = fit_region(0, position.x, bounds_min, bounds_max)
		region.min_y, region.max_y = fit_region(1, position.y, bounds_min, bounds_max)
		region.min_z, region.max_z = fit_region(2, position.z, bounds_min, bounds_max)
		local irradiance = render3d.pipelines.ddgi_irradiance
		local framebuffers = irradiance and irradiance.framebuffers
		local reset_mask = 0
		local update_mask = 0
		local frame_time = system.GetFrameTime()

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
			cascade.elapsed = (cascade.elapsed or 0) + frame_time
			local interval = update_intervals[c]:Get()

			-- a probe that scrolled into a slot is not usable until its cascade
			-- updates, so scrolling does not wait for the interval
			if
				(
					frame + c - 1
				) % interval == 0 or
				bit.band(reset_mask, bit.lshift(1, c - 1)) ~= 0 or
				cascade.x ~= cascade.updated_x or
				cascade.y ~= cascade.updated_y or
				cascade.z ~= cascade.updated_z
			then
				update_mask = bit.bor(update_mask, bit.lshift(1, c - 1))
				cascade.updated_x, cascade.updated_y, cascade.updated_z = cascade.x, cascade.y, cascade.z
				cascade.update_time = cascade.elapsed
				cascade.elapsed = 0
			end

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
		state.update_mask = bit.band(update_mask, bit.lshift(1, count) - 1)

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

-- The same spherical fibonacci + rotation as ddgi_fibonacci in GLSL, for the n
-- uniform rays of a probe.
function ddgi.GetRayDirection(index, n, rotation)
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
		// a kept emitter sample's hit word: the emitter's index, and above DDGI_EMITTER_SHIFT which candidate it was
		#define DDGI_EMITTER_SHIFT 26u
		#define DDGI_EMITTER_MASK 0x03FFFFFFu
		// ddgi_emitter.triangle: the soup index, and the material's double sidedness
		#define DDGI_EMITTER_DOUBLE_SIDED 0x80000000u
		// a probe's uniform rays followed by its emitter samples
		#define DDGI_RAY_STRIDE (DDGI_RAYS + DDGI_EMITTER_SAMPLES)
		#define DDGI_IRRADIANCE_TEXELS %d
		#define DDGI_DISTANCE_TEXELS %d
		#define DDGI_MISS_DISTANCE %.1e
		// what the ray texture can hold, and the bits per octahedral axis of an
		// emitter sample's direction, which has to sit exactly in one of its floats
		#define DDGI_RAY_MAX %.1e
		#define DDGI_DIRECTION_BITS %du
		#define DDGI_DIRECTION_OFFSET %.1f
		#define DDGI_SUN_VISIBLE_BIT 0x80000000u
		#define DDGI_SHADOW_OFFSET 0.02
		#define DDGI_LIGHT_SAMPLES %d
		#define DDGI_BACKFACE_SCALE 0.2
		// GLSL leaves %% undefined for negative operands (NVIDIA treats them
		// as unsigned), so shift into the positive range before wrapping
		#define DDGI_WRAP(v, n) (((v) + (n) * 65536) %% (n))
		// the instances a probe's visibility ray can hit, which leaves out foliage with ddgi.ALPHA_TEST
		#define DDGI_VISIBILITY_MASK %d
	]]
	):format(
		ddgi.PROBES_PER_AXIS,
		ddgi.CASCADES,
		ddgi.RAYS_PER_PROBE,
		ddgi.EMITTER_SAMPLES,
		ddgi.IRRADIANCE_TEXELS,
		ddgi.DISTANCE_TEXELS,
		ddgi.MISS_DISTANCE,
		ddgi.HALF_PRECISION_RAYS and 65000 or 3e38,
		ddgi.HALF_PRECISION_RAYS and 6 or 12,
		-- a half float is exact from -2048 to 2048, so the 12 packed bits are centred on 0
		ddgi.HALF_PRECISION_RAYS and 2048 or 0,
		ddgi.LIGHT_SAMPLES,
		ddgi.ALPHA_TEST and scene_bvh.RAY_MASK_SOLID or 0xFF
	)
end

function ddgi.GetRayDirectionGLSL()
	return [[
		#define DDGI_GUIDE_TEXELS 8
		#define DDGI_GUIDE_CELLS 64
		// what reads the guide texel of a probe's tile, so that the ray generation
		// shader and the guide pass can use their own bindings
		#ifndef DDGI_GUIDE_FETCH
		#define DDGI_GUIDE_FETCH(texel) texelFetch(TEXTURE(ddgi_data.ddgi_guide_tex), texel, 0)
		#endif

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

		// index of count spherical fibonacci points, rotated by q
		vec3 ddgi_fibonacci(uint index, uint count, vec4 q) {
			const float golden = 0.61803398875;
			float phi = 6.28318530718 * fract(float(index) * golden);
			float cos_theta = 1.0 - (2.0 * float(index) + 1.0) / float(count);
			float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
			vec3 v = vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
			return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
		}

		// The guide is one 8x8 octahedral tile per probe, in world space. Per
		// cell: r = mean radiance luminance, g = the probability a guided ray
		// picks the cell, b = cumulative probability up to and including it,
		// a = stamp of the probe that wrote it. A slot that a different probe
		// scrolled into has a stamp that does not match, and its rays are uniform.
		float ddgi_guide_stamp(ivec3 world, int c) {
			uint h = uint(world.x) * 73856093u ^ uint(world.y) * 19349663u ^ uint(world.z) * 83492791u ^ uint(c + 1) * 2654435761u;
			return float(h & 0xFFFFFFu) + 1.0;
		}

		ivec2 ddgi_guide_texel(ivec2 tile, int cell) {
			return tile * DDGI_GUIDE_TEXELS + ivec2(cell % DDGI_GUIDE_TEXELS, cell / DDGI_GUIDE_TEXELS);
		}

		bool ddgi_guide_valid(ivec2 tile, ivec3 world, int c) {
			return DDGI_GUIDE_FETCH(ddgi_guide_texel(tile, 0)).a == ddgi_guide_stamp(world, c);
		}

		// The first uniform_count rays of a probe are uniform, the rest are drawn
		// from the guide: stratified along its cumulative probability, then
		// anywhere in the cell. The jitter is derived from the frame's random
		// rotation.
		vec3 ddgi_ray_direction(uint index, uint uniform_count, vec4 q, ivec2 tile, bool guided) {
			if (index < uniform_count) return ddgi_fibonacci(index, uniform_count, q);

			uint k = index - uniform_count;
			uint guided_count = uint(DDGI_RAYS) - uniform_count;

			if (!guided) return ddgi_fibonacci(k, guided_count, q);

			vec3 jitter = fract(abs(q.xyz) * 1000.0 + q.w * 7.0);
			float u = fract((float(k) + 0.5) / float(guided_count) + jitter.x);
			int lo = 0;
			int hi = DDGI_GUIDE_CELLS - 1;

			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (DDGI_GUIDE_FETCH(ddgi_guide_texel(tile, mid)).b < u) {
					lo = mid + 1;
				} else {
					hi = mid;
				}
			}

			vec2 inner = fract(vec2(0.7548776662, 0.5698402910) * float(k) + jitter.yz);
			vec2 p = (vec2(lo % DDGI_GUIDE_TEXELS, lo / DDGI_GUIDE_TEXELS) + inner) / float(DDGI_GUIDE_TEXELS) * 2.0 - 1.0;
			return ddgi_oct_decode(p);
		}

		// What a ray of direction d counts for: the inverse of the density it was
		// drawn with (the uniform rays' and the guide's mixed by their share of
		// the rays), scaled so that uniform rays alone weigh 1. A cell's
		// probability spreads over its share of the octahedron's plane, and a
		// unit of that plane covers |d|_1^3 steradians.
		float ddgi_ray_weight(vec3 d, uint uniform_count, ivec2 tile, bool guided) {
			if (!guided || uniform_count >= uint(DDGI_RAYS)) return 1.0;

			ivec2 cell = clamp(ivec2((ddgi_oct_encode(d) * 0.5 + 0.5) * float(DDGI_GUIDE_TEXELS)), ivec2(0), ivec2(DDGI_GUIDE_TEXELS - 1));
			float probability = DDGI_GUIDE_FETCH(tile * DDGI_GUIDE_TEXELS + cell).g;
			vec3 a = abs(d);
			float l1 = a.x + a.y + a.z;
			float density = probability * float(DDGI_GUIDE_TEXELS * DDGI_GUIDE_TEXELS) * 0.25 / (l1 * l1 * l1);
			float share = float(uniform_count) / float(DDGI_RAYS);
			return 1.0 / (share + (1.0 - share) * density * 12.5663706144);
		}
	]]
end

-- total probe weight below which a lookup is darkened rather than normalized
local MIN_WEIGHT = "0.05"
ddgi.MIN_WEIGHT = MIN_WEIGHT

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
		// The emitters as words, built by ddgi.GetEmitters:
		//   0 hash mask, 1 cell size (float), 2 cells' first word, 3 cell emitters'
		//   first word, 4 emitters' first word, 5 total power (float), 6 emitter count
		// A cell (10 words, empty when its count is 0): x y z, first cell emitter,
		// count, power (float), power weighted centroid (3 floats).
		// A cell emitter (3 words): its emitter, its cdf within the cell (float),
		// its power (float).
		// An emitter (4 words): its triangle (and the double sided bit), its cdf
		// over all emitters (float), its power (float), its cell.
		layout(set = 0, binding = %d) readonly buffer DDGIEmitters {
			uint ddgi_grid[];
		};
	]]
	):format(binding)
end

-- Picking and placing an emitter sample, shared by the trace (which traces
-- it) and the shade pass (which lights with it); both derive the
-- same random numbers from the sample's ray index and the frame. Needs
-- ddgi_emitters and scene_bvh_triangles.
-- The material buffer written by ddgi.WriteMaterialBuffer, indexed by a soup
-- triangle's material id.
function ddgi.GetMaterialDeclarationsGLSL(binding)
	return [[
		struct ddgi_material {
			vec3 albedo;
			int albedo_tex;
			int double_sided;
			// terrain: the layer weights texture, -1 for other materials
			int terrain_tex;
			ivec4 terrain_layer_tex;
			// min x, min z, 1 / size of the square terrain_tex covers
			vec3 terrain_bounds;
			vec4 terrain_detail;
			vec4 terrain_additive_detail;
			float alpha;
			float alpha_cutoff;
			// 0 solid, 1 alpha tested by alpha alone, 2 by the albedo texture's alpha times alpha
			int alpha_test;
			// the sun's shadow ray passes through it, tinted (see glass_tint.lua)
			int glass;
			// displacement blending: the second albedo and the blend modulate texture, -1 without
			int albedo2_tex;
			int blend_tex;
		};
		layout(scalar, set = 0, binding = ]] .. binding .. [[) readonly buffer DDGIMaterials {
			ddgi_material ddgi_materials[];
		};
	]]
end

-- needs render3d.GetEmissiveGLSL
function ddgi.GetMaterialGLSL()
	return [[
		// no uvs at a hit, so textured surfaces use the texture's average
		// colour from its smallest mip. terrain finds its uv from where it was
		// hit and blends its layers' averages like the gbuffer blends the layers
		vec3 ddgi_albedo(ddgi_material material, vec3 P) {
			if (material.terrain_tex >= 0) {
				vec2 uv = (P.xz - material.terrain_bounds.xy) * material.terrain_bounds.z;
				vec4 weights = max(textureLod(TEXTURE(material.terrain_tex), uv, 0.0), vec4(0.0));
				float weight_sum = dot(weights, vec4(1.0));

				if (weight_sum <= 0.0001) return material.albedo;

				weights /= weight_sum;
				vec3 base = material.albedo_tex >= 0 ? textureLod(TEXTURE(material.albedo_tex), uv, 0.0).rgb : vec3(1.0);
				vec3 albedo = vec3(0.0);

				for (int i = 0; i < 4; i++) {
					vec3 layer = base;

					if (material.terrain_layer_tex[i] >= 0) {
						vec3 average = textureLod(TEXTURE(material.terrain_layer_tex[i]), vec2(0.5), 16.0).rgb;
						float detail = material.terrain_detail[i];

						if (detail <= 0.0) {
							layer = average * base;
						} else if (material.terrain_additive_detail[i] > 0.0) {
							layer = pow(max(pow(base, vec3(1.0 / 2.2)) + (average - 0.5) * detail, vec3(0.0)), vec3(2.2)) * material.terrain_additive_detail[i];
						}
						// a non additive detail layer only varies around base
					}

					albedo += layer * weights[i];
				}

				return albedo * material.albedo;
			}

			vec3 albedo = material.albedo;

			if (material.albedo_tex >= 0) {
				albedo *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;
			}

			return albedo;
		}

		vec3 ddgi_emission(scene_bvh_triangle tri, vec3 albedo) {
			return min(tri.emissive * albedo * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));
		}
	]]
end

-- The albedo at a ray hit on a soup triangle, with the uv lookup of
-- ddgi.ALBEDO_UVS when it is on (needs the uv declaration then).
function ddgi.GetHitAlbedoGLSL()
	if not ddgi.ALBEDO_UVS then
		return [[
			vec3 ddgi_hit_albedo(ddgi_material material, vec3 P, uint triangle) {
				return ddgi_albedo(material, P);
			}
		]]
	end

	return [[
		#define DDGI_ALBEDO_UV_TEXELS ]] .. string.format("%.1f", ddgi.ALBEDO_UV_TEXELS) .. [[

		vec3 ddgi_hit_albedo(ddgi_material material, vec3 P, uint triangle) {
			if (material.terrain_tex >= 0 || material.albedo_tex < 0) return ddgi_albedo(material, P);

			scene_bvh_triangle tri = bvh_tri(triangle);
			vec3 p = P - tri.v0;
			float d00 = dot(tri.e1, tri.e1);
			float d01 = dot(tri.e1, tri.e2);
			float d11 = dot(tri.e2, tri.e2);
			float d20 = dot(p, tri.e1);
			float d21 = dot(p, tri.e2);
			float inv = 1.0 / (d00 * d11 - d01 * d01);
			float v = (d11 * d20 - d01 * d21) * inv;
			float w = (d00 * d21 - d01 * d20) * inv;
			scene_bvh_uv uv = bvh_uv(triangle);
			vec2 coord = uv.uv0 * (1.0 - v - w) + uv.uv1 * v + uv.uv2 * w;
			ivec2 size = textureSize(TEXTURE(material.albedo_tex), 0);
			float lod = max(log2(float(max(size.x, size.y)) / DDGI_ALBEDO_UV_TEXELS), 0.0);
			vec3 rgb = textureLod(TEXTURE(material.albedo_tex), coord, lod).rgb;

			if (material.albedo2_tex >= 0) {
				float blend = uv.blend.x * (1.0 - v - w) + uv.blend.y * v + uv.blend.z * w;

				if (material.blend_tex >= 0) {
					// source blendmodulate: g is the transition center, r its half width
					vec2 modulate = textureLod(TEXTURE(material.blend_tex), coord, lod).rg;
					blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
				}

				if (blend != 0.0) {
					ivec2 size2 = textureSize(TEXTURE(material.albedo2_tex), 0);
					float lod2 = max(log2(float(max(size2.x, size2.y)) / DDGI_ALBEDO_UV_TEXELS), 0.0);
					rgb = mix(rgb, textureLod(TEXTURE(material.albedo2_tex), coord, lod2).rgb, blend);
				}
			}

			return material.albedo * rgb;
		}
	]]
end

-- Whether a hit on a soup triangle counts, for the alpha tested materials
-- (see ddgi.ALPHA_TEST). Needs the material and uv declarations, bvh_tri and a
-- TEXTURE macro.
function ddgi.GetAlphaTestGLSL()
	return [[
		bool ddgi_alpha_passes(uint triangle, vec2 barycentrics) {
			ddgi_material material = ddgi_materials[bvh_tri(triangle).material];

			if (material.alpha_test == 0) return true;

			float alpha = material.alpha;

			if (material.alpha_test == 2) {
				scene_bvh_uv uv = bvh_uv(triangle);
				vec2 coord = uv.uv0 * (1.0 - barycentrics.x - barycentrics.y) + uv.uv1 * barycentrics.x + uv.uv2 * barycentrics.y;
				alpha *= textureLod(TEXTURE(material.albedo_tex), coord, 0.0).a;
			}

			return alpha >= material.alpha_cutoff;
		}
	]]
end

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

		uint ddgi_emitter_triangle(int e) {
			return ddgi_grid[ddgi_grid[4] + uint(e) * 4u];
		}

		int ddgi_pick_emitter(float u, int count) {
			uint base = ddgi_grid[4];
			int lo = 0;
			int hi = count - 1;

			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (uintBitsToFloat(ddgi_grid[base + uint(mid) * 4u + 1u]) < u) {
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

		// An emitter sample seen from origin. Candidates are drawn by a mix of two
		// proposals: by power over all emitters, and (for grid_share of them) from
		// the 27 cells of the grid around the origin, a cell by its power over its
		// distance squared and then an emitter of it by power. One is kept with a
		// probability proportional to its weight, the light it would bring
		// unshadowed (facing / distance^2, inside radius flattened like the local
		// lights) times its luminance, over the density it was drawn with
		// (resampled importance sampling). Returns the candidates' summed weight,
		// which with the kept emitter's colour and the candidate count is the
		// estimate, and which one was kept and where; the shade pass rebuilds its
		// point from the same random numbers.
		float ddgi_pick_emitter_sample(uint index, uint frame, int emitter_count, uint candidates, float grid_share, vec3 origin, float radius, out int kept_emitter, out uint kept, out vec3 kept_point) {
			float weight_sum = 0.0;
			kept = 0u;
			kept_emitter = 0;
			kept_point = vec3(0.0);

			uint hash_mask = ddgi_grid[0];
			float cell_size = uintBitsToFloat(ddgi_grid[1]);
			uint cells = ddgi_grid[2];
			uint cell_emitters = ddgi_grid[3];
			uint emitters = ddgi_grid[4];
			float total_power = uintBitsToFloat(ddgi_grid[5]);
			ivec3 origin_cell = ivec3(floor(origin / cell_size));
			float cell_weight[27];
			float cell_power[27];
			uint cell_first[27];
			uint cell_count[27];
			float weight_total = 0.0;

			if (grid_share > 0.0) {
				for (int k = 0; k < 27; k++) {
					ivec3 cell = origin_cell + ivec3(k % 3 - 1, (k / 3) % 3 - 1, k / 9 - 1);
					uint h = (uint(cell.x) * 73856093u ^ uint(cell.y) * 19349663u ^ uint(cell.z) * 83492791u) & hash_mask;
					cell_weight[k] = 0.0;
					cell_power[k] = 0.0;
					cell_first[k] = 0u;
					cell_count[k] = 0u;

					// linear probing up to the first empty cell
					for (uint probe = 0u; probe <= hash_mask; probe++) {
						uint b = cells + h * 10u;
						uint n = ddgi_grid[b + 4u];

						if (n == 0u) break;

						if (ivec3(int(ddgi_grid[b]), int(ddgi_grid[b + 1u]), int(ddgi_grid[b + 2u])) == cell) {
							vec3 to_centroid = origin - vec3(uintBitsToFloat(ddgi_grid[b + 6u]), uintBitsToFloat(ddgi_grid[b + 7u]), uintBitsToFloat(ddgi_grid[b + 8u]));
							float flat_distance = cell_size * 0.5;
							cell_power[k] = uintBitsToFloat(ddgi_grid[b + 5u]);
							cell_weight[k] = cell_power[k] / max(dot(to_centroid, to_centroid), flat_distance * flat_distance);
							cell_first[k] = ddgi_grid[b + 3u];
							cell_count[k] = n;
							weight_total += cell_weight[k];
							break;
						}

						h = (h + 1u) & hash_mask;
					}
				}
			}

			// no cell around the origin has an emitter: by power alone
			float share = weight_total > 0.0 ? grid_share : 0.0;

			for (uint j = 0u; j < candidates; j++) {
				vec4 u = ddgi_emitter_random(index, frame, j);
				vec4 u2 = ddgi_emitter_random(index, frame, j + 64u);
				int e;
				float power;
				float grid_density = 0.0;

				if (u.x < share) {
					float target = max(u.x / share * weight_total, 1e-30);
					int k = 0;
					float running = cell_weight[0];

					while (k < 26 && running < target) {
						k++;
						running += cell_weight[k];
					}

					if (cell_count[k] == 0u) continue;

					int lo = 0;
					int hi = int(cell_count[k]) - 1;

					while (lo < hi) {
						int mid = (lo + hi) / 2;

						if (uintBitsToFloat(ddgi_grid[cell_emitters + (cell_first[k] + uint(mid)) * 3u + 1u]) < u2.x) {
							lo = mid + 1;
						} else {
							hi = mid;
						}
					}

					uint r = cell_emitters + (cell_first[k] + uint(lo)) * 3u;
					e = int(ddgi_grid[r]);
					power = uintBitsToFloat(ddgi_grid[r + 2u]);
					grid_density = cell_weight[k] / weight_total * power / cell_power[k];
				} else {
					e = ddgi_pick_emitter(share >= 1.0 ? 0.0 : (u.x - share) / (1.0 - share), emitter_count);
					uint g = emitters + uint(e) * 4u;
					power = uintBitsToFloat(ddgi_grid[g + 2u]);

					if (share > 0.0) {
						uint b = cells + ddgi_grid[g + 3u] * 10u;
						ivec3 offset = ivec3(int(ddgi_grid[b]), int(ddgi_grid[b + 1u]), int(ddgi_grid[b + 2u])) - origin_cell;

						if (all(lessThanEqual(abs(offset), ivec3(1)))) {
							int k = offset.x + 1 + (offset.y + 1) * 3 + (offset.z + 1) * 9;
							grid_density = cell_weight[k] / weight_total * power / cell_power[k];
						}
					}
				}

				float density = share * grid_density + (1.0 - share) * power / total_power;

				if (!(density > 0.0)) continue;

				uint triangle = ddgi_grid[emitters + uint(e) * 4u];
				scene_bvh_triangle tri = bvh_tri(triangle & ~DDGI_EMITTER_DOUBLE_SIDED);
				vec3 point = ddgi_emitter_point(tri, u.yz);
				vec3 to_point = point - origin;
				float dist2 = dot(to_point, to_point);
				// tri.normal points away from the visible side
				float facing = dot(tri.normal, to_point) * inversesqrt(dist2);

				if ((triangle & DDGI_EMITTER_DOUBLE_SIDED) != 0u) facing = abs(facing);

				float weight = max(facing, 0.0) / max(dist2, radius * radius) * power / density;
				weight_sum += weight;

				if (weight > 0.0 && u.w * weight_sum < weight) {
					kept = j;
					kept_emitter = e;
					kept_point = point;
				}
			}

			return weight_sum;
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
			if (ddgi_data.ddgi_cascade_count == 0) return false;

			int c = ddgi_data.ddgi_cascade_count - 1;
			vec3 grid = P / ddgi_spacing(c) - vec3(ddgi_volume_base(c));
			return all(greaterThanEqual(grid, vec3(0.0))) && all(lessThanEqual(grid, vec3(ddgi_volume_size(c) - 1)));
		}

		float ddgi_pack_direction(vec3 d) {
			const float levels = float((1u << DDGI_DIRECTION_BITS) - 1u);
			uvec2 q = uvec2((ddgi_oct_encode(d) * 0.5 + 0.5) * levels + 0.5);
			return float(q.x | (q.y << DDGI_DIRECTION_BITS)) - DDGI_DIRECTION_OFFSET;
		}

		vec3 ddgi_unpack_direction(float packed) {
			const uint mask = (1u << DDGI_DIRECTION_BITS) - 1u;
			uint v = uint(packed + DDGI_DIRECTION_OFFSET);
			return ddgi_oct_decode(vec2(v & mask, v >> DDGI_DIRECTION_BITS) / float(mask) * 2.0 - 1.0);
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

		// w is 1 + the smoothed fraction of back face hits, plus 2 when the update
		// moved the probe (the rays it was last integrated from started somewhere
		// else), plus 4 when the probe is disabled (inside geometry)
		int ddgi_probe_flags(vec4 data) {
			return int((data.w - 1.0) * 0.5);
		}

		bool ddgi_probe_moved(vec4 data) {
			return (ddgi_probe_flags(data) & 1) != 0;
		}

		bool ddgi_probe_disabled(vec4 data) {
			return (ddgi_probe_flags(data) & 2) != 0;
		}

		float ddgi_probe_backfaces(vec4 data) {
			return data.w - 1.0 - 2.0 * float(ddgi_probe_flags(data));
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

		// a probe's ray index, from its tile and whether its guide is usable
		vec3 ddgi_ray(uint index, ivec2 tile, bool guided) {
			return ddgi_ray_direction(index, uint(ddgi_data.ddgi_uniform_rays), ddgi_data.ddgi_rotation, tile, guided);
		}

		float ddgi_ray_q(vec3 d, ivec2 tile, bool guided) {
			return ddgi_ray_weight(d, uint(ddgi_data.ddgi_uniform_rays), tile, guided);
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

				if (!ddgi_probe_is_current(data, world) || ddgi_probe_disabled(data)) continue;

				vec3 probe_pos = data.xyz * spacing;

				#ifdef DDGI_VISIBILITY_RAYS
				if (ddgi_data.ddgi_rt_ready != 0 && (ddgi_data.ddgi_visibility_rays == 2 || ddgi_data.ddgi_visibility_rays == 1 && data.xyz != vec3(world))) {
					vec3 origin = P + N * (0.02 * spacing);
					vec3 to_probe = probe_pos - origin;
					float len = length(to_probe);

					// a ray query with a nan or zero direction is undefined
					if (!(len > 1e-4)) continue;

					rayQueryEXT query;
					rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | (ddgi_data.ddgi_visibility_front_faces_only != 0 ? gl_RayFlagsCullBackFacingTrianglesEXT : 0u), DDGI_VISIBILITY_MASK, origin, 0.0, to_probe / len, len);

					while (rayQueryProceedEXT(query)) {}

					if (rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT) continue;
				}
				#endif

				vec3 kernel = smooth_blend ? mix(mix(below, middle, equal(offset, ivec3(1))), above, equal(offset, ivec3(2))) : mix(1.0 - alpha, alpha, vec3(offset));
				vec3 to_probe = normalize(probe_pos - P);
				float w = (dot(to_probe, N) + 1.0) * 0.5;
				w = w * w + 0.2;

				vec3 probe_to_point = biased - probe_pos;
				float dist = length(probe_to_point);
				vec2 moments = textureLod(
					TEXTURE(ddgi_data.ddgi_distance_tex),
					ddgi_atlas_uv(slot, c, probe_to_point / max(dist, 1e-4), DDGI_DISTANCE_TEXELS),
					0.0
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
				sum += textureLod(
					TEXTURE(ddgi_data.ddgi_irradiance_tex),
					ddgi_atlas_uv(slot, c, N, DDGI_IRRADIANCE_TEXELS),
					0.0
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

-- The fields ddgi_sample_irradiance needs, for passes that only read the
-- probes (volumetric_fog.lua); GetBlockLayout adds what the DDGI passes need.
function ddgi.GetProbeBlockLayout()
	return {
		-- xyz = volume base (the lowest probe's world coordinate), w = spacing
		{"ddgi_cascades", "vec4", ddgi.CASCADES},
		-- xyz = probes along each axis, w = bits of the axes (1 x, 2 y, 4 z)
		-- along which the cascade holds the whole scene
		{"ddgi_cascade_size", "vec4", ddgi.CASCADES},
		{"ddgi_rotation", "vec4"},
		{"ddgi_sun_direction", "vec4"},
		{"ddgi_sun_radiance", "vec4"},
		{"ddgi_max_distance", "float"},
		-- x = hysteresis, y = minimum hysteresis, scaled by the time since the
		-- cascade's last update
		{"ddgi_cascade_update", "vec4", ddgi.CASCADES},
		{"ddgi_noise_range", "float"},
		{"ddgi_irradiance_threshold", "float"},
		{"ddgi_adapt_frames", "float"},
		{"ddgi_ray_clamp", "float"},
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
		{"ddgi_debug_scene", "int"},
		{"ddgi_debug_manual_gamma", "int"},
		{"ddgi_smooth_blend", "int"},
		{"ddgi_visibility_rays", "int"},
		{"ddgi_visibility_front_faces_only", "int"},
		{"ddgi_cascade_count", "int"},
		-- bit c: cascade c's history is garbage
		{"ddgi_reset_mask", "int"},
		-- bit c: cascade c traces and blends this frame
		{"ddgi_update_mask", "int"},
		{"ddgi_rt_ready", "int"},
		{"ddgi_env_tex", "int"},
		{"ddgi_env_irradiance_tex", "int"},
		{"ddgi_ray_tex", "int"},
		{"ddgi_irradiance_tex", "int"},
		{"ddgi_distance_tex", "int"},
		{"ddgi_probe_data_tex", "int"},
		{"ddgi_emitter_count", "int"},
		-- the summed power of all emitters
		-- see ddgi_emitter_grid
		{"ddgi_emitter_grid", "float"},
		{"ddgi_frame", "int"},
		-- the rays of a probe that are not aimed by its guide
		{"ddgi_uniform_rays", "int"},
		{"ddgi_emitter_candidates", "int"},
		{"ddgi_guide_tex", "int"},
	}
end

function ddgi.GetBlockLayout()
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
		clouds.GetShadowBlockLayout(),
	}
	table.add(layout, ddgi.GetProbeBlockLayout())
	table.add(layout, post_source.pre_exposure_block)
	layout[#layout + 1] = glass_tint.block
	return layout
end

local function pipeline_texture_index(self, name)
	local pipeline = render3d.pipelines[name]
	return pipeline and
		self:GetTextureIndex(pipeline:GetFramebuffer(1):GetAttachment(1)) or
		-1
end

function ddgi.WriteProbeBlock(self, block)
	local state = ddgi.GetFrameState()
	local lights = render3d.GetLights()
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
	block.ddgi_max_distance = max_ray_distance:Get()

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		-- a hitch shouldn't throw the history away
		local frames = math.min(cascade.update_time, 0.1 * update_intervals[c]:Get()) * 60
		block.ddgi_cascade_update[c - 1][0] = hysteresis:Get() ^ frames
		block.ddgi_cascade_update[c - 1][1] = min_hysteresis:Get() ^ frames
	end

	block.ddgi_noise_range = noise_range:Get()
	block.ddgi_irradiance_threshold = irradiance_threshold:Get()
	block.ddgi_adapt_frames = adapt_frames:Get()
	block.ddgi_ray_clamp = ray_clamp:Get()
	block.ddgi_distance_exponent = ddgi.DISTANCE_EXPONENT
	block.ddgi_normal_bias = ddgi.NORMAL_BIAS
	block.ddgi_view_bias = ddgi.VIEW_BIAS
	block.ddgi_backface_threshold = ddgi.BACKFACE_THRESHOLD
	-- in spacings, like the biases and the light radius
	block.ddgi_relocation_distance = relocation:Get() and ddgi.RELOCATION_DISTANCE or 0
	block.ddgi_max_offset = relocation:Get() and ddgi.PROBE_MAX_OFFSET or 0
	block.ddgi_sky_intensity = ddgi.SKY_INTENSITY
	block.ddgi_light_radius = light_radius:Get()
	block.ddgi_cascade_blend = ddgi.CASCADE_BLEND
	block.ddgi_debug_scale = debug_scale:Get()
	block.ddgi_debug_probes = debug_probes:Get()
	block.ddgi_debug_cascade = debug_cascade:Get()
	block.ddgi_debug_scene = debug_scene:Get()
	block.ddgi_debug_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
	block.ddgi_smooth_blend = smooth_blend:Get() and 1 or 0
	block.ddgi_visibility_rays = visibility_rays:Get()
	block.ddgi_visibility_front_faces_only = visibility_front_faces_only:Get() and 1 or 0
	block.ddgi_cascade_count = enabled:Get() and state.cascade_count or 0
	block.ddgi_reset_mask = state.reset_mask
	block.ddgi_update_mask = state.update_mask
	block.ddgi_rt_ready = state.rt_ready and 1 or 0
	block.ddgi_env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.ddgi_env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	block.ddgi_ray_tex = pipeline_texture_index(self, "ddgi_shade")
	block.ddgi_irradiance_tex = pipeline_texture_index(self, "ddgi_irradiance")
	block.ddgi_distance_tex = pipeline_texture_index(self, "ddgi_distance")
	block.ddgi_probe_data_tex = pipeline_texture_index(self, "ddgi_probe_data")
	local emitters = ddgi.GetEmitters()
	block.ddgi_emitter_count = emitters_enabled:Get() and emitters.count or 0
	block.ddgi_emitter_grid = emitter_grid:Get()
	block.ddgi_frame = state.frame
	block.ddgi_uniform_rays = ddgi.GetUniformRays()
	block.ddgi_emitter_candidates = emitter_candidates:Get()
	block.ddgi_guide_tex = pipeline_texture_index(self, "ddgi_guide")
	return block
end

function ddgi.WriteBlock(self, block)
	render3d.WriteCameraBlock(self, block)
	gbuffer_layout.WriteBlock(self, block)
	-- every light, not just those in view: probes see what the camera doesn't,
	-- and the shadow rays make that safe
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	clouds.WriteShadowBlock(self, block)
	post_source.WritePreExposureBlock(self, block)
	glass_tint.WriteBlock(self, block)
	return ddgi.WriteProbeBlock(self, block)
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

-- Every emissive triangle of the scene soup, as the words ddgi_grid in GLSL
-- reads (see GetEmitterDeclarationsGLSL): the emitters with the running sum of
-- their power for picking one in proportion to it, and a hash grid of cells
-- holding the emitters whose centroid is in them, for picking one near a probe.
-- weight is the total power. Rebuilt whenever the soup or the cell size changes.
do
	local GRID_HEADER = 8
	local CELL_WORDS = 10
	local CELL_EMITTER_WORDS = 3
	local EMITTER_WORDS = 4
	local WordArray = ffi.typeof("uint32_t[?]")
	local FloatArray = ffi.typeof("float[?]")
	local Words = ffi.typeof("uint32_t*")
	local Ints = ffi.typeof("int32_t*")
	local Floats = ffi.typeof("float*")
	local emitters = {
		words = WordArray(1),
		word_capacity = 1,
		word_count = 0,
		count = 0,
		weight = 0,
		version = 0,
		soup_version = -1,
		top_version = -1,
		cell_size = 0,
		additive = false,
		excluded_count = 0,
		excluded_power = 0,
	}
	local buffers = {}
	local buffer_versions = {}
	local fill = FloatArray(1)
	local running = FloatArray(1)
	local scratch_capacity = 1

	function ddgi.GetEmitters()
		local cell_size = emitter_cell_size:Get()
		local additive = additive_emitters:Get()

		if
			emitters.soup_version == scene_bvh.soup_version and
			emitters.top_version == scene_bvh.top_version and
			emitters.cell_size == cell_size and
			emitters.additive == additive
		then
			return emitters
		end

		local total_count = 0

		for _, block in ipairs(scene_bvh.emissive_blocks) do
			total_count = total_count + block.emitter_count
		end

		-- at least twice as many cells as emitters, so probing ends at an empty one
		local capacity = 64

		while capacity < total_count * 2 do
			capacity = capacity * 2
		end

		local mask = capacity - 1
		local cells_base = GRID_HEADER
		local cell_emitters_base = cells_base + capacity * CELL_WORDS
		local emitters_base = cell_emitters_base + total_count * CELL_EMITTER_WORDS
		local word_count = emitters_base + total_count * EMITTER_WORDS

		if emitters.word_capacity < word_count then
			emitters.words = WordArray(word_count * 2)
			emitters.word_capacity = word_count * 2
		end

		if scratch_capacity < capacity then
			fill = FloatArray(capacity * 2)
			running = FloatArray(capacity * 2)
			scratch_capacity = capacity * 2
		end

		local words = emitters.words
		ffi.fill(words, word_count * 4)
		ffi.fill(fill, capacity * 4)
		ffi.fill(running, capacity * 4)
		local ints = ffi.cast(Ints, words)
		local floats = ffi.cast(Floats, words)
		local inverse = 1 / cell_size
		local count, weight = 0, 0
		local excluded_count, excluded_power = 0, 0

		for _, block in ipairs(scene_bvh.emissive_blocks) do
			local block_emitters = block.emitters
			local tri_base = block.tri_base

			for j = 0, block.emitter_count - 1 do
				local emitter = block_emitters[j]
				local power = emitter.power

				if emitter.additive ~= 0 and not additive then
					excluded_count = excluded_count + 1
					excluded_power = excluded_power + power
				elseif power > 0 then
					weight = weight + power
					local g = emitters_base + count * EMITTER_WORDS
					words[g] = emitter.triangle + tri_base
					floats[g + 1] = weight
					floats[g + 2] = power
					local x = math.floor(emitter.x * inverse)
					local y = math.floor(emitter.y * inverse)
					local z = math.floor(emitter.z * inverse)
					local h = bit.band(bit.bxor(bit.bxor(x * 73856093, y * 19349663), z * 83492791), mask)

					while true do
						local b = cells_base + h * CELL_WORDS

						if words[b + 4] == 0 then
							ints[b], ints[b + 1], ints[b + 2] = x, y, z

							break
						end

						if ints[b] == x and ints[b + 1] == y and ints[b + 2] == z then break end

						h = bit.band(h + 1, mask)
					end

					local b = cells_base + h * CELL_WORDS
					words[b + 4] = words[b + 4] + 1
					floats[b + 5] = floats[b + 5] + power
					floats[b + 6] = floats[b + 6] + power * emitter.x
					floats[b + 7] = floats[b + 7] + power * emitter.y
					floats[b + 8] = floats[b + 8] + power * emitter.z
					words[g + 3] = h
					count = count + 1
				end
			end
		end

		-- each cell's emitters are laid out together, in the order they came
		local cursor = 0

		for h = 0, capacity - 1 do
			local b = cells_base + h * CELL_WORDS

			if words[b + 4] > 0 then
				words[b + 3] = cursor
				cursor = cursor + words[b + 4]
				local power = floats[b + 5]
				floats[b + 6] = floats[b + 6] / power
				floats[b + 7] = floats[b + 7] / power
				floats[b + 8] = floats[b + 8] / power
			end
		end

		for i = 0, count - 1 do
			local g = emitters_base + i * EMITTER_WORDS
			local h = words[g + 3]
			local b = cells_base + h * CELL_WORDS
			local r = cell_emitters_base + (words[b + 3] + fill[h]) * CELL_EMITTER_WORDS
			fill[h] = fill[h] + 1
			running[h] = running[h] + floats[g + 2]
			words[r] = i
			floats[r + 1] = running[h] / floats[b + 5]
			floats[r + 2] = floats[g + 2]

			if fill[h] == words[b + 4] then floats[r + 1] = 1 end

			floats[g + 1] = floats[g + 1] / weight
		end

		if count > 0 then floats[emitters_base + (count - 1) * EMITTER_WORDS + 1] = 1 end

		words[0] = mask
		floats[1] = cell_size
		words[2] = cells_base
		words[3] = cell_emitters_base
		words[4] = emitters_base
		floats[5] = weight
		words[6] = count
		emitters.word_count = word_count
		emitters.count = count
		emitters.weight = weight
		emitters.cell_size = cell_size
		emitters.additive = additive
		emitters.excluded_count = excluded_count
		emitters.excluded_power = excluded_power
		emitters.soup_version = scene_bvh.soup_version
		emitters.top_version = scene_bvh.top_version
		emitters.version = emitters.version + 1
		return emitters
	end

	-- one host-visible copy per frame in flight
	function ddgi.GetEmitterBuffer()
		local emitters = ddgi.GetEmitters()
		local frame = render.GetCurrentFrame()
		local buffer = buffers[frame]
		local bytes = emitters.word_count * 4

		if not buffer or buffer:GetSize() < bytes then
			if buffer then buffer:Remove() end

			buffer = render.CreateBuffer{
				byte_size = bytes * 2,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_emitters",
				data = WordArray(emitters.word_count * 2),
			}
			buffers[frame] = buffer
			buffer_versions[frame] = nil
		end

		if buffer_versions[frame] ~= emitters.version then
			buffer:CopyData(emitters.words, bytes)
			buffer_versions[frame] = emitters.version
		end

		return buffer
	end
end

-- The per-material data read through the soup's material id, one
-- host-visible copy per pipeline (texture indices are per pipeline) and frame
-- in flight. scene_bvh.materials only grows, so an entry is only rewritten when
-- it is new, its material was stamped by InvalidateRayMaterial since, or the
-- pipeline freed a texture index that an entry may still hold.
local MaterialEntry = ffi.typeof([[struct {
	float albedo[3];
	int32_t albedo_tex;
	int32_t double_sided;
	int32_t terrain_tex;
	int32_t terrain_layer_tex[4];
	float terrain_bounds[3];
	float terrain_detail[4];
	float terrain_additive_detail[4];
	float alpha;
	float alpha_cutoff;
	int32_t alpha_test;
	int32_t glass;
	int32_t albedo2_tex;
	int32_t blend_tex;
}]])
local MaterialEntryArray = ffi.typeof("$[?]", MaterialEntry)
local MaterialEntryPointer = ffi.typeof("$*", MaterialEntry)
local MATERIAL_ENTRY_SIZE = ffi.sizeof(MaterialEntry)
local material_buffers = setmetatable({}, {__mode = "k"})

function ddgi.WriteMaterialBuffer(self)
	local frame = render.GetCurrentFrame()
	local materials = scene_bvh.materials
	local count = #materials
	material_buffers[self] = material_buffers[self] or {}
	local states = material_buffers[self]
	local state = states[frame]

	if not state or state.buffer:GetSize() < count * MATERIAL_ENTRY_SIZE then
		if state then state.buffer:Remove() end

		local capacity = math.max(count, 1) * 2
		state = {
			buffer = render.CreateBuffer{
				byte_size = capacity * MATERIAL_ENTRY_SIZE,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_materials",
				data = MaterialEntryArray(capacity),
			},
			written = 0,
			generation = 0,
			releases = -1,
		}
		states[frame] = state
	end

	local generation = Material.ray_material_generation
	local releases = self:GetTextureIndexReleases()
	local glass_enabled = glass_tint.IsSunThrough()

	if
		state.written == count and
		state.generation == generation and
		state.releases == releases and
		state.glass == glass_enabled
	then
		return state.buffer
	end

	local rewrite_all = state.releases ~= releases or state.glass ~= glass_enabled
	local written = state.written
	local stamp = state.generation
	local out = ffi.cast(MaterialEntryPointer, state.buffer:Map(0, state.buffer:GetSize()))

	for i = 1, count do
		local material = materials[i]

		if rewrite_all or i > written or material.ray_material_stamp > stamp then
			local entry = out[i - 1]
			local color = material:GetColorMultiplier()
			entry.albedo[0] = color.r
			entry.albedo[1] = color.g
			entry.albedo[2] = color.b
			local albedo = material:GetAlbedoTexture() or NULL
			entry.albedo_tex = albedo:IsValid() and self:GetTextureIndex(albedo) or -1
			entry.double_sided = material:GetDoubleSided() and 1 or 0
			entry.alpha = color.a
			entry.alpha_cutoff = material:GetAlphaCutoff()

			if not material:GetAlphaTest() then
				entry.alpha_test = 0
			else
				entry.alpha_test = material:HasShadowTexture() and 2 or 1
			end

			entry.glass = (glass_enabled and material:IsGlass()) and 1 or 0
			local albedo2 = material:GetAlbedo2Texture()
			entry.albedo2_tex = albedo2 and albedo2:IsValid() and self:GetTextureIndex(albedo2) or -1
			local blend_texture = material:GetBlendTexture()
			entry.blend_tex = blend_texture and
				blend_texture:IsValid() and
				self:GetTextureIndex(blend_texture) or
				-1
			local terrain = material:GetTerrainMaterialTexture()

			if terrain and terrain:IsValid() then
				entry.terrain_tex = self:GetTextureIndex(terrain)

				for layer = 1, 4 do
					local tex = material["GetTerrainLayer" .. layer .. "Texture"](material)
					entry.terrain_layer_tex[layer - 1] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
				end

				local bounds = material:GetTerrainBounds()
				entry.terrain_bounds[0] = bounds.x
				entry.terrain_bounds[1] = bounds.y
				entry.terrain_bounds[2] = 1 / bounds.z
				local detail = material:GetTerrainLayerDetailStrength()
				local additive = material:GetTerrainLayerAdditiveDetail()
				entry.terrain_detail[0] = detail.r
				entry.terrain_detail[1] = detail.g
				entry.terrain_detail[2] = detail.b
				entry.terrain_detail[3] = detail.a
				entry.terrain_additive_detail[0] = additive.r
				entry.terrain_additive_detail[1] = additive.g
				entry.terrain_additive_detail[2] = additive.b
				entry.terrain_additive_detail[3] = additive.a
			else
				entry.terrain_tex = -1
			end
		end
	end

	state.written = count
	state.generation = generation
	state.releases = releases
	state.glass = glass_enabled
	return state.buffer
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
	int32_t emitter_count;
	uint32_t frame;
	float light_radius;
	int32_t update_mask;
	int32_t uniform_rays;
	int32_t emitter_candidates;
	float emitter_grid;
}]]
	):format(ddgi.CASCADES, ddgi.CASCADES)
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
	p.max_ray_distance = max_ray_distance:Get()
	p.tmin = 0.0
	p.emitter_count = emitters_enabled:Get() and ddgi.GetEmitters().count or 0
	p.frame = state.frame
	p.light_radius = light_radius:Get()
	p.update_mask = state.update_mask
	p.uniform_rays = ddgi.GetUniformRays()
	p.emitter_candidates = emitter_candidates:Get()
	p.emitter_grid = emitter_grid:Get()
	return buffer
end

local payload_glsl = [[
struct Payload
{
    float hit_t;
    uint primitive;
    // 1 for the sun's shadow ray, which passes through glass (see ddgi_material.glass)
    uint sun;
};
]]
ddgi.SCENE_FLAGS_GLSL = ddgi.ALPHA_TEST and
	"#define DDGI_SCENE_FLAGS 0u\n" or
	"#define DDGI_SCENE_FLAGS gl_RayFlagsOpaqueEXT\n"
local raygen_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
]] .. ddgi.SCENE_FLAGS_GLSL .. ddgi.GetDefinesGLSL() .. [[
// see ddgi_guide_texel
layout(set = 0, binding = 4) uniform sampler2D guide;
#define DDGI_GUIDE_FETCH(texel) texelFetch(guide, texel, 0)
]] .. ddgi.GetRayDirectionGLSL() .. payload_glsl .. scene_bvh.GetDeclarationsGLSL(7, 5) .. ddgi.GetEmitterDeclarationsGLSL(6) .. ddgi.GetEmitterGLSL() .. [[
layout(set = 0, binding = 0) uniform Params
{
    // see ddgi_cascades and ddgi_cascade_size
    vec4 cascades[DDGI_CASCADES];
    vec4 size[DDGI_CASCADES];
    vec4 rotation;
    vec4 sun_direction;
    float max_ray_distance;
    float tmin;
    int emitter_count;
    uint frame;
    // in spacings, see ddgi_light_radius
    float light_radius;
    // bit c: cascade c traces this frame
    int update_mask;
    // rays of a probe that are not aimed by its guide
    int uniform_rays;
    // see ddgi_emitter_candidates
    int emitter_candidates;
    // see ddgi_emitter_grid
    float emitter_grid;
} params;
layout(set = 0, binding = 1) writeonly buffer Hits
{
    uvec2 hits[];
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

    if ((params.update_mask & (1 << c)) == 0) return;

    ivec3 n = ivec3(params.size[c].xyz);

    if (probe >= n.x * n.y * n.z) return;

    ivec3 base = ivec3(params.cascades[c].xyz);
    ivec3 slot = ivec3(probe % n.x, (probe / n.x) % n.y, probe / (n.x * n.y));
    ivec3 world = base + DDGI_WRAP(slot - DDGI_WRAP(base, n), n);
    ivec2 tile = ivec2(probe % (DDGI_P * DDGI_P), probe / (DDGI_P * DDGI_P) + DDGI_P * c);
    vec4 data = texelFetch(probe_data, tile, 0);
    bool current = data.w >= 1.0 && ivec3(round(data.xyz)) == world;
    vec3 origin = (current ? data.xyz : vec3(world)) * params.cascades[c].w;
    uint index = uint(probe + DDGI_P * DDGI_P * DDGI_P * c) * uint(DDGI_RAY_STRIDE) + ray;
    const uint shadow_flags = DDGI_SCENE_FLAGS | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT;

    // An emitter sample (see ddgi_pick_emitter_sample). Only the kept one is
    // traced. Stores the candidates' summed weight and which one was kept, or
    // a negative weight when it is blocked.
    if (ray >= DDGI_RAYS) {
        uvec2 result = uvec2(floatBitsToUint(-1.0), 0u);

        if (params.emitter_count > 0) {
            int kept_emitter;
            uint kept;
            vec3 kept_point;
            float weight_sum = ddgi_pick_emitter_sample(index, params.frame, params.emitter_count, uint(params.emitter_candidates), params.emitter_grid, origin, params.light_radius * params.cascades[c].w, kept_emitter, kept, kept_point);
            vec3 to_point = kept_point - origin;
            float dist = length(to_point);

            if (weight_sum > 0.0 && dist > DDGI_SHADOW_OFFSET) {
                payload.hit_t = 1.0;
                payload.sun = 0u;
                traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, origin, 0.0, to_point / dist, dist - DDGI_SHADOW_OFFSET, 0);

                if (payload.hit_t < 0.0) result = uvec2(floatBitsToUint(weight_sum), uint(kept_emitter) | (kept << DDGI_EMITTER_SHIFT));
            }
        }

        hits[index] = result;
        return;
    }

    vec3 dir = ddgi_ray_direction(ray, uint(params.uniform_rays), params.rotation, tile, ddgi_guide_valid(tile, world, c));
    payload.sun = 0u;
    traceRayEXT(scene, DDGI_SCENE_FLAGS, 0xFF, 0, 0, 0, origin, params.tmin, dir, params.max_ray_distance, 0);
    float hit_t = payload.hit_t;
    uint primitive = payload.primitive;

    // The sun's visibility from the hit, exact rather than from shadow maps
    // that only cover the view. The local lights get theirs in the shade pass
    // (see ddgi_direct_light). The shadow rays skip the closest hit shader, so
    // only a miss changes the payload.
    if (hit_t >= 0.0 && params.sun_direction.w > 0.0) {
        payload.hit_t = 1.0;
        payload.sun = 1u;
        traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, origin + dir * max(hit_t - DDGI_SHADOW_OFFSET, 0.0), 0.0, normalize(params.sun_direction.xyz), params.max_ray_distance, 0);

        if (payload.hit_t < 0.0) primitive |= DDGI_SUN_VISIBLE_BIT;
    }

    hits[index] = uvec2(floatBitsToUint(hit_t), primitive);
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
    // one instance per visual, its custom index is the visual's soup range start
    payload.primitive = uint(gl_InstanceCustomIndexEXT) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(gl_PrimitiveID);
}
]]

local function build_anyhit_glsl()
	return [[
#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 1, binding = 0) uniform sampler2D textures[]] .. render.GetBindlessDescriptorCapacities().textures .. [[];
#define TEXTURE(idx) textures[nonuniformEXT(idx)]
hitAttributeEXT vec2 barycentrics;
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;
]] .. scene_bvh.GetTriangleDeclarationGLSL(5) .. scene_bvh.GetUvDeclarationGLSL(8) .. ddgi.GetMaterialDeclarationsGLSL(9) .. ddgi.GetAlphaTestGLSL() .. [[

void main()
{
    // one instance per visual, its custom index is the visual's soup range start
    uint triangle = uint(gl_InstanceCustomIndexEXT) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(gl_PrimitiveID);

    // the sun's light goes on through glass, tinted by the lookup in the shade pass
    if (payload.sun != 0u && ddgi_materials[bvh_tri(triangle).material].glass != 0) ignoreIntersectionEXT;

    if (!ddgi_alpha_passes(triangle, barycentrics)) ignoreIntersectionEXT;
}
]]
end

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
		local stages = {
			{name = "raygeneration", code = raygen_glsl},
			{name = "closesthit", code = closesthit_glsl},
			{name = "miss", code = miss_glsl},
		}
		local bindings = {
			{binding_index = 0, type = "uniform_buffer", stageFlags = "all"},
			{binding_index = 1, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 2, type = "acceleration_structure_khr", stageFlags = "all"},
			{binding_index = 3, type = "combined_image_sampler", stageFlags = "all"},
			{binding_index = 4, type = "combined_image_sampler", stageFlags = "all"},
			{
				binding_index = 5,
				type = "storage_buffer",
				stageFlags = "all",
				count = scene_bvh.SOUP_CHUNKS,
			},
			{binding_index = 6, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 7, type = "storage_buffer", stageFlags = "all"},
		}

		if ddgi.ALPHA_TEST then
			stages[#stages + 1] = {name = "anyhit", code = build_anyhit_glsl()}
			bindings[#bindings + 1] = {
				binding_index = 8,
				type = "storage_buffer",
				stageFlags = "all",
				count = scene_bvh.SOUP_CHUNKS,
			}
			bindings[#bindings + 1] = {binding_index = 9, type = "storage_buffer", stageFlags = "all"}
		end

		rt_pipeline = RayTracingPipeline.New(
			render.GetDevice(),
			{
				stages = stages,
				bindless = ddgi.ALPHA_TEST,
				max_recursion_depth = 1,
				max_ray_payload_size = 12,
				DescriptorSetCount = render.GetSwapchainImageCount() * 16,
				descriptor_sets = {bindings},
			}
		)
	end

	return rt_pipeline
end

-- What the emitters are made of, to tell a crystal that is too bright from a
-- sampler that is too noisy. An emitter's radiance at a hit is emissive
-- multiplier x albedo x EMISSIVE_REFERENCE_LUMINANCE (cd/m2), capped at
-- EMISSIVE_MAX_LUMINANCE, see ddgi_emission.
commands.Add("ddgi_emitter_info", function()
	local emitters = ddgi.GetEmitters()
	logf(
		"ddgi emitters: %d triangles, total power %.4g, reference luminance %.0f, max %.0f\n",
		emitters.count,
		emitters.weight,
		render3d.EMISSIVE_REFERENCE_LUMINANCE,
		render3d.EMISSIVE_MAX_LUMINANCE
	)
	logf(
		"  left out as additive effects (ddgi_additive_emitters 0): %d triangles, power %.4g\n",
		emitters.excluded_count,
		emitters.excluded_power
	)
	local words = emitters.words
	local floats = ffi.cast("float*", words)
	local cells_base, cell_emitters_base, emitters_base = words[2], words[3], words[4]
	local occupied, largest, largest_power = 0, 0, 0

	for h = 0, words[0] do
		local b = cells_base + h * 10

		if words[b + 4] > 0 then
			occupied = occupied + 1
			largest = math.max(largest, words[b + 4])
			largest_power = math.max(largest_power, floats[b + 5])
		end
	end

	logf(
		"  grid: cell size %.2f m, %d cells hold emitters, most in one cell %d, most power in one cell %.4g\n",
		emitters.cell_size,
		occupied,
		largest,
		largest_power
	)
	local lowest, highest = math.huge, 0

	for i = 0, emitters.count - 1 do
		local power = floats[emitters_base + i * 4 + 2]
		lowest = math.min(lowest, power)
		highest = math.max(highest, power)
	end

	logf("  power per triangle: lowest %.4g, highest %.4g\n", lowest, highest)
	logf("  %d emissive blocks:\n", #scene_bvh.emissive_blocks)

	for i, block in ipairs(scene_bvh.emissive_blocks) do
		if i > 40 then
			logf("  ...\n")

			break
		end

		local power = 0

		for j = 0, block.emitter_count - 1 do
			power = power + block.emitters[j].power
		end

		logf(
			"  block %d%s: %d emitters, power %.4g, at %.1f %.1f %.1f\n",
			i,
			block.emitters[0].additive ~= 0 and not emitters.additive and " (left out)" or "",
			block.emitter_count,
			power,
			block.emitters[0].x,
			block.emitters[0].y,
			block.emitters[0].z
		)
		local seen = {}

		for _, slot in ipairs(block.slots) do
			if
				slot.emissive_r + slot.emissive_g + slot.emissive_b > 0 and
				not seen[slot.material_id]
			then
				seen[slot.material_id] = true
				local material = scene_bvh.materials[slot.material_id + 1]
				local color = material:GetColorMultiplier()
				logf(
					"    material '%s' (id %d): emissive x strength %.3f %.3f %.3f, colour %.2f %.2f %.2f, albedo texture %s, emissive texture %s, albedo alpha is emissive %s, additive %s\n",
					material:GetName(),
					slot.material_id,
					slot.emissive_r,
					slot.emissive_g,
					slot.emissive_b,
					color.r,
					color.g,
					color.b,
					tostring(material:GetAlbedoTexture() ~= nil),
					tostring(material:GetEmissiveTexture() ~= nil),
					tostring(material:GetAlbedoAlphaIsEmissive()),
					tostring(material:GetAdditive())
				)
			end
		end
	end
end)

commands.Add("ddgi_reset", function()
	ddgi.ResetHistory()
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
			"  cascade %d%s: spacing %.2f, updates every %d frames, %d x %d x %d probes (%d), spans %.1f %.1f %.1f m from %.1f %.1f %.1f\n",
			c - 1,
			c > state.cascade_count and " (unused)" or "",
			cascade.spacing,
			update_intervals[c]:Get(),
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

return ddgi
