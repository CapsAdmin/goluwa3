local ffi = require("ffi")
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local ddgi = library()
-- Dynamic diffuse global illumination (Majercik et al. 2019) over hardware ray
-- tracing. A camera-centred grid of probes each trace RAYS_PER_PROBE rays per
-- frame; the hits are shaded (direct light plus last frame's probe irradiance
-- for the infinite bounce) and blended into two octahedral atlases per probe:
-- irradiance, and the mean/mean^2 hit distance used for the Chebyshev
-- visibility test that keeps light from leaking through walls.
ddgi.enabled = true
ddgi.PROBES_PER_AXIS = 24
ddgi.PROBE_SPACING = 2.0
ddgi.RAYS_PER_PROBE = 128
-- octahedral tile sizes including the one texel border that makes bilinear
-- sampling wrap correctly across the octahedron's edges
ddgi.IRRADIANCE_TEXELS = 8
ddgi.DISTANCE_TEXELS = 16
ddgi.MAX_RAY_DISTANCE = 1000.0
ddgi.HYSTERESIS = 0.97
-- a texel whose irradiance changed by more than this fraction adapts faster
-- this frame
ddgi.IRRADIANCE_THRESHOLD = 1.0
-- sharpness of the cosine lobe the hit distances are averaged with
ddgi.DISTANCE_EXPONENT = 50.0
-- surface bias along the normal and towards the viewer, in probe spacings
ddgi.NORMAL_BIAS = 0.1
ddgi.VIEW_BIAS = 0.3
-- probes whose rays mostly hit back faces are inside geometry and are skipped
ddgi.BACKFACE_THRESHOLD = 0.25
ddgi.SKY_INTENSITY = 1.0
ddgi.RANDOM_ROTATION = true
ddgi.RESOLVE_SCALE = 1.0
-- stored in a ray's distance slot when it missed everything
ddgi.MISS_DISTANCE = 1e27

function ddgi.GetProbeCount()
	return ddgi.PROBES_PER_AXIS ^ 3
end

function ddgi.GetRayCount()
	return ddgi.GetProbeCount() * ddgi.RAYS_PER_PROBE
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

function ddgi.RTSupported()
	return render.GetDevice().ray_tracing_supported
end

function ddgi.ResetHistory()
	ddgi.force_reset = true
end

do
	local state = {
		frame = -1,
		volume_base = {x = 0, y = 0, z = 0},
		rotation = {x = 0, y = 0, z = 0, w = 1},
		reset = true,
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

	-- Everything the passes of one frame must agree on: where the volume is,
	-- how this frame's rays are rotated, and whether the probe history is
	-- garbage (fresh atlases) and must be overwritten instead of blended.
	function ddgi.GetFrameState()
		local frame = system.GetFrameNumber()

		if state.frame == frame then return state end

		state.frame = frame
		local position = render3d.GetRenderCamera():GetPosition()
		local spacing = ddgi.PROBE_SPACING
		local half = math.floor(ddgi.PROBES_PER_AXIS / 2)
		state.volume_base.x = math.floor(position.x / spacing) - half
		state.volume_base.y = math.floor(position.y / spacing) - half
		state.volume_base.z = math.floor(position.z / spacing) - half

		if ddgi.RANDOM_ROTATION then
			random_rotation(state.rotation)
		else
			state.rotation.x, state.rotation.y, state.rotation.z, state.rotation.w = 0, 0, 0, 1
		end

		local irradiance = render3d.pipelines.ddgi_irradiance
		local framebuffers = irradiance and irradiance.framebuffers
		state.reset = ddgi.force_reset or framebuffers ~= state.history_framebuffers
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
		#define DDGI_RAYS %d
		#define DDGI_IRRADIANCE_TEXELS %d
		#define DDGI_DISTANCE_TEXELS %d
		#define DDGI_MISS_DISTANCE %.1e
		#define DDGI_SUN_VISIBLE_BIT 0x80000000u
		#define DDGI_SHADOW_OFFSET 0.02
		// GLSL leaves %% undefined for negative operands (NVIDIA treats them
		// as unsigned), so shift into the positive range before wrapping
		#define DDGI_WRAP(v) (((v) + DDGI_P * 65536) %% DDGI_P)
	]]
	):format(
		ddgi.PROBES_PER_AXIS,
		ddgi.RAYS_PER_PROBE,
		ddgi.IRRADIANCE_TEXELS,
		ddgi.DISTANCE_TEXELS,
		ddgi.MISS_DISTANCE
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

-- Probe addressing. A probe is named by its integer world coordinate w (it
-- sits at w * spacing) and stored in slot w mod P, so when the volume scrolls
-- the probes that stay keep their slot and history; only the planes that
-- wrapped around land on a slot whose stored coordinate no longer matches.
function ddgi.GetCommonGLSL()
	return ddgi.GetDefinesGLSL() .. ddgi.GetRayDirectionGLSL() .. [[
		ivec3 ddgi_volume_base() {
			return ivec3(ddgi_data.ddgi_volume_base.xyz);
		}

		ivec3 ddgi_slot(ivec3 world) {
			return DDGI_WRAP(world);
		}

		int ddgi_probe_index(ivec3 slot) {
			return slot.x + DDGI_P * (slot.y + DDGI_P * slot.z);
		}

		ivec3 ddgi_slot_from_index(int index) {
			return ivec3(index % DDGI_P, (index / DDGI_P) % DDGI_P, index / (DDGI_P * DDGI_P));
		}

		// the probe of this frame's volume that is stored in slot
		ivec3 ddgi_world_from_slot(ivec3 slot) {
			ivec3 base = ddgi_volume_base();
			return base + DDGI_WRAP(slot - ddgi_slot(base));
		}

		ivec2 ddgi_tile(ivec3 slot) {
			return ivec2(slot.x + DDGI_P * slot.y, slot.z);
		}

		vec3 ddgi_probe_position(ivec3 world) {
			return vec3(world) * ddgi_data.ddgi_spacing;
		}

		bool ddgi_in_volume(vec3 P) {
			vec3 grid = P / ddgi_data.ddgi_spacing - vec3(ddgi_volume_base());
			return all(greaterThanEqual(grid, vec3(0.0))) && all(lessThanEqual(grid, vec3(DDGI_P - 1)));
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

		vec2 ddgi_atlas_uv(ivec3 slot, vec3 dir, int texels) {
			vec2 atlas_size = vec2(DDGI_P * DDGI_P * texels, DDGI_P * texels);
			vec2 oct = ddgi_oct_encode(dir) * 0.5 + 0.5;
			vec2 pixel = vec2(ddgi_tile(slot) * texels) + 1.0 + oct * float(texels - 2);
			return pixel / atlas_size;
		}

		// xyz = world coordinate last written into the slot, w = 1 + back face
		// ray fraction (0 when never written)
		vec4 ddgi_probe_data(ivec3 slot) {
			return texelFetch(TEXTURE(ddgi_data.ddgi_probe_data_tex), ddgi_tile(slot), 0);
		}

		bool ddgi_probe_is_current(vec4 data, ivec3 world) {
			return data.w >= 1.0 && ivec3(round(data.xyz)) == world;
		}

		vec3 ddgi_sky(vec3 dir) {
			return textureLod(
				TEXTURE(ddgi_data.ddgi_env_tex),
				dir_to_equirect_uv(correct_environment_lookup_dir(dir)),
				1.0
			).rgb * ddgi_data.ddgi_sky_intensity;
		}

		// Irradiance at P with normal N, seen from direction V (towards the
		// viewer). rgb = irradiance, a = sky visibility. weight is 0 when no
		// probe could contribute.
		vec4 ddgi_sample_irradiance(vec3 P, vec3 N, vec3 V, out float weight) {
			float spacing = ddgi_data.ddgi_spacing;
			vec3 biased = P + (N * ddgi_data.ddgi_normal_bias + V * ddgi_data.ddgi_view_bias) * spacing;
			vec3 grid = biased / spacing;
			ivec3 base_world = ivec3(floor(grid));
			vec3 alpha = grid - vec3(base_world);
			ivec3 volume_min = ddgi_volume_base();
			ivec3 volume_max = volume_min + DDGI_P - 1;
			vec4 sum = vec4(0.0);
			weight = 0.0;

			for (int i = 0; i < 8; i++) {
				ivec3 offset = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
				ivec3 world = base_world + offset;

				if (any(lessThan(world, volume_min)) || any(greaterThan(world, volume_max))) continue;

				ivec3 slot = ddgi_slot(world);
				vec4 data = ddgi_probe_data(slot);

				if (!ddgi_probe_is_current(data, world) || data.w - 1.0 > ddgi_data.ddgi_backface_threshold) continue;

				vec3 probe_pos = ddgi_probe_position(world);
				vec3 trilinear = mix(1.0 - alpha, alpha, vec3(offset));
				vec3 to_probe = normalize(probe_pos - P);
				float w = (dot(to_probe, N) + 1.0) * 0.5;
				w = w * w + 0.2;

				vec3 probe_to_point = biased - probe_pos;
				float dist = length(probe_to_point);
				vec2 moments = texture(
					TEXTURE(ddgi_data.ddgi_distance_tex),
					ddgi_atlas_uv(slot, probe_to_point / max(dist, 1e-4), DDGI_DISTANCE_TEXELS)
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

				w *= trilinear.x * trilinear.y * trilinear.z;
				sum += texture(
					TEXTURE(ddgi_data.ddgi_irradiance_tex),
					ddgi_atlas_uv(slot, N, DDGI_IRRADIANCE_TEXELS)
				) * w;
				weight += w;
			}

			return weight > 0.0 ? sum / weight : vec4(0.0);
		}
	]]
end

function ddgi.GetBlockLayout()
	return {
		render3d.camera_block,
		render3d.gbuffer_block,
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
		{"shadows", scene_lights.BuildShadowsBlockLayout()},
		light_occlusion.GetBlockLayout(),
		{"ddgi_volume_base", "vec4"},
		{"ddgi_rotation", "vec4"},
		{"ddgi_sun_direction", "vec4"},
		{"ddgi_sun_radiance", "vec4"},
		{"ddgi_spacing", "float"},
		{"ddgi_max_distance", "float"},
		{"ddgi_hysteresis", "float"},
		{"ddgi_irradiance_threshold", "float"},
		{"ddgi_distance_exponent", "float"},
		{"ddgi_normal_bias", "float"},
		{"ddgi_view_bias", "float"},
		{"ddgi_backface_threshold", "float"},
		{"ddgi_sky_intensity", "float"},
		{"ddgi_reset", "int"},
		{"ddgi_rt_ready", "int"},
		{"ddgi_env_tex", "int"},
		{"ddgi_env_irradiance_tex", "int"},
		{"ddgi_ray_tex", "int"},
		{"ddgi_irradiance_tex", "int"},
		{"ddgi_distance_tex", "int"},
		{"ddgi_probe_data_tex", "int"},
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
	local lights, light_instance_indices = scene_lights.GetVisibleLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	light_occlusion.WriteOcclusionBlock(block, lights, light_instance_indices)
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	local sun_color = directional_shadows.GetPrimarySunColor(lights)
	local sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
	sun_direction:CopyToFloatPointer(block.ddgi_sun_direction)
	block.ddgi_sun_direction[3] = 0
	block.ddgi_sun_radiance[0] = sun_color.x * sun_illuminance
	block.ddgi_sun_radiance[1] = sun_color.y * sun_illuminance
	block.ddgi_sun_radiance[2] = sun_color.z * sun_illuminance
	block.ddgi_sun_radiance[3] = 0
	block.ddgi_volume_base[0] = state.volume_base.x
	block.ddgi_volume_base[1] = state.volume_base.y
	block.ddgi_volume_base[2] = state.volume_base.z
	block.ddgi_volume_base[3] = 0
	block.ddgi_rotation[0] = state.rotation.x
	block.ddgi_rotation[1] = state.rotation.y
	block.ddgi_rotation[2] = state.rotation.z
	block.ddgi_rotation[3] = state.rotation.w
	block.ddgi_spacing = ddgi.PROBE_SPACING
	block.ddgi_max_distance = ddgi.MAX_RAY_DISTANCE
	block.ddgi_hysteresis = ddgi.HYSTERESIS
	block.ddgi_irradiance_threshold = ddgi.IRRADIANCE_THRESHOLD
	block.ddgi_distance_exponent = ddgi.DISTANCE_EXPONENT
	block.ddgi_normal_bias = ddgi.NORMAL_BIAS
	block.ddgi_view_bias = ddgi.VIEW_BIAS
	block.ddgi_backface_threshold = ddgi.BACKFACE_THRESHOLD
	block.ddgi_sky_intensity = ddgi.SKY_INTENSITY
	block.ddgi_reset = state.reset and 1 or 0
	block.ddgi_rt_ready = state.rt_ready and 1 or 0
	block.ddgi_env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.ddgi_env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	block.ddgi_ray_tex = pipeline_texture_index(self, "ddgi_shade")
	block.ddgi_irradiance_tex = pipeline_texture_index(self, "ddgi_irradiance")
	block.ddgi_distance_tex = pipeline_texture_index(self, "ddgi_distance")
	block.ddgi_probe_data_tex = pipeline_texture_index(self, "ddgi_probe_data")
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
local RTParams = ffi.typeof([[struct {
	int32_t volume_base[3];
	float probe_spacing;
	float rotation[4];
	float sun_direction[4];
	float max_ray_distance;
	float tmin;
	float padding[2];
}]])
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
	p.volume_base[0] = state.volume_base.x
	p.volume_base[1] = state.volume_base.y
	p.volume_base[2] = state.volume_base.z
	p.probe_spacing = ddgi.PROBE_SPACING
	p.rotation[0] = state.rotation.x
	p.rotation[1] = state.rotation.y
	p.rotation[2] = state.rotation.z
	p.rotation[3] = state.rotation.w
	local lights = scene_lights.GetVisibleLights()
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	p.sun_direction[0] = sun_direction.x
	p.sun_direction[1] = sun_direction.y
	p.sun_direction[2] = sun_direction.z
	p.sun_direction[3] = directional_shadows.GetPrimarySunIlluminance(lights) > 0 and 1 or 0
	p.max_ray_distance = ddgi.MAX_RAY_DISTANCE
	p.tmin = 0.0
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
]] .. ddgi.GetDefinesGLSL() .. ddgi.GetRayDirectionGLSL() .. payload_glsl .. [[
layout(set = 0, binding = 0) uniform Params
{
    ivec3 volume_base;
    float probe_spacing;
    vec4 rotation;
    vec4 sun_direction;
    float max_ray_distance;
    float tmin;
} params;
layout(set = 0, binding = 1) writeonly buffer Hits
{
    uvec2 hits[];
};
layout(set = 0, binding = 2) uniform accelerationStructureEXT scene;
layout(location = 0) rayPayloadEXT Payload payload;

void main()
{
    uint ray = gl_LaunchIDEXT.x;
    int probe = int(gl_LaunchIDEXT.y);
    ivec3 slot = ivec3(probe % DDGI_P, (probe / DDGI_P) % DDGI_P, probe / (DDGI_P * DDGI_P));
    ivec3 world = params.volume_base + DDGI_WRAP(slot - DDGI_WRAP(params.volume_base));
    vec3 origin = vec3(world) * params.probe_spacing;
    vec3 dir = ddgi_ray_direction(ray, params.rotation);
    traceRayEXT(scene, gl_RayFlagsOpaqueEXT, 0xFF, 0, 0, 0, origin, params.tmin, dir, params.max_ray_distance, 0);
    float hit_t = payload.hit_t;
    uint primitive = payload.primitive;

    // Sun visibility from the hit, exact rather than from shadow cascades that
    // only cover the view and let light into sealed rooms. The shadow ray
    // skips the closest hit shader, so only a miss changes the payload.
    if (hit_t >= 0.0 && params.sun_direction.w > 0.0) {
        vec3 hit_pos = origin + dir * max(hit_t - DDGI_SHADOW_OFFSET, 0.0);
        payload.hit_t = 1.0;
        traceRayEXT(
            scene,
            gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT,
            0xFF, 0, 0, 0,
            hit_pos, 0.0, normalize(params.sun_direction.xyz), params.max_ray_distance, 0
        );

        if (payload.hit_t < 0.0) primitive |= DDGI_SUN_VISIBLE_BIT;
    }

    hits[uint(probe) * uint(DDGI_RAYS) + ray] = uvec2(floatBitsToUint(hit_t), primitive);
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

commands.Add("ddgi_hysteresis=number[0.97]", function(value)
	ddgi.HYSTERESIS = value
end)

return ddgi
