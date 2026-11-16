local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local froxel_fog = import("goluwa/render3d/froxel_fog.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local medium_lighting = import("goluwa/render3d/medium_lighting.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local fluid_volume_passes = {}
fluid_volume_passes.MAX_STEPS = 96
fluid_volume_passes.STEP_CELLS = 0.75
local LOCAL_LIGHT_LIMIT = 4
local BINDING_SCATTER = 0
local BINDING_TRANSMITTANCE = 1
local BINDING_DATA = 4
local BINDING_LIGHT_GRID = 7
local BINDING_GI = 10
local BINDING_GI_EMITTER = 14
fluid_volume_passes.BINDING_RECORDS = 16
fluid_volume_passes.BINDING_FIELDS = 17
fluid_volume_passes.BINDING_LIGHT = 18
fluid_volume_passes.BINDING_SLOT_DEPTH = 19
fluid_volume_passes.BINDING_SLOT_VISIBILITY = 20
local view = {}

local function ensure_view_textures()
	local size = render3d.GetRenderSize()

	if view.width == size.x and view.height == size.y then return view end

	for _, key in ipairs{"scatter", "transmittance"} do
		if view[key] then view[key]:Remove() end

		view[key] = Texture.New{
			width = size.x,
			height = size.y,
			format = "r16g16b16a16_sfloat",
			image = {usage = {"storage", "sampled"}},
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		view[key]:SetDebugName("fluid view " .. key)
	end

	view.width = size.x
	view.height = size.y
	return view
end

function fluid_volume_passes.GetViewTextures()
	ensure_view_textures()
	return view.scatter, view.transmittance
end

local function atlas_descriptor(key)
	return function()
		local texture = fluid_volumes.GetAtlas()[key]
		return {
			texture:GetView(),
			texture.sampler or
			render.CreateSampler(texture:GetSamplerConfig()),
		}
	end
end

function fluid_volume_passes.GetSampledImages()
	return {
		{
			binding_index = fluid_volume_passes.BINDING_SLOT_DEPTH,
			get_descriptor = atlas_descriptor("slot_depth"),
		},
		{
			binding_index = fluid_volume_passes.BINDING_SLOT_VISIBILITY,
			get_descriptor = atlas_descriptor("slot_visibility"),
		},
		{
			binding_index = fluid_volume_passes.BINDING_FIELDS,
			get_descriptor = function()
				local atlas = fluid_volumes.GetAtlas()
				return {
					atlas.fields:GetView(),
					atlas.fields.sampler or
					render.CreateSampler(atlas.fields:GetSamplerConfig()),
				}
			end,
		},
		{
			binding_index = fluid_volume_passes.BINDING_LIGHT,
			get_descriptor = function()
				local atlas = fluid_volumes.GetAtlas()
				return {
					atlas.light:GetView(),
					atlas.light.sampler or
					render.CreateSampler(atlas.light:GetSamplerConfig()),
				}
			end,
		},
	}
end

function fluid_volume_passes.BindRecords(self, desc)
	local buffer = fluid_volumes.GetRecordBuffer()
	self:UpdateDescriptorSet(
		"storage_buffer",
		desc,
		fluid_volume_passes.BINDING_RECORDS,
		0,
		buffer,
		buffer:GetSize()
	)
end

function fluid_volume_passes.GetDeclarationGLSL()
	return fluid_volumes.GetDeclarationGLSL(
		fluid_volume_passes.BINDING_RECORDS,
		fluid_volume_passes.BINDING_FIELDS,
		fluid_volume_passes.BINDING_LIGHT,
		fluid_volume_passes.BINDING_SLOT_DEPTH,
		fluid_volume_passes.BINDING_SLOT_VISIBILITY
	)
end

fluid_volume_passes.simulate = {
	name = "fluid_volumes_simulate",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"fluid_dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 1, y = 1, z = 1},
	on_draw = function(self, cmd)
		fluid_volumes.Simulate(cmd)
	end,
	shader = [[
		void main() {}
	]],
}
local sampled_images = fluid_volume_passes.GetSampledImages()
list.insert(
	sampled_images,
	{
		binding_index = BINDING_GI,
		get_descriptor = function()
			froxel_fog.EnsureResources()
			return {froxel_fog.froxels.gi:GetView(), froxel_fog.froxels.gi_sampler}
		end,
	}
)
list.insert(
	sampled_images,
	{
		binding_index = BINDING_GI_EMITTER,
		get_descriptor = function()
			froxel_fog.EnsureResources()
			return {froxel_fog.froxels.gi_emitter:GetView(), froxel_fog.froxels.gi_emitter_sampler}
		end,
	}
)
fluid_volume_passes.view = {
	name = "fluid_volumes_view",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"fluid_view_dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {
		{
			binding_index = BINDING_SCATTER,
			dst_stage = "fragment",
			get_texture = function()
				return ensure_view_textures().scatter
			end,
		},
		{
			binding_index = BINDING_TRANSMITTANCE,
			dst_stage = "fragment",
			get_texture = function()
				return ensure_view_textures().transmittance
			end,
		},
	},
	sampled_images = sampled_images,
	uniform_buffers = {
		{
			name = "fluid_data",
			binding_index = BINDING_DATA,
			block = {
				render3d.camera_block,
				gbuffer_layout.block,
				post_source.pre_exposure_block,
				{"froxel_size", "vec2"},
				{"frame", "int"},
				{"water_distance_tex", "int"},
				{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
				{"light_count", "int"},
				{"shadows", scene_lights.BuildShadowsBlockLayout()},
				atmosphere.GetBlockLayout(),
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				post_source.WritePreExposureBlock(self, block)
				block.froxel_size[0] = froxel_fog.froxels.width
				block.froxel_size[1] = froxel_fog.froxels.height
				block.frame = system.GetFrameNumber()

				if
					render3d.IsWaterEnabled() and
					render3d.IsPassEnabled("water") and
					render3d.pipelines.water.framebuffers
				then
					block.water_distance_tex = self:GetTextureIndex(render3d.pipelines.water:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(2))
				else
					block.water_distance_tex = -1
				end

				medium_lighting.WriteLightsBlock(self, block)
				return block
			end,
		},
	},
	storage_buffers = {
		{binding_index = BINDING_LIGHT_GRID},
		{binding_index = fluid_volume_passes.BINDING_RECORDS},
	},
	on_pre_draw = function(self, cmd, frame, desc)
		froxel_fog.EnsureResources()
		light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
		fluid_volume_passes.BindRecords(self, desc)
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		if not fluid_volumes.HasRaymarched() then return end

		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, view.width, view.height, 1, desc, self.dynamic_offsets)
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_SCATTER .. [[, rgba16f) uniform writeonly image2D out_scatter;
		layout(set = 0, binding = ]] .. BINDING_TRANSMITTANCE .. [[, rgba16f) uniform writeonly image2D out_transmittance;
		layout(set = 0, binding = ]] .. BINDING_GI .. [[) uniform sampler3D froxel_gi;
		layout(set = 0, binding = ]] .. BINDING_GI_EMITTER .. [[) uniform sampler3D froxel_gi_emitter;
	]] .. light_grid.GetGLSL(BINDING_LIGHT_GRID) .. fluid_volume_passes.GetDeclarationGLSL(),
	shader = glsl_common.GetHashGLSL() .. glsl_common.GetConstantsGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("fluid_data") .. screen_reconstruct.GetViewDepthGLSL("fluid_data") .. post_source.GetPreExposureGLSL("fluid_data") .. scene_lights.GetLightGLSLCode() .. medium_lighting.GetSunHelpersGLSL("fluid_data") .. atmosphere.GetGLSLDefines("fluid_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. fluid_volumes.GetGLSL() .. [[
		float get_medium_light_visibility(int i, lights_t light, vec3 world_pos, vec3 L) {
			return 1.0;
		}
	]] .. medium_lighting.GetLocalLightsGLSL(
			"fluid_data",
			LOCAL_LIGHT_LIMIT,
			{
				visibility = false,
				name = "get_fluid_light_scattering",
				params = "float g, fluid_record fv, vec4 slot_depth, vec4 slot_visibility",
				attenuation = "fluid_light_slot_transmittance(fv, slot_depth, slot_visibility, i)",
			}
		) .. froxel_fog.GetSliceGLSL("fluid_data") .. froxel_fog.GetViewDirGLSL("fluid_data") .. [[
		#define FLUID_MAX_STEPS ]] .. fluid_volume_passes.MAX_STEPS .. [[

		#define FLUID_STEP_CELLS ]] .. string.format("%.4f", fluid_volume_passes.STEP_CELLS) .. [[

		shared vec3 shared_sky_ambient;

		vec3 fluid_ambient(vec2 uv, float view_depth) {
			ivec3 size = textureSize(froxel_gi, 0);
			ivec3 id = ivec3(ivec2(uv * fluid_data.froxel_size) >> 1, int(froxel_slice_coord(view_depth)));
			id = clamp(id, ivec3(0), size - 1);
			vec4 gi = texelFetch(froxel_gi, id, 0);
			float open_sky = gi.a < 0.0 ? 1.0 : gi.a;
			vec3 probe = gi.a < 0.0 ? shared_sky_ambient : gi.rgb;
			return mix(probe, shared_sky_ambient, open_sky) + texelFetch(froxel_gi_emitter, id, 0).rgb;
		}

		void main() {
			if (gl_LocalInvocationIndex == 0u) {
				shared_sky_ambient = ATMOSPHERE_ENABLED != 0 ? get_ground_fog_sky_ambient(get_atmosphere_camera_origin(fluid_data.camera_position.xyz)) : vec3(0.0);
			}

			barrier();

			ivec2 id = ivec2(gl_GlobalInvocationID.xy);
			ivec2 size = imageSize(out_scatter);

			if (any(greaterThanEqual(id, size))) return;

			vec2 uv = (vec2(id) + 0.5) / vec2(size);
			vec3 view_dir = get_view_dir(uv);
			float ray_scale = length(view_dir);
			vec3 ray_dir = normalize(mat3(fluid_data.inv_view) * view_dir);
			vec3 origin = fluid_data.camera_position.xyz;
			ivec2 depth_size = textureSize(TEXTURE(fluid_data.depth_tex), 0);
			float depth = gbuffer_depth(clamp(ivec2(uv * vec2(depth_size)), ivec2(0), depth_size - 1));
			float hit = depth > 0.0 ? get_view_depth(uv, depth) * ray_scale : 1e30;

			if (fluid_data.water_distance_tex != -1) {
				float air_distance = textureLod(TEXTURE(fluid_data.water_distance_tex), uv, 0.0).b;

				if (air_distance >= 0.0) hit = min(hit, air_distance);
			}

			float entries[]] .. fluid_volumes.MAX_VOLUMES .. [[];
			float exits[]] .. fluid_volumes.MAX_VOLUMES .. [[];
			int order[]] .. fluid_volumes.MAX_VOLUMES .. [[];
			int count = 0;

			for (int i = 0; i < fluid_counts.x; i++) {
				fluid_record v = fluid_records[i];

				if (v.mode != FLUID_MODE_RAYMARCH) continue;

				float t0;
				float t1;

				if (!medium_box_intersect(v.to_local, -v.half_size, v.half_size, origin, ray_dir, t0, t1)) continue;

				t0 = max(t0, 0.0);
				t1 = min(t1, hit);

				if (t1 <= t0) continue;

				int k = count;

				while (k > 0 && entries[k - 1] > t0) {
					entries[k] = entries[k - 1];
					exits[k] = exits[k - 1];
					order[k] = order[k - 1];
					k--;
				}

				entries[k] = t0;
				exits[k] = t1;
				order[k] = i;
				count++;
			}

			if (count == 0) {
				imageStore(out_scatter, id, vec4(0.0, 0.0, 0.0, -1.0));
				imageStore(out_transmittance, id, vec4(1.0));
				return;
			}

			vec3 sun_dir = get_current_primary_sun_direction();
			float mu = dot(ray_dir, sun_dir);
			vec3 sun = vec3(0.0);

			if (ATMOSPHERE_ENABLED != 0) {
				vec3 point = get_atmosphere_camera_origin(origin + ray_dir * entries[0]);
				sun = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(point, sun_dir) * get_ground_fog_sun_transmittance(point, sun_dir);
			}

			uvec3 h = pcg3d(uvec3(id, uint(fluid_data.frame)));
			float jitter = pcg_unorm(h.x);
			vec3 scattered = vec3(0.0);
			vec3 transmittance = vec3(1.0);
			float depth_sum = 0.0;
			float weight_sum = 0.0;

			for (int k = 0; k < count; k++) {
				int index = order[k];
				fluid_record v = fluid_records[index];
				float t0 = entries[k];
				float t1 = exits[k];
				int steps = clamp(int(ceil((t1 - t0) / (v.cell * FLUID_STEP_CELLS))), 4, FLUID_MAX_STEPS);
				float dt = (t1 - t0) / float(steps);
				vec3 local_origin = (v.to_local * vec4(origin, 1.0)).xyz;
				vec3 local_dir = (v.to_local * vec4(ray_dir, 0.0)).xyz;
				vec3 ambient = fluid_ambient(uv, 0.5 * (t0 + t1) / ray_scale);
				vec3 volume_sun = sun * fluid_sun_transmittance(origin + ray_dir * (0.5 * (t0 + t1)), sun_dir, index, -1);
				vec3 extinction_unit = v.absorption + v.scattering;

				for (int s = 0; s < steps; s++) {
					float t = t0 + (float(s) + jitter) * dt;
					vec3 local = local_origin + local_dir * t;
					vec3 uvw = fluid_atlas_uvw(v, local);
					vec4 f = textureLod(fluid_fields_atlas, uvw, 0.0);
					float edge = fluid_edge(v, local);
					float smoke = f.x * edge;
					float flame = f.w * edge;
					vec3 extinction = smoke * extinction_unit + flame * v.flame_absorption;

					if (max(extinction.x, max(extinction.y, extinction.z)) < 1e-5) continue;

					vec4 l = textureLod(fluid_light_atlas, uvw, 0.0);
					vec4 slot_depth = textureLod(fluid_slot_depth_atlas, uvw, 0.0);
					vec4 slot_visibility = textureLod(fluid_slot_visibility_atlas, uvw, 0.0);
					vec3 world = origin + ray_dir * t;
					vec3 lit = volume_sun * l.z * fluid_sun_phase(v, l, mu) + ambient * fluid_ambient_transmittance(v, l) + get_fluid_light_scattering(ray_dir, world, v.g, v, slot_depth, slot_visibility);
					vec3 source = smoke * v.scattering * lit + (smoke * v.absorption + flame * v.flame_absorption) * fluid_emission(f.y);
					vec3 step_transmittance = exp(-extinction * dt);
					scattered += transmittance * (source - source * step_transmittance) / max(extinction, vec3(1e-6));
					float before = dot(transmittance, vec3(1.0 / 3.0));
					transmittance *= step_transmittance;
					float weight = before - dot(transmittance, vec3(1.0 / 3.0));
					depth_sum += weight * t;
					weight_sum += weight;
				}

				if (max(transmittance.x, max(transmittance.y, transmittance.z)) < 0.002) break;
			}

			float fluid_depth = weight_sum > 1e-5 ? depth_sum / weight_sum : -1.0;
			imageStore(out_scatter, id, vec4(min(scattered * get_pre_exposure(), vec3(65000.0)), fluid_depth));
			imageStore(out_transmittance, id, vec4(transmittance, 1.0));
		}
	]],
}
return fluid_volume_passes
