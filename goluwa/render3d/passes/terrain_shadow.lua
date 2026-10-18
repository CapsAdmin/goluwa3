local render3d = import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local terrain_shadow = import("goluwa/render3d/terrain_shadow.lua")
local BINDING_OUT = 0
local BINDING_HEIGHTS = 1
local BINDING_DATA = 2
-- the sun has to move this much (the length of the difference of the unit vectors) for the shadow to be marched again
local SUN_EPSILON = 0.0005
local sun_marched = {0, 0, 0}

local function sun_moved(sun)
	local dx, dy, dz = sun.x - sun_marched[1], sun.y - sun_marched[2], sun.z - sun_marched[3]

	return dx * dx + dy * dy + dz * dz > SUN_EPSILON * SUN_EPSILON
end

return {
	{
		name = "terrain_shadow",
		ComputePass = true,
		ColorFormat = {{"r8_unorm", {"terrain_shadow_dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		is_enabled = function()
			local field = terrain_shadow.field

			return field ~= nil and
				(
					terrain_shadow.dirty or
					sun_moved(directional_shadows.GetPrimarySunDirection(render3d.GetLights()))
				)
		end,
		storage_images = {
			{
				binding_index = BINDING_OUT,
				dst_stage = "fragment",
				get_texture = function()
					return terrain_shadow.textures.shadow
				end,
			},
		},
		sampled_images = {
			{
				binding_index = BINDING_HEIGHTS,
				get_texture = function()
					return terrain_shadow.textures.height
				end,
			},
		},
		uniform_buffers = {
			{
				name = "ts_data",
				binding_index = BINDING_DATA,
				block = {
					{"sun_direction", "vec4"},
					{"field", "vec4"},
				},
				write = function(self, block)
					local sun = directional_shadows.GetPrimarySunDirection(render3d.GetLights())
					local field = terrain_shadow.field
					block.sun_direction[0] = sun.x
					block.sun_direction[1] = sun.y
					block.sun_direction[2] = sun.z
					block.sun_direction[3] = field.max_height
					block.field[0] = field.step
					block.field[1] = field.size
					block.field[2] = 0
					block.field[3] = 0
					return block
				end,
			},
		},
		on_draw = function(self, cmd, fb, frame, desc)
			local sun = directional_shadows.GetPrimarySunDirection(render3d.GetLights())
			self:UploadConstants()
			local size = terrain_shadow.field.size
			self.pipeline:DispatchForSize(cmd, size, size, 1, desc, self.dynamic_offsets)
			sun_marched[1], sun_marched[2], sun_marched[3] = sun.x, sun.y, sun.z
			terrain_shadow.dirty = false
			terrain_shadow.ready = true
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUT .. [[, r32f) uniform writeonly image2D out_shadow;
			layout(set = 0, binding = ]] .. BINDING_HEIGHTS .. [[) uniform sampler2D terrain_heights;
		]],
		shader = [[
			const int MAX_STEPS = 600;
			const float START_TEXELS = 2.0;
			// the step grows with the distance, 1 texel up close and a texel more every this many
			const float GROWTH_TEXELS = 48.0;

			void main() {
				ivec2 id = ivec2(gl_GlobalInvocationID.xy);
				ivec2 size = imageSize(out_shadow);

				if (any(greaterThanEqual(id, size))) return;

				vec3 sun = ts_data.sun_direction.xyz;
				float max_height = ts_data.sun_direction.w;
				float step_m = ts_data.field.x;
				float horizontal = length(sun.xz);
				float lowest_ray = -1.0e6;

				if (sun.y <= 0.0) {
					lowest_ray = 1.0e6;
				} else if (horizontal > 1.0e-4) {
					vec2 dir = sun.xz / horizontal;
					float rise = sun.y / horizontal;
					float d = START_TEXELS;
					vec2 origin = vec2(id) + 0.5;

					for (int i = 0; i < MAX_STEPS; i++) {
						vec2 q = origin + dir * d;

						if (any(lessThan(q, vec2(0.0))) || any(greaterThan(q, vec2(size)))) break;

						float h = textureLod(terrain_heights, q / vec2(size), 0.0).r;
						lowest_ray = max(lowest_ray, h - d * step_m * rise);

						// nothing further along can reach over what was found
						if (max_height - d * step_m * rise <= lowest_ray) break;

						d += 1.0 + d / GROWTH_TEXELS;
					}
				}

				imageStore(out_shadow, id, vec4(lowest_ray, 0.0, 0.0, 0.0));
			}
		]],
	},
}
