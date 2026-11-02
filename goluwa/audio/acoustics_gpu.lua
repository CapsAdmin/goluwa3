local ffi = require("ffi")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local acoustics_gpu = {}
local MAX_SOURCES = 8
local MAX_QUERIES = 2048
local MAX_RAYS = 4096
local MAX_SAMPLES = 512
local MAX_MATERIALS = 8192
local GROUP_SIZE = 64
local STATS_FLOATS = 38
local SOURCE_FLOATS = 9
local ACC = STATS_FLOATS + SOURCE_FLOATS * MAX_SOURCES
local SAMPLE_FLOATS = acoustics.SAMPLE_FLOATS
local RAY_FLOATS = acoustics.RAY_FLOATS
local MATERIAL_ROWS = 4
local BINDING_UNIFORM = 0
local BINDING_QUERIES = 1
local BINDING_OUTPUT = 2
local BINDING_MATERIALS = 3
local BINDING_TLAS = 4
local BINDING_HIT = 5
local MAX_GROUPS = MAX_RAYS / GROUP_SIZE
local QUERY_FLOATS = acoustics.QUERY_FLOATS
local QUERY_INPUT_FLOATS = acoustics.QUERY_INPUT_FLOATS
local SAMPLE_BASE = MAX_GROUPS * ACC
local QUERY_BASE = SAMPLE_BASE + MAX_SAMPLES * SAMPLE_FLOATS
local RAY_BASE = QUERY_BASE + MAX_QUERIES * QUERY_FLOATS
local OUTPUT_FLOATS = RAY_BASE + MAX_RAYS * RAY_FLOATS
local float_ptr = ffi.typeof("float *")

local function glsl_vec3(t)
	return ("vec3(%f, %f, %f)"):format(t[1], t[2], t[3])
end

local function build_pipeline(slots)
	local default = acoustics.DEFAULT_MATERIAL
	local frequencies = {}

	for i, f in ipairs(acoustics.BAND_FREQUENCIES) do
		frequencies[i] = ("%f"):format(f)
	end

	return EasyPipeline.Compute{
		name = "audio_acoustics_trace",
		DescriptorSetCount = slots,
		LocalSize = {x = GROUP_SIZE, y = 1, z = 1},
		storage_buffers = {
			{binding_index = BINDING_QUERIES},
			{binding_index = BINDING_OUTPUT},
			{binding_index = BINDING_MATERIALS},
		},
		descriptor_sets = hit.GetDescriptorSets(BINDING_HIT, "compute", BINDING_TLAS),
		uniform_buffers = {
			{
				name = "acoustic",
				binding_index = BINDING_UNIFORM,
				block = {
					{"listener", "vec4"},
					{"rotation", "vec4", 3},
					{"sources", "vec4", MAX_SOURCES},
					{"air", "vec4"},
					{"timing", "vec4"},
					{"params", "vec4"},
					{"rain_up", "vec4"},
					{"upwind", "vec4"},
					{"limits", "vec4"},
					{"snow", "vec4"},
					{"counts", "ivec4"},
					{"extra", "ivec4"},
				},
				write = function(self, block)
					local job = acoustics_gpu.current_job
					local tracer = acoustics_gpu.current_tracer
					local l = job.listener
					block.listener[0], block.listener[1], block.listener[2], block.listener[3] = l.x, l.y, l.z, acoustics.LISTENER_CLEARANCE
					local m = job.rotation

					for row = 0, 2 do
						block.rotation[row][0] = m[row * 3 + 1]
						block.rotation[row][1] = m[row * 3 + 2]
						block.rotation[row][2] = m[row * 3 + 3]
						block.rotation[row][3] = 0
					end

					for i = 0, MAX_SOURCES - 1 do
						local source = job.sources[i + 1]

						if source then
							block.sources[i][0], block.sources[i][1], block.sources[i][2] = source.x, source.y, source.z
							block.sources[i][3] = job.direct_time[i + 1]
						end
					end

					for b = 0, 2 do
						block.air[b] = acoustics.AirEnergyPerMeter(b + 1)
					end

					block.air[3] = acoustics.SURFACE_OFFSET
					block.timing[0] = job.split_time
					block.params[0] = job.speed
					block.params[1] = acoustics.OPEN_DISTANCE
					block.params[2] = acoustics.SOURCE_CLEARANCE
					block.params[3] = acoustics.TRACE_DISTANCE
					local up = job.rain_up
					block.rain_up[0], block.rain_up[1], block.rain_up[2], block.rain_up[3] = up.x, up.y, up.z, job.gather and 1 or 0
					local upwind = job.upwind
					block.upwind[0] = upwind and upwind.x or 0
					block.upwind[1] = upwind and upwind.y or 0
					block.upwind[2] = upwind and upwind.z or 0
					block.upwind[3] = upwind and 1 or 0
					block.limits[0] = acoustics.WALL_SEARCH
					block.limits[1] = acoustics.LEAF_STEP
					block.limits[2] = acoustics.WIND_SHELTER
					block.limits[3] = acoustics.MIN_SCATTER_PROBABILITY
					local cover = job.snow_cover
					block.snow[0], block.snow[1], block.snow[2], block.snow[3] = cover[1], cover[2], cover[3], acoustics.SNOW_MIN_SLOPE
					block.counts[0] = job.rays
					block.counts[1] = job.bounces
					block.counts[2] = math.min(job.sample_count, job.rays)
					block.counts[3] = #job.sources
					block.extra[0] = job.query_count
					block.extra[1] = job.seed
					block.extra[2] = tracer.material_count
					block.extra[3] = acoustics.GATHER_WALL_BOUNCES
					return block
				end,
			},
		},
		custom_declarations = hit.GetSceneGLSL("acoustic_scene", BINDING_TLAS) .. hit.GetGLSL(BINDING_HIT) .. (
				[[
			layout(set = 0, binding = %d) readonly buffer AcousticQueries { vec4 queries[]; };
			layout(set = 0, binding = %d) buffer AcousticOutput { float result[]; };
			layout(set = 0, binding = %d) readonly buffer AcousticMaterials { vec4 acoustic_materials[]; };
		]]
			):format(BINDING_QUERIES, BINDING_OUTPUT, BINDING_MATERIALS),
		shader = hit.GetTraceGLSL("acoustic_scene") .. (
				[[
			#define ACC %d
			#define STATS_FLOATS %d
			#define SOURCE_FLOATS %d
			#define GROUP_SIZE %d
			#define SAMPLE_FLOATS %d
			#define QUERY_FLOATS %d
			#define RAY_FLOATS %d
			#define SAMPLE_BASE %d
			#define QUERY_BASE %d
			#define RAY_BASE %d
			#define MAX_LEAVES %d
			#define RHO_C %f
			#define RHO_C2 %f
			#define MIN_COS %f
			#define DEFAULT_ABSORPTION %s
			#define DEFAULT_SCATTERING %s
			#define DEFAULT_RAIN %s
			#define DEFAULT_WIND %s
			#define DEFAULT_DENSITY %f
			#define DEFAULT_SURFACE_MASS %f
			#define SNOW_ABSORPTION %s
			#define SNOW_SCATTERING %s
			#define SNOW_RAIN %s
			#define PI 3.14159265359

			const float BAND_FREQUENCIES[9] = float[9](%s);
			shared float reduce_buffer[GROUP_SIZE];

			uint acoustic_hash(uint x) {
				x ^= x >> 16u;
				x *= 0x7feb352du;
				x ^= x >> 15u;
				x *= 0x846ca68bu;
				x ^= x >> 16u;
				return x;
			}

			float acoustic_random(inout uint state) {
				state = acoustic_hash(state);
				return float(state >> 8u) / 16777216.0;
			}

			vec3 acoustic_cosine(vec3 n, float u1, float u2) {
				float r = sqrt(u1);
				float phi = 6.283185307 * u2;
				vec3 t = abs(n.x) > 0.5 ? vec3(-n.y, n.x, 0.0) : vec3(0.0, -n.z, n.y);
				t = normalize(t);
				vec3 b = cross(n, t);
				return t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1.0 - u1));
			}

			struct acoustic_material {
				vec3 absorption;
				vec3 scattering;
				vec3 rain;
				vec3 wind;
				float density;
				float surface_mass;
			};

			acoustic_material acoustic_material_of(uint instance) {
				uint row = scene_instance_material(instance);
				acoustic_material m;

				if (row >= uint(acoustic.extra.z)) {
					m.absorption = DEFAULT_ABSORPTION;
					m.scattering = DEFAULT_SCATTERING;
					m.rain = DEFAULT_RAIN;
					m.wind = DEFAULT_WIND;
					m.density = DEFAULT_DENSITY;
					m.surface_mass = DEFAULT_SURFACE_MASS;
					return m;
				}

				vec4 a = acoustic_materials[row * 4u];
				vec4 b = acoustic_materials[row * 4u + 1u];
				m.absorption = a.xyz;
				m.density = a.w;
				m.scattering = b.xyz;
				m.surface_mass = b.w;
				m.rain = acoustic_materials[row * 4u + 2u].xyz;
				m.wind = acoustic_materials[row * 4u + 3u].xyz;
				return m;
			}

			float acoustic_limp(float f, float m, float c) {
				float x = PI * f * m * c / RHO_C;
				return 1.0 / (1.0 + x * x);
			}

			vec3 acoustic_chain(int count, float mass[MAX_LEAVES], float cosines[MAX_LEAVES], float gaps[MAX_LEAVES], float speed) {
				vec3 bands = vec3(0.0);

				for (int b = 0; b < 3; b++) {
					float sum = 0.0;

					for (int k = 0; k < 3; k++) {
						float f = BAND_FREQUENCIES[b * 3 + k];
						float c = max(cosines[0], MIN_COS);
						float total = mass[0];
						float tau = acoustic_limp(f, total, c);

						for (int i = 1; i < count; i++) {
							c = max(cosines[i], MIN_COS);
							float m = mass[i];
							float combined = tau * acoustic_limp(f, total + m, c) / acoustic_limp(f, total, c);
							float gap = gaps[i];

							if (gap > 0.0 && total > 0.0 && m > 0.0 && f > sqrt(RHO_C2 * (total + m) / (gap * total * m)) / (2.0 * PI)) {
								float coupling = min(4.0 * PI * f * gap / speed, 2.0);
								tau = min(tau * acoustic_limp(f, m, c) / (coupling * coupling), combined);
							} else {
								tau = combined;
							}

							total += m;
						}

						sum += tau;
					}

					bands[b] = sum / 3.0;
				}

				return bands;
			}

			struct acoustic_wall {
				vec3 tau;
				vec3 exit_normal;
				vec3 rain;
				float solid;
				float exit_t;
				bool found;
			};

			acoustic_wall acoustic_transmit(vec3 origin, vec3 dir, float tmin, float tmax) {
				float mass[MAX_LEAVES];
				float cosines[MAX_LEAVES];
				float gaps[MAX_LEAVES];
				float step_size = acoustic.limits.y;
				int count = 0;
				float t = tmin;
				float last_end = tmin;
				acoustic_wall wall;
				wall.solid = 0.0;
				wall.exit_t = 0.0;
				wall.exit_normal = vec3(0.0);
				wall.rain = vec3(0.0);
				wall.found = false;
				scene_trace_hit h;
				scene_trace_hit back;

				while (count < MAX_LEAVES && t < tmax) {
					if (!scene_trace(origin, dir, t, tmax, h)) break;

					acoustic_material material = acoustic_material_of(h.instance);
					float m = material.surface_mass;
					float e = h.distance;
					vec3 exit_normal = -h.normal;
					vec3 rain = material.rain;

					if (h.front_face && scene_trace(origin, dir, h.distance + step_size, tmax, back) && !back.front_face) {
						e = back.distance;
						m = material.density * (back.distance - h.distance);
						wall.solid += back.distance - h.distance;
						exit_normal = -back.normal;
						rain = acoustic_material_of(back.instance).rain;
					}

					mass[count] = m;
					cosines[count] = abs(dot(h.normal, dir));
					gaps[count] = h.distance - last_end;
					count++;
					last_end = e;
					t = e + step_size;
					wall.exit_t = e;
					wall.exit_normal = exit_normal;
					wall.rain = rain;
					wall.found = true;
				}

				wall.tau = count == 0 ? vec3(1.0) : acoustic_chain(count, mass, cosines, gaps, acoustic.params.x);
				return wall;
			}

			void acoustic_gather_surface(acoustic_material material, vec3 position, vec3 n, vec3 scale, inout vec3 rain, inout vec3 wind) {
				vec3 p = position + n * acoustic.air.w;
				vec3 up = acoustic.rain_up.xyz;
				float flux = dot(n, up);

				if (flux > 0.0 && dot(material.rain, vec3(1.0)) > 0.0 && !scene_occluded(p, up, 0.0, acoustic.params.y)) {
					rain += scale * material.rain * flux;
				}

				if (acoustic.upwind.w > 0.0 && dot(material.wind, vec3(1.0)) > 0.0 && !scene_occluded(p, acoustic.upwind.xyz, 0.0, acoustic.limits.z)) {
					wind += scale * material.wind;
				}
			}

			void acoustic_gather_escape(vec3 dir, vec3 scale, inout vec3 rain) {
				if (dot(dir, acoustic.rain_up.xyz) < 0.0) rain += scale * DEFAULT_RAIN;
			}

			void acoustic_gather_wall(vec3 p, vec3 dir, vec3 w, inout vec3 rain, inout vec3 wind) {
				acoustic_wall wall = acoustic_transmit(p, dir, 0.0, acoustic.limits.x);

				if (!wall.found) return;

				vec3 scale = w * wall.tau;
				vec3 exit_point = p + dir * wall.exit_t;
				vec3 up = acoustic.rain_up.xyz;
				float flux = dot(wall.exit_normal, up);

				if (flux > 0.0 && !scene_occluded(exit_point + wall.exit_normal * acoustic.air.w, up, 0.0, acoustic.params.y)) {
					rain += scale * wall.rain * flux;
				}

				scene_trace_hit beyond;

				if (scene_trace(p, dir, wall.exit_t + acoustic.limits.y, acoustic.params.w, beyond) && beyond.distance <= acoustic.params.y) {
					acoustic_gather_surface(acoustic_material_of(beyond.instance), p + dir * beyond.distance, beyond.normal, scale, rain, wind);
				} else {
					acoustic_gather_escape(dir, scale, rain);
				}
			}

			void main() {
				uint id = gl_GlobalInvocationID.x;
				uint lid = gl_LocalInvocationID.x;
				int ray_count = acoustic.counts.x;
				uint ray_groups = uint((ray_count + GROUP_SIZE - 1) / GROUP_SIZE);
				scene_trace_hit hit;

				if (gl_WorkGroupID.x >= ray_groups) {
					uint q = id - ray_groups * uint(GROUP_SIZE);

					if (q >= uint(acoustic.extra.x)) return;

					vec4 a = queries[q * 3u];
					vec4 b = queries[q * 3u + 1u];
					vec4 c = queries[q * 3u + 2u];
					vec4 r = vec4(-1.0, 0.0, 0.0, 0.0);
					vec3 absorption = vec3(0.0);
					float scattering = 0.0;
					vec3 tau = vec3(1.0);
					float solid = 0.0;

					if (b.w > a.w && scene_trace(a.xyz, b.xyz, a.w, b.w, hit)) {
						acoustic_material material = acoustic_material_of(hit.instance);
						r = vec4(hit.distance, hit.normal);
						absorption = material.absorption;
						scattering = material.scattering.y;

						if (c.x != 0.0) {
							acoustic_wall wall = acoustic_transmit(a.xyz, b.xyz, a.w, b.w);
							tau = wall.tau;
							solid = wall.solid;
						}
					}

					uint at = QUERY_BASE + q * uint(QUERY_FLOATS);
					result[at] = r.x;
					result[at + 1u] = r.y;
					result[at + 2u] = r.z;
					result[at + 3u] = r.w;
					result[at + 4u] = absorption.x;
					result[at + 5u] = absorption.y;
					result[at + 6u] = absorption.z;
					result[at + 7u] = scattering;
					result[at + 8u] = tau.x;
					result[at + 9u] = tau.y;
					result[at + 10u] = tau.z;
					result[at + 11u] = solid;
					return;
				}

				float acc[ACC];

				for (int i = 0; i < ACC; i++) acc[i] = 0.0;

				if (int(id) < ray_count) {
					float speed = acoustic.params.x;
					float open_distance = acoustic.params.y;
					float clearance = acoustic.params.z;
					float trace_distance = acoustic.params.w;
					float offset = acoustic.air.w;
					float min_p = acoustic.limits.w;
					bool gather = acoustic.rain_up.w > 0.0;
					vec3 air = acoustic.air.xyz;
					int source_count = acoustic.counts.w;
					int settled_bounce = acoustic.counts.y / 2;
					float z = 1.0 - 2.0 * (float(id) + 0.5) / float(ray_count);
					float rr = sqrt(max(0.0, 1.0 - z * z));
					float phi = float(id) * 2.399963229728653;
					vec3 local_dir = vec3(cos(phi) * rr, sin(phi) * rr, z);
					vec3 dir = vec3(dot(acoustic.rotation[0].xyz, local_dir), dot(acoustic.rotation[1].xyz, local_dir), dot(acoustic.rotation[2].xyz, local_dir));
					vec3 origin = acoustic.listener.xyz;
					float tmin = acoustic.listener.w;
					float path_length = 0.0;
					vec3 w = vec3(1.0);
					vec3 rain = vec3(0.0);
					vec3 wind = vec3(0.0);
					vec3 escape_point = vec3(0.0);
					vec3 escape_w = vec3(0.0);
					bool escaped = false;
					uint rng = acoustic_hash(id * 9781u + uint(acoustic.extra.y));
					acc[0] = 1.0;

					for (int bounce = 0; bounce < acoustic.counts.y; bounce++) {
						bool found = scene_trace(origin, dir, tmin, trace_distance, hit);
						float distance = found ? hit.distance : -1.0;

						if (bounce == 0) {
							float d = found ? min(distance, open_distance) : open_distance;
							acc[4] += 4.18879020479 * d * d * d;
						}

						if (!found || distance > open_distance) {
							acc[2] += 1.0;
							escaped = true;

							vec3 rain_before = rain;

							if (gather) acoustic_gather_escape(dir, w, rain);

							if (bounce >= settled_bounce) {
								acc[29] += rain.x - rain_before.x;
								acc[30] += rain.y - rain_before.y;
								acc[31] += rain.z - rain_before.z;
								acc[35] += w.x;
								acc[36] += w.y;
								acc[37] += w.z;
							}

							escape_point = origin;
							escape_w = w;
							break;
						}

						acoustic_material material = acoustic_material_of(hit.instance);
						vec3 n = hit.normal;
						vec3 hit_point = origin + dir * distance;

						if (acoustic.snow.z > 0.0 && n.y > acoustic.snow.w && !scene_occluded(hit_point + n * offset, vec3(0.0, 1.0, 0.0), 0.0, open_distance)) {
							material.absorption = mix(material.absorption, SNOW_ABSORPTION, acoustic.snow.xyz);
							material.scattering = mix(material.scattering, SNOW_SCATTERING, acoustic.snow.xyz);
							material.rain = mix(material.rain, SNOW_RAIN, acoustic.snow.xyz);
						}

						vec3 absorption = material.absorption;
						vec3 scattering = material.scattering;

						if (bounce == 0 && int(id) < acoustic.counts.z) {
							uint s = SAMPLE_BASE + id * uint(SAMPLE_FLOATS);
							result[s] = hit_point.x;
							result[s + 1u] = hit_point.y;
							result[s + 2u] = hit_point.z;
							result[s + 3u] = n.x;
							result[s + 4u] = n.y;
							result[s + 5u] = n.z;
							result[s + 6u] = distance;
							result[s + 7u] = abs(dot(n, dir));
							result[s + 8u] = absorption.x;
							result[s + 9u] = absorption.y;
							result[s + 10u] = absorption.z;
							result[s + 11u] = scattering.x;
							result[s + 12u] = scattering.y;
							result[s + 13u] = scattering.z;
						}

						vec3 rain_before = rain;
						vec3 wind_before = wind;

						if (gather) {
							acoustic_gather_surface(material, hit_point, n, w, rain, wind);

							if (bounce < acoustic.extra.w && rain.y == rain_before.y) {
								acoustic_gather_wall(hit_point + n * offset, dir, w, rain, wind);
							}
						}

						acc[1] += 1.0;
						acc[3] += distance;
						path_length += distance;
						vec3 p = hit_point + n * offset;
						bool settled = bounce >= settled_bounce;

						if (settled) {
							acc[8] += w.x;
							acc[9] += w.y;
							acc[10] += w.z;
							acc[23] += w.x * distance;
							acc[24] += w.y * distance;
							acc[25] += w.z * distance;
							acc[26] += w.x * path_length;
							acc[27] += w.y * path_length;
							acc[28] += w.z * path_length;
							acc[29] += rain.x - rain_before.x;
							acc[30] += rain.y - rain_before.y;
							acc[31] += rain.z - rain_before.z;
							acc[32] += wind.x - wind_before.x;
							acc[33] += wind.y - wind_before.y;
							acc[34] += wind.z - wind_before.z;

							if (bounce == settled_bounce) {
								acc[17] += w.x;
								acc[18] += w.y;
								acc[19] += w.z;
							}

							if (bounce == acoustic.counts.y - 1) {
								acc[20] += w.x;
								acc[21] += w.y;
								acc[22] += w.z;
							}
						}

						vec3 reflect = vec3(1.0) - absorption;
						vec3 log_reflect = log(max(reflect, vec3(1e-6)));
						acc[5] += log_reflect.x;
						acc[6] += log_reflect.y;
						acc[7] += log_reflect.z;

						for (int s = 0; s < source_count; s++) {
							vec4 source = acoustic.sources[s];
							vec3 to_source = source.xyz - p;
							float d2 = dot(to_source, to_source);
							float d = sqrt(d2);
							float cos_s = dot(to_source, n) / max(d, 1e-6);

							if (cos_s > 0.0 && d > clearance && !scene_occluded(p, to_source / d, 0.0, d - clearance)) {
								float total = path_length + d;
								float t = total / speed - source.w;
								vec3 e = (4.0 * cos_s / max(d2, 0.01)) * w * reflect * exp(-air * total);
								int base = STATS_FLOATS + s * SOURCE_FLOATS;

								if (settled) {
									acc[base] += e.x;
									acc[base + 1] += e.y;
									acc[base + 2] += e.z;
								}

								if (bounce > 0 && t > acoustic.timing.x) {
									acc[base + 3] += e.x;
									acc[base + 4] += e.y;
									acc[base + 5] += e.z;
									acc[base + 6] += e.x * t;
									acc[base + 7] += e.y * t;
									acc[base + 8] += e.z * t;
								}
							}
						}

						w *= reflect;
						origin = p;
						tmin = 0.0;
						float probability = clamp(scattering.y, min_p, 1.0 - min_p);

						if (acoustic_random(rng) < probability) {
							float u1 = acoustic_random(rng);
							float u2 = acoustic_random(rng);
							dir = acoustic_cosine(n, u1, u2);
							w *= scattering / probability;
						} else {
							dir -= 2.0 * dot(dir, n) * n;
							w *= (vec3(1.0) - scattering) / (1.0 - probability);
						}
					}

					if (!escaped) {
						acc[11] += w.x;
						acc[12] += w.y;
						acc[13] += w.z;
						acc[14] += w.x * path_length;
						acc[15] += w.y * path_length;
						acc[16] += w.z * path_length;
					}

					uint ray_at = RAY_BASE + id * uint(RAY_FLOATS);
					result[ray_at] = rain.x;
					result[ray_at + 1u] = rain.y;
					result[ray_at + 2u] = rain.z;
					result[ray_at + 3u] = wind.x;
					result[ray_at + 4u] = wind.y;
					result[ray_at + 5u] = wind.z;
					result[ray_at + 6u] = escape_point.x;
					result[ray_at + 7u] = escape_point.y;
					result[ray_at + 8u] = escape_point.z;
					result[ray_at + 9u] = escape_w.x;
					result[ray_at + 10u] = escape_w.y;
					result[ray_at + 11u] = escape_w.z;
				}

				for (int f = 0; f < ACC; f++) {
					reduce_buffer[lid] = acc[f];
					barrier();

					for (uint stride = uint(GROUP_SIZE) / 2u; stride > 0u; stride >>= 1u) {
						if (lid < stride) reduce_buffer[lid] += reduce_buffer[lid + stride];
						barrier();
					}

					if (lid == 0u) result[gl_WorkGroupID.x * uint(ACC) + uint(f)] = reduce_buffer[0];
					barrier();
				}
			}
		]]
			):format(
				ACC,
				STATS_FLOATS,
				SOURCE_FLOATS,
				GROUP_SIZE,
				SAMPLE_FLOATS,
				QUERY_FLOATS,
				RAY_FLOATS,
				SAMPLE_BASE,
				QUERY_BASE,
				RAY_BASE,
				acoustics.MAX_LEAVES,
				acoustics.RHO_C,
				acoustics.RHO_C2,
				math.cos(acoustics.MAX_INCIDENCE),
				glsl_vec3(default.absorption),
				glsl_vec3(default.scattering),
				glsl_vec3(default.rain),
				glsl_vec3(default.wind),
				default.density,
				default.surface_mass,
				glsl_vec3(acoustics.SNOW.absorption),
				glsl_vec3(acoustics.SNOW.scattering),
				glsl_vec3(acoustics.SNOW.rain),
				table.concat(frequencies, ", ")
			),
	}
end

local META = {}
META.__index = META

function META:IsReady()
	return true
end

function META:Submit(job)
	self.pending = job
end

function META:Collect()
	local done = self.done

	if #done == 0 then return done end

	self.done = {}
	return done
end

function META:Probe(listener, source, speed)
	if self.cpu then return self.cpu:Probe(listener, source, speed) end
end

function META:GetSlot(index)
	local slot = self.slots[index]

	if slot then return slot end

	slot = {
		queries = render.CreateBuffer{
			byte_size = MAX_QUERIES * QUERY_INPUT_FLOATS * 4,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "audio_acoustics queries",
		},
		output = render.CreateBuffer{
			byte_size = OUTPUT_FLOATS * 4,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent", "host_cached"},
			label = "audio_acoustics output",
		},
		materials = render.CreateBuffer{
			byte_size = MAX_MATERIALS * MATERIAL_ROWS * 16,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "audio_acoustics materials",
		},
	}
	self.slots[index] = slot
	return slot
end

function META:UploadMaterials(slot)
	local count = math.min(#materials.list, MAX_MATERIALS)
	local out = ffi.cast(float_ptr, slot.materials:Map())

	for i = 0, count - 1 do
		local material = materials.list[i + 1]
		local a = material:GetAcousticAbsorption()
		local s = material:GetAcousticScattering()
		local r = material:GetAcousticRainEmission()
		local w = material:GetAcousticWindEmission()
		local at = i * MATERIAL_ROWS * 4
		out[at], out[at + 1], out[at + 2], out[at + 3] = a.x, a.y, a.z, material:GetAcousticDensity()
		out[at + 4], out[at + 5], out[at + 6], out[at + 7] = s.x, s.y, s.z, material:GetAcousticSurfaceMass()
		out[at + 8], out[at + 9], out[at + 10], out[at + 11] = r.x, r.y, r.z, 0
		out[at + 12], out[at + 13], out[at + 14], out[at + 15] = w.x, w.y, w.z, 0
	end

	self.material_count = count
end

function META:ReadResult(job, slot)
	local out = ffi.cast(float_ptr, slot.output:Map())
	local result = acoustics.NewResult(job)
	local stats = result.stats
	local groups = math.ceil(job.rays / GROUP_SIZE)

	for g = 0, groups - 1 do
		local at = g * ACC
		stats.rays = stats.rays + out[at]
		stats.hits = stats.hits + out[at + 1]
		stats.escapes = stats.escapes + out[at + 2]
		stats.segment = stats.segment + out[at + 3]
		stats.volume = stats.volume + out[at + 4]

		for b = 1, 3 do
			stats.log_reflect[b] = stats.log_reflect[b] + out[at + 4 + b]
			stats.settled_throughput[b] = stats.settled_throughput[b] + out[at + 7 + b]
			stats.last_throughput[b] = stats.last_throughput[b] + out[at + 10 + b]
			stats.last_throughput_length[b] = stats.last_throughput_length[b] + out[at + 13 + b]
			stats.settled_first[b] = stats.settled_first[b] + out[at + 16 + b]
			stats.settled_final[b] = stats.settled_final[b] + out[at + 19 + b]
			stats.settled_length[b] = stats.settled_length[b] + out[at + 22 + b]
			stats.settled_path[b] = stats.settled_path[b] + out[at + 25 + b]
			stats.settled_rain[b] = stats.settled_rain[b] + out[at + 28 + b]
			stats.settled_wind[b] = stats.settled_wind[b] + out[at + 31 + b]
			stats.settled_escape[b] = stats.settled_escape[b] + out[at + 34 + b]
		end

		for s = 1, #job.sources do
			local sums = result.sources[s]
			local base = at + STATS_FLOATS + (s - 1) * SOURCE_FLOATS

			for b = 1, 3 do
				sums.settled[b] = sums.settled[b] + out[base + b - 1]
				sums.late[b] = sums.late[b] + out[base + 2 + b]
				sums.moment[b] = sums.moment[b] + out[base + 5 + b]
			end
		end
	end

	local samples = result.samples

	for i = 0, math.min(job.sample_count, job.rays) - 1 do
		local at = SAMPLE_BASE + i * SAMPLE_FLOATS

		if out[at + 6] > 0 then
			for k = 0, SAMPLE_FLOATS - 1 do
				samples[#samples + 1] = out[at + k]
			end
		end
	end

	local queries = result.queries

	for i = 0, job.query_count * QUERY_FLOATS - 1 do
		queries[i + 1] = out[QUERY_BASE + i]
	end

	local rays = result.rays

	for i = 0, job.rays * RAY_FLOATS - 1 do
		rays[i + 1] = out[RAY_BASE + i]
	end

	return result
end

function META:Dispatch(cmd)
	local index = render.GetCurrentFrame() or 1
	local slot = self:GetSlot(index)
	local inflight = self.inflight[index]

	if inflight then
		self.inflight[index] = nil
		self.done[#self.done + 1] = {job = inflight, result = self:ReadResult(inflight, slot)}
	end

	local job = self.pending

	if not job then return end

	self.pending = nil
	job.rays = math.min(job.rays, MAX_RAYS)
	job.sample_count = math.min(job.sample_count, MAX_SAMPLES)
	job.query_count = math.min(job.query_count, MAX_QUERIES)

	for i = #job.sources, MAX_SOURCES + 1, -1 do
		job.sources[i] = nil
		job.sounds[i] = nil
	end

	local q = ffi.cast(float_ptr, slot.queries:Map())

	for i = 0, job.query_count * QUERY_INPUT_FLOATS - 1 do
		q[i] = job.queries[i + 1]
	end

	local out = ffi.cast(float_ptr, slot.output:Map())

	for i = 0, math.min(job.sample_count, job.rays) - 1 do
		out[SAMPLE_BASE + i * SAMPLE_FLOATS + 6] = -1
	end

	self:UploadMaterials(slot)
	local tlas = rt.GetTLAS(cmd)
	local pipeline = self.pipeline
	pipeline:UpdateDescriptorSet("storage_buffer", index, BINDING_QUERIES, 0, slot.queries, slot.queries:GetSize())
	pipeline:UpdateDescriptorSet("storage_buffer", index, BINDING_OUTPUT, 0, slot.output, slot.output:GetSize())
	pipeline:UpdateDescriptorSet(
		"storage_buffer",
		index,
		BINDING_MATERIALS,
		0,
		slot.materials,
		slot.materials:GetSize()
	)
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", index, BINDING_TLAS, 0, tlas)
	hit.Bind(pipeline, index, BINDING_HIT)
	acoustics_gpu.current_job = job
	acoustics_gpu.current_tracer = self
	pipeline:UploadConstants()
	cmd:PipelineBarrier{
		srcStage = {"acceleration_structure_build_khr", "host"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	gpu_timing.BeginScope(cmd, "audio_acoustics")
	pipeline.pipeline:Dispatch(
		cmd,
		math.ceil(job.rays / GROUP_SIZE) + math.ceil(job.query_count / GROUP_SIZE),
		1,
		1,
		index,
		pipeline.dynamic_offsets
	)
	gpu_timing.EndScope(cmd, "audio_acoustics")
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	self.inflight[index] = job
end

function META:Remove()
	event.RemoveListener("PreRenderPass", self.listener_id)
end

function acoustics_gpu.New(budget)
	local self = setmetatable(
		{
			done = {},
			slots = {},
			inflight = {},
			material_count = 0,
			budget = budget or
				{
					rays = 1024,
					bounces = 8,
					samples = 256,
					sources = MAX_SOURCES - 1,
					fresnel = 4,
					reflection_sources = MAX_SOURCES - 1,
				},
		},
		META
	)
	self.pipeline = build_pipeline(math.max(render.GetSwapchainImageCount() or 1, 1))

	if PHYSICS then self.cpu = import("goluwa/audio/acoustics_cpu.lua").New() end

	self.listener_id = "audio_acoustics_gpu_" .. tostring(self)

	event.AddListener(
		"PreRenderPass",
		self.listener_id,
		function()
			self:Dispatch(render.GetCommandBuffer())
		end,
		{priority = -10}
	)

	return self
end

return acoustics_gpu
