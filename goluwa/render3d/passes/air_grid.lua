local render3d = import("goluwa/render3d/render3d.lua")
local air_grid = import("goluwa/render3d/air_grid.lua")
local debug_block = table.copy(render3d.camera_block)
table.add(debug_block, air_grid.GetBlockLayout())
list.insert(debug_block, {"debug_view", "int"})
return {
	{
		name = "air_grid",
		ComputePass = true,
		compute_input = true,
		ColorFormat = {{"r8_unorm", {"air_grid_dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		shader = "void main() {}",
		on_draw = function(self, cmd)
			air_grid.Update(cmd)
		end,
	},
	{
		name = "air_grid_debug",
		resolution = "internal",
		lazy_framebuffers = true,
		is_enabled = function()
			return air_grid.GetDebugView() ~= 0
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "debug_data",
					binding_index = 2,
					block = debug_block,
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						air_grid.WriteBlock(block)
						block.debug_view = air_grid.GetDebugView()
						return block
					end,
				},
			},
			shader = air_grid.GetGLSL("debug_data") .. [[
			const vec3 LEVEL_TINT[5] = vec3[](vec3(0.95, 0.92, 0.85), vec3(0.55, 0.8, 1.0), vec3(0.6, 1.0, 0.6), vec3(1.0, 0.85, 0.45), vec3(0.9, 0.6, 1.0));

			void main() {
				vec2 uv = gl_FragCoord.xy / debug_data.render_size;
				vec4 clip_pos = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
				vec4 view_pos = debug_data.inv_projection * clip_pos;
				vec3 dir = normalize(mat3(debug_data.inv_view) * (view_pos.xyz / view_pos.w));
				vec3 origin = debug_data.camera_position;
				vec3 shown = vec3(0.02, 0.02, 0.03) + max(dir.y, 0.0) * vec3(0.05, 0.07, 0.1);
				float unknown = 0.0;
				int last_level = debug_data.debug_view == 2 ? 0 : AIR_GRID_LEVELS - 1;
				float t = 0.0;
				int steps = 0;

				if (air_grid_available()) {
					for (int level = 0; level <= last_level && steps < 1024; level++) {
						float cs = air_grid_cell_size(level);
						ivec4 origin_brick = ivec4(debug_data.air_grid_origin[level]);

						if (origin_brick.w == 0) continue;

						vec3 region_min = vec3(origin_brick.xyz * 32) * cs;
						vec3 region_max = region_min + 256.0 * cs;
						vec3 p = origin + dir * t;

						if (any(lessThan(p, region_min)) || any(greaterThanEqual(p, region_max))) continue;

						vec3 inv = 1.0 / max(abs(dir), vec3(1e-9));
						vec3 pa = p / cs;
						ivec3 c = ivec3(floor(pa));
						ivec3 step_dir = ivec3(sign(dir));
						vec3 t_max = t + (step(0.0, dir) * (vec3(c) + 1.0 - pa) + step(dir, vec3(0.0)) * (pa - vec3(c))) * inv * cs;
						vec3 t_delta = inv * cs;
						ivec3 brick = ivec3(-2147483647);
						int slot = -1;
						int axis = -1;
						bool hit = false;

						ivec3 region_cell_min = origin_brick.xyz * 32;

						while (steps < 1024 && all(greaterThanEqual(c, region_cell_min)) && all(lessThan(c, region_cell_min + 256))) {
							steps++;
							ivec3 cell_brick = c >> 5;

							if (cell_brick != brick) {
								brick = cell_brick;
								slot = air_grid_slot(level, brick);

								// consumers fall back to the next coarser level at a hole, so the ray does too
								if (slot < 0) {
									if (level == last_level) unknown = 1.0;

									break;
								}
							}

							ivec3 local_cell = c & 31;
							uint word = AirGridBits(debug_data.air_grid_bits).w[uint(slot) * 1024u + uint(local_cell.z * 32 + local_cell.y)];

							if ((word & (1u << uint(local_cell.x))) != 0u) {
								hit = true;
								break;
							}

							if (t_max.x < t_max.y && t_max.x < t_max.z) {
								t = t_max.x; t_max.x += t_delta.x; c.x += step_dir.x; axis = 0;
							} else if (t_max.y < t_max.z) {
								t = t_max.y; t_max.y += t_delta.y; c.y += step_dir.y; axis = 1;
							} else {
								t = t_max.z; t_max.z += t_delta.z; c.z += step_dir.z; axis = 2;
							}
						}

						if (hit) {
							vec3 n = axis < 0 ? -dir : -vec3(equal(ivec3(axis), ivec3(0, 1, 2))) * vec3(step_dir);
							vec3 hit_pos = origin + dir * t;
							vec3 f = fract(hit_pos / cs);
							vec3 edge = min(f, 1.0 - f);
							edge = mix(edge, vec3(1.0), abs(n));
							float cell_pixels = cs * abs(debug_data.projection[1][1]) * debug_data.render_size.y / (2.0 * max(t, 1e-3));
							float line = (1.0 - smoothstep(0.03, 0.08, min(edge.x, min(edge.y, edge.z)))) * smoothstep(4.0, 10.0, cell_pixels);
							float light = 0.45 + 0.35 * max(dot(n, normalize(vec3(0.4, 0.8, 0.3))), 0.0) + 0.2 * abs(n.y);
							vec3 tint = LEVEL_TINT[level];

							if (debug_data.debug_view == 3) {
								tint = vec3(0.35);

								for (int field_level = 0; field_level < AIR_GRID_LEVELS; field_level++) {
									int d = air_grid_sky_distance(field_level, hit_pos + n * (0.75 * air_grid_field_cell(field_level)));

									if (d < 0 || d == AIR_GRID_SOLID) continue;

									float meters = float(d) * air_grid_field_cell(field_level);
									float x = clamp(meters / 12.0, 0.0, 1.0);
									tint = d == AIR_GRID_FAR ? vec3(0.3, 0.03, 0.03) : x < 0.4 ? mix(vec3(0.2, 0.9, 1.0), vec3(1.0, 0.9, 0.2), x / 0.4) : mix(vec3(1.0, 0.9, 0.2), vec3(1.0, 0.15, 0.08), (x - 0.4) / 0.6);
									break;
								}
							}

							shown = tint * light * (1.0 - 0.6 * line);
							shown *= mix(1.0, 0.35, clamp(t / 200.0, 0.0, 1.0));
							break;
						}

						// a surface on the border of this level can be voxelized into the cell just past it, the coarser
						// level marches the last cell again
						t = max(t - 2.0 * cs, 0.0);
					}
				}

				shown = mix(shown, vec3(1.0, 0.1, 0.05), 0.35 * unknown);
				set_color(vec4(shown, 1.0));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
