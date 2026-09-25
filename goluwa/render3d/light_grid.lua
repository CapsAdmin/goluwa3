local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_grid = library()
-- Which lights reach which part of the world, so a shader only loops over the
-- lights that can light its point instead of all of them. Nested grids of
-- DIM^3 cells around the camera, each twice the cell size of the one inside
-- it, hold a bit per light (in render3d.GetLights order, the order every
-- light block is written in) for the lights whose range touches the cell.
-- Rebuilt on the GPU every frame. A point outside every grid gets all lights.
light_grid.LEVELS = 4
light_grid.DIM = 32
light_grid.CELL_SIZE = 2
light_grid.WORDS = scene_lights.MAX_LIGHTS / 32
local HEADER_BYTES = 16 * light_grid.LEVELS + 16
local BINDING_UNIFORM = 0
local BINDING_GRID = 1
-- the ddgi ray generation shader and the translucent pass's fragment shader
-- read it too; set with the buffer
local rt_stage = nil
local buffer = nil

function light_grid.GetBuffer(cmd)
	if not buffer then
		rt_stage = render.GetDevice().ray_tracing_supported and "ray_tracing_shader_khr" or nil
		buffer = render.CreateBuffer{
			byte_size = HEADER_BYTES + light_grid.LEVELS * light_grid.DIM ^ 3 * light_grid.WORDS * 4,
			buffer_usage = {"storage_buffer", "transfer_dst"},
			memory_property = {"device_local"},
			label = "light_grid",
		}
		-- no levels until the first build, so every point gets all lights
		cmd:FillBuffer(buffer, 0, buffer:GetSize(), 0)
		cmd:PipelineBarrier{
			srcStage = "transfer",
			dstStage = {"compute", "fragment", rt_stage},
			bufferBarriers = {
				{
					buffer = buffer,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
				},
			},
		}
	end

	return buffer
end

function light_grid.Bind(self, cmd, desc, binding)
	local grid = light_grid.GetBuffer(cmd)
	self:UpdateDescriptorSet("storage_buffer", desc, binding, 0, grid, grid:GetSize())
end

local function declarations(binding, access)
	return string.format(
		[[
		#define LIGHT_GRID_LEVELS %d
		#define LIGHT_GRID_DIM %d
		#define LIGHT_GRID_WORDS %d
		layout(std430, set = 0, binding = %d) %s buffer LightGrid {
			// xyz = the level's minimum corner, w = its cell size
			vec4 light_grid_levels[LIGHT_GRID_LEVELS];
			// x = levels built, 0 before the first build
			ivec4 light_grid_info;
			uint light_grid_cells[];
		};
	]],
		light_grid.LEVELS,
		light_grid.DIM,
		light_grid.WORDS,
		binding,
		access
	)
end

-- Loop over the lights at P with:
--   int cell = light_grid_cell(P);
--   for (int w = 0; w < light_grid_words(light_count); w++) {
--       uint bits = light_grid_word(cell, w, light_count);
--       while (bits != 0u) {
--           int i = w * 32 + findLSB(bits);
--           bits &= bits - 1u;
--           ...
--       }
--   }
function light_grid.GetGLSL(binding)
	return declarations(binding, "readonly") .. [[
		int light_grid_cell(vec3 P) {
			for (int l = 0; l < light_grid_info.x; l++) {
				vec4 level = light_grid_levels[l];
				ivec3 c = ivec3(floor((P - level.xyz) / level.w));

				if (all(greaterThanEqual(c, ivec3(0))) && all(lessThan(c, ivec3(LIGHT_GRID_DIM)))) {
					return ((l * LIGHT_GRID_DIM + c.z) * LIGHT_GRID_DIM + c.y) * LIGHT_GRID_DIM + c.x;
				}
			}

			return -1;
		}

		// only the words that hold lights, so a high MAX_LIGHTS costs nothing
		int light_grid_words(int light_count) {
			return min((light_count + 31) / 32, LIGHT_GRID_WORDS);
		}

		uint light_grid_word(int cell, int w, int light_count) {
			if (cell >= 0) return light_grid_cells[cell * LIGHT_GRID_WORDS + w];

			int n = light_count - w * 32;
			return n >= 32 ? 0xFFFFFFFFu : n <= 0 ? 0u : (1u << uint(n)) - 1u;
		}
	]]
end

light_grid.pass = {
	name = "light_grid",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"light_grid_dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 4, y = 4, z = 4},
	storage_buffers = {{binding_index = BINDING_GRID}},
	uniform_buffers = {
		{
			name = "light_grid_data",
			binding_index = BINDING_UNIFORM,
			block = {
				{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
				{"light_count", "int"},
				{"levels", "vec4", light_grid.LEVELS},
			},
			write = function(self, block)
				local lights = render3d.GetLights()
				scene_lights.WriteLightsBlock(block.lights, lights)
				block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
				local camera = render3d.GetCamera():GetPosition()

				for l = 0, light_grid.LEVELS - 1 do
					local size = light_grid.CELL_SIZE * 2 ^ l
					local half = light_grid.DIM / 2
					block.levels[l][0] = (math.floor(camera.x / size) - half) * size
					block.levels[l][1] = (math.floor(camera.y / size) - half) * size
					block.levels[l][2] = (math.floor(camera.z / size) - half) * size
					block.levels[l][3] = size
				end

				return block
			end,
		},
	},
	on_pre_draw = function(self, cmd, frame, desc)
		light_grid.Bind(self, cmd, desc, BINDING_GRID)
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		local grid = light_grid.GetBuffer(cmd)
		-- last frame's readers are done before it's overwritten
		cmd:PipelineBarrier{
			srcStage = {"compute", "fragment", rt_stage},
			dstStage = "compute",
			bufferBarriers = {{buffer = grid, srcAccessMask = "shader_read", dstAccessMask = "shader_write"}},
		}
		self:UploadConstants()
		self.pipeline:DispatchForSize(
			cmd,
			light_grid.DIM,
			light_grid.DIM,
			light_grid.DIM * light_grid.LEVELS,
			desc,
			self.dynamic_offsets
		)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = {"compute", "fragment", rt_stage},
			bufferBarriers = {{buffer = grid, srcAccessMask = "shader_write", dstAccessMask = "shader_read"}},
		}
	end,
	custom_declarations = declarations(BINDING_GRID, ""),
	shader = [[
		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);
			int l = id.z / LIGHT_GRID_DIM;

			if (id.x >= LIGHT_GRID_DIM || id.y >= LIGHT_GRID_DIM || l >= LIGHT_GRID_LEVELS) return;

			ivec3 c = ivec3(id.xy, id.z % LIGHT_GRID_DIM);
			vec4 level = light_grid_data.levels[l];

			if (id == ivec3(0)) {
				for (int i = 0; i < LIGHT_GRID_LEVELS; i++) {
					light_grid_levels[i] = light_grid_data.levels[i];
				}

				light_grid_info = ivec4(LIGHT_GRID_LEVELS, 0, 0, 0);
			}

			vec3 box_min = level.xyz + vec3(c) * level.w;
			vec3 box_max = box_min + level.w;
			int cell = ((l * LIGHT_GRID_DIM + c.z) * LIGHT_GRID_DIM + c.y) * LIGHT_GRID_DIM + c.x;

			for (int w = 0; w < (light_grid_data.light_count + 31) / 32; w++) {
				uint bits = 0u;

				for (int b = 0; b < 32; b++) {
					int i = w * 32 + b;

					if (i >= light_grid_data.light_count) break;

					lights_t light = light_grid_data.lights[i];
					int type = int(light.position.w);
					// the sun and directional lights reach everywhere
					bool reaches = type == 0 || type == 2;

					if (!reaches) {
						vec3 d = light.position.xyz - clamp(light.position.xyz, box_min, box_max);
						reaches = dot(d, d) < light.params.x * light.params.x;
					}

					if (reaches) bits |= 1u << uint(b);
				}

				light_grid_cells[cell * LIGHT_GRID_WORDS + w] = bits;
			}
		}
	]],
}
return light_grid
