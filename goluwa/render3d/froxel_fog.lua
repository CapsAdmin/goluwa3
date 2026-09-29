local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local froxel_fog = library()
-- The low altitude fog and the air up to FAR meters of view depth, in a
-- volume of TILE pixel cells, SLICES deep, that passes/volumetric_fog.lua
-- lights and integrates. Slices are thin near the camera and grow with
-- distance. FAR reaches as far as the sun's shadow map, so everything that
-- casts a shadow into the air does so here; beyond it the rest of the ray is
-- integrated analytically and fully lit.
froxel_fog.TILE = 8
froxel_fog.SLICES = 96
froxel_fog.FAR = 3000
-- slices are roughly linear up to this many meters and exponential beyond
froxel_fog.DEPTH_KNEE = 2
local froxels = {width = 0, height = 0, current = 1}
froxel_fog.froxels = froxels

function froxel_fog.EnsureResources()
	local size = render.GetRenderImageSize()
	local width = math.ceil(size.x / froxel_fog.TILE)
	local height = math.ceil(size.y / froxel_fog.TILE)

	if froxels.width == width and froxels.height == height then return froxels end

	for _, key in ipairs{"raw", "scatter1", "scatter2"} do
		if froxels[key] then froxels[key]:Remove() end

		froxels[key] = Texture.New{
			width = width,
			height = height,
			format = "r16g16b16a16_sfloat",
			image = {
				image_type = "3d",
				depth = froxel_fog.SLICES,
				usage = {"storage", "sampled"},
			},
			view = {view_type = "3d"},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
				wrap_r = "clamp_to_edge",
			},
		}
		froxels[key]:SetDebugName("render3d froxels " .. key)
		froxels[key .. "_sampler"] = render.CreateSampler(froxels[key]:GetSamplerConfig())
	end

	froxels.integrated = froxels.raw
	froxels.integrated_sampler = froxels.raw_sampler
	froxels.width = width
	froxels.height = height
	froxels.history_valid = false
	return froxels
end

function froxel_fog.GetScatterTexture(index)
	local key = "scatter" .. index
	return froxels[key], froxels[key .. "_sampler"]
end

-- the integrated volume a pass samples as froxel_volume, for a
-- combined_image_sampler descriptor's args
function froxel_fog.GetVolumeDescriptor()
	froxel_fog.EnsureResources()
	return {froxels.integrated:GetView(), froxels.integrated_sampler}
end

-- slice coordinate s (slice k spans [k, k + 1)) <-> view depth in meters
froxel_fog.SLICE_GLSL = (
	[[
	const float FROXEL_SLICES = %d.0;
	const float FROXEL_FAR = %.1f;
	const float FROXEL_DEPTH_KNEE = %.1f;

	float froxel_slice_depth(float s) {
		return FROXEL_DEPTH_KNEE * (pow(1.0 + FROXEL_FAR / FROXEL_DEPTH_KNEE, s / FROXEL_SLICES) - 1.0);
	}

	float froxel_slice_coord(float depth) {
		return FROXEL_SLICES * log(1.0 + depth / FROXEL_DEPTH_KNEE) / log(1.0 + FROXEL_FAR / FROXEL_DEPTH_KNEE);
	}

	// how deep a froxel's point may go in front of a surface at surface_depth:
	// half a slice short of it. Right against the surface the sun's shadow
	// map can't tell the point from the surface, so points in front of a wall
	// facing away from the sun would be lit by the light on its other side.
	float froxel_surface_limit(float surface_depth) {
		float s = froxel_slice_coord(surface_depth);
		return max(surface_depth - max(0.5 * (froxel_slice_depth(s + 1.0) - froxel_slice_depth(s)), 0.05), 0.0);
	}
]]
):format(froxel_fog.SLICES, froxel_fog.FAR, froxel_fog.DEPTH_KNEE)

function froxel_fog.GetViewDirGLSL(block)
	return [[
		// view space direction through uv, scaled to a view depth of 1
		vec3 get_view_dir(vec2 uv) {
			vec4 p = ]] .. block .. [[.inv_projection * vec4(uv * 2.0 - 1.0, 0.0, 1.0);
			return p.xyz / -p.z;
		}
	]]
end

-- froxel_point(id, uv, depth, out point_uv): the view depth and the uv the
-- froxel id stands for at view depth depth, sampled through uv. block holds
-- render3d.camera_block, gbuffer_layout.block, froxel_size and
-- ocean_distance_tex; SLICE_GLSL and GetViewDirGLSL come before it
function froxel_fog.GetPointGLSL(block)
	return [[
		// view depth of the surface seen through uv, the ocean's included
		float froxel_surface_depth(vec2 uv) {
			float depth = textureLod(TEXTURE(]] .. block .. [[.depth_tex), uv, 0.0).r;
			vec4 surface = ]] .. block .. [[.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
			float view_depth = depth < 1.0 ? -surface.z / surface.w : 1e30;
			float ocean_distance = ]] .. block .. [[.ocean_distance_tex != -1 ? textureLod(TEXTURE(]] .. block .. [[.ocean_distance_tex), uv, 0.0).r : -1.0;
			return ocean_distance > 0.0 ? min(view_depth, ocean_distance / length(get_view_dir(uv))) : view_depth;
		}

		// A froxel spans several pixels that see surfaces at different
		// depths. When the pixel at uv can't see the point (it is behind its
		// surface), the point is taken on the ray of the froxel's pixel that
		// sees furthest instead: past a leaf, the mountain's pixels see the
		// air there, and along a wall the pixels further down it. No pixel
		// sees past the furthest surface, and a point reaching past it would
		// bring the light on its other side to the pixels in front of it, so
		// such points are lit in front of it.
		float froxel_point(ivec3 id, vec2 uv, float depth, out vec2 point_uv) {
			point_uv = uv;
			float surface_depth = froxel_surface_depth(uv);

			if (depth > surface_depth) {
				for (int i = 0; i < 4; i++) {
					vec2 corner_uv = (vec2(id.xy) + vec2(i & 1, i >> 1) * 0.8 + 0.1) / ]] .. block .. [[.froxel_size;
					float corner_depth = froxel_surface_depth(corner_uv);

					if (corner_depth > surface_depth) {
						surface_depth = corner_depth;
						point_uv = corner_uv;
					}
				}
			}

			return min(depth, froxel_surface_limit(surface_depth));
		}
	]]
end

-- get_volumetric_fog(uv, hit_distance): the fog in front of the point
-- hit_distance meters along the ray through uv, or all of it along the ray
-- when hit_distance is negative (the sky). rgb is the light it scatters
-- toward the camera, a how much of what is behind it comes through.
-- block holds render3d.camera_block, atmosphere's block and gi_screen_tex;
-- the atmosphere defines, SLICE_GLSL, GetViewDirGLSL and a sampler3D
-- froxel_volume come before it. sun_dir_expr is the sun's direction
function froxel_fog.GetGLSL(block, sun_dir_expr)
	return [[
		vec4 get_volumetric_fog(vec2 uv, float hit_distance) {
			vec3 view_dir = get_view_dir(uv);
			vec3 ray_dir = normalize(mat3(]] .. block .. [[.inv_view) * view_dir);
			// meters along the ray per meter of view depth
			float ray_scale = length(view_dir);
			bool is_sky = hit_distance < 0.0;
			float s = froxel_slice_coord(is_sky ? FROXEL_FAR : min(hit_distance / ray_scale, FROXEL_FAR));
			// texel k holds the fog from the camera to the far side of slice k
			vec4 near_fog = textureLod(froxel_volume, vec3(uv, max(s - 0.5, 0.5) / FROXEL_SLICES), 0.0);
			near_fog = mix(vec4(0.0, 0.0, 0.0, 1.0), near_fog, clamp(s, 0.0, 1.0));
			float scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			float froxel_end = FROXEL_FAR * ray_scale * scale;
			vec3 fog_origin = get_atmosphere_camera_origin(]] .. block .. [[.camera_position.xyz);
			float fog_near;
			float fog_length;

			if (
				(is_sky || hit_distance * scale > froxel_end) &&
				get_scenery_fog_segment_with_ground_clip(fog_origin, ray_dir, is_sky ? -1.0 : hit_distance * scale, is_sky, fog_near, fog_length) &&
				fog_near + fog_length > froxel_end
			) {
				fog_length += fog_near - max(fog_near, froxel_end);
				fog_near = max(fog_near, froxel_end);
				vec3 sun_dir = ]] .. sun_dir_expr .. [[;
				vec4 gi = is_sky || ]] .. block .. [[.gi_screen_tex < 0 ? vec4(0.0, 0.0, 0.0, 1.0) : texture(TEXTURE(]] .. block .. [[.gi_screen_tex), uv);
				// past the sun's shadow map
				float sun_visibility = get_fog_sun_horizon_visibility(sun_dir) <= 0.0001 ? 0.0 : 1.0;
				vec4 far_fog = integrate_scenery_fog_segment(fog_origin, ray_dir, fog_near, fog_length, sun_dir, sun_visibility, gi.rgb, clamp(gi.a, 0.0, 1.0));
				return vec4(far_fog.rgb * near_fog.a + near_fog.rgb, far_fog.a * near_fog.a);
			}

			return near_fog;
		}
	]]
end

return froxel_fog
