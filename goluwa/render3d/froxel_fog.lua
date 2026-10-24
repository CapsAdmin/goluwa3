local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local froxel_fog = {}
froxel_fog.TILE = 6
froxel_fog.MAX_WIDTH = 480
froxel_fog.MAX_HEIGHT = 270
froxel_fog.SLICES = 96
froxel_fog.FAR = 100000
froxel_fog.DEPTH_KNEE = 2
local froxels = {width = 0, height = 0, current = 1, generation = 0}
froxel_fog.froxels = froxels

function froxel_fog.EnsureResources()
	local size = render.GetRenderImageSize()
	local tile = math.max(froxel_fog.TILE, size.x / froxel_fog.MAX_WIDTH, size.y / froxel_fog.MAX_HEIGHT)
	local width = math.ceil(size.x / tile)
	local height = math.ceil(size.y / tile)

	if froxels.width == width and froxels.height == height then return froxels end

	for _, key in ipairs{"raw", "scatter1", "scatter2"} do
		if froxels[key] then froxels[key]:Remove() end

		local depth = key == "raw" and 2 * froxel_fog.SLICES or froxel_fog.SLICES
		froxels[key] = Texture.New{
			width = width,
			height = height,
			format = "r16g16b16a16_sfloat",
			image = {
				image_type = "3d",
				depth = depth,
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

	if froxels.depth then froxels.depth:Remove() end

	froxels.depth = Texture.New{
		width = width,
		height = height,
		format = "r32_sfloat",
		image = {usage = {"storage", "sampled"}},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	froxels.depth:SetDebugName("render3d froxels depth")
	froxels.depth_sampler = render.CreateSampler(froxels.depth:GetSamplerConfig())
	if froxels.gi then froxels.gi:Remove() end

	froxels.gi = Texture.New{
		width = math.ceil(width / 2),
		height = math.ceil(height / 2),
		format = "r16g16b16a16_sfloat",
		image = {
			image_type = "3d",
			depth = froxel_fog.SLICES,
			usage = {"storage", "sampled"},
		},
		view = {view_type = "3d"},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	froxels.gi:SetDebugName("render3d froxels gi")
	froxels.gi_sampler = render.CreateSampler(froxels.gi:GetSamplerConfig())
	froxels.integrated = froxels.raw
	froxels.integrated_sampler = froxels.raw_sampler
	froxels.width = width
	froxels.height = height
	froxels.history_valid = false
	froxels.generation = froxels.generation + 1
	return froxels
end

function froxel_fog.GetScatterTexture(index)
	local key = "scatter" .. index
	return froxels[key], froxels[key .. "_sampler"]
end

function froxel_fog.GetVolumeDescriptor()
	froxel_fog.EnsureResources()
	return {froxels.integrated:GetView(), froxels.integrated_sampler}
end

function froxel_fog.BindVolume(pipeline, frame)
	froxel_fog.EnsureResources()

	if not pipeline.pipeline.descriptor_sets[frame] then frame = 1 end

	pipeline.froxel_generations = pipeline.froxel_generations or {}

	if pipeline.froxel_generations[frame] == froxels.generation then return end

	pipeline.froxel_generations[frame] = froxels.generation
	pipeline:UpdateDescriptorSet("combined_image_sampler", frame, 0, 2, froxels.integrated)
end

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

	float froxel_surface_limit(float surface_depth) {
		float s = froxel_slice_coord(surface_depth);
		return max(surface_depth - max(0.5 * (froxel_slice_depth(s + 1.0) - froxel_slice_depth(s)), 0.05), 0.0);
	}
]]
):format(froxel_fog.SLICES, froxel_fog.FAR, froxel_fog.DEPTH_KNEE)

function froxel_fog.GetViewDirGLSL(block)
	return [[

		vec3 get_view_dir(vec2 uv) {
			vec4 p = ]] .. block .. [[.inv_projection * vec4(uv * 2.0 - 1.0, 0.0, 1.0);
			return p.xyz / -p.z;
		}
	]]
end

function froxel_fog.GetPointGLSL(block)
	return screen_reconstruct.GetViewDepthGLSL(block) .. [[

		float froxel_surface_depth(vec2 uv) {
			float depth = textureLod(TEXTURE(]] .. block .. [[.depth_tex), uv, 0.0).r;
			float view_depth = depth > 0.0 ? get_view_depth(uv, depth) : 1e30;
			float air_distance = ]] .. block .. [[.ocean_distance_tex != -1 ? textureLod(TEXTURE(]] .. block .. [[.ocean_distance_tex), uv, 0.0).g : -1.0;
			return air_distance >= 0.0 ? min(view_depth, air_distance / length(get_view_dir(uv))) : view_depth;
		}

		float froxel_point(ivec3 id, vec2 uv, float depth, float pick, out vec2 point_uv) {
			point_uv = uv;
			float surface_depth = froxel_surface_depth(uv);

			if (depth > surface_depth && pick >= 0.0) {
				int i = int(pick * 4.0);
				vec2 corner_uv = (vec2(id.xy) + vec2(i & 1, i >> 1) * 0.8 + 0.1) / ]] .. block .. [[.froxel_size;
				float corner_depth = froxel_surface_depth(corner_uv);

				if (corner_depth > surface_depth) {
					surface_depth = corner_depth;
					point_uv = corner_uv;
				}
			} else if (depth > surface_depth) {
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

function froxel_fog.GetGLSL(block)
	return [[

		void froxel_sample(vec2 uv, float s, out vec4 front, out vec4 back) {
			float z = clamp(s - 0.5, 0.5, FROXEL_SLICES - 0.5);
			float front_z = z / (2.0 * FROXEL_SLICES);
			float back_z = (FROXEL_SLICES + z) / (2.0 * FROXEL_SLICES);
			vec2 size = vec2(textureSize(froxel_volume, 0).xy);
			vec2 p = uv * size - 0.5;
			vec2 base = floor(p);
			vec2 f = p - base;
			front = vec4(0.0);
			back = vec4(0.0);
			float total = 0.0;

			for (int i = 0; i < 4; i++) {
				vec2 corner = vec2(i & 1, i >> 1);
				vec2 column = (clamp(base + corner, vec2(0.0), size - 1.0) + 0.5) / size;
				vec4 f_sample = textureLod(froxel_volume, vec3(column, front_z), 0.0);
				vec2 w2 = mix(1.0 - f, f, corner);
				float weight = w2.x * w2.y * f_sample.a;
				front += f_sample * weight;
				back += textureLod(froxel_volume, vec3(column, back_z), 0.0) * weight;
				total += weight;
			}

			if (total > 1e-3) {
				front /= total;
				back /= total;
			} else {
				front = textureLod(froxel_volume, vec3(uv, front_z), 0.0);
				back = textureLod(froxel_volume, vec3(uv, back_z), 0.0);
			}
		}

		vec3 get_volumetric_fog(vec2 uv, float hit_distance, out vec3 transmittance) {
			vec3 view_dir = get_view_dir(uv);
			float ray_scale = length(view_dir);
			float s = froxel_slice_coord(hit_distance < 0.0 ? FROXEL_FAR : min(hit_distance / ray_scale, FROXEL_FAR));
			float near = clamp(s, 0.0, 1.0);
			vec4 front, back;
			froxel_sample(uv, s, front, back);
			transmittance = mix(vec3(1.0), back.rgb, near);
			return front.rgb * near;
		}

		float get_fog_layer_transmittance(vec2 uv, float hit_distance) {
			float ray_scale = length(get_view_dir(uv));
			float s = froxel_slice_coord(hit_distance < 0.0 ? FROXEL_FAR : min(hit_distance / ray_scale, FROXEL_FAR));
			vec4 front, back;
			froxel_sample(uv, s, front, back);
			return mix(1.0, back.a, clamp(s, 0.0, 1.0));
		}
	]]
end

return froxel_fog
