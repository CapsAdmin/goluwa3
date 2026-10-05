local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local normal_debug = import("goluwa/render3d/normal_debug.lua")
local post_source = import("goluwa/render3d/post_source.lua")
return {
	{
		name = "normal_debug",
		is_enabled = function()
			return normal_debug.GetView() ~= 0
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "debug_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						gbuffer_layout.block,
						{"mode", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						gbuffer_layout.WriteBlock(self, block)
						block.mode = normal_debug.GetView()
						return block
					end,
				},
			},
			shader = gbuffer_layout.GetDecodeGLSL("debug_data") .. [[
			void main() {
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec3 shown = vec3(0.0);

				if (gbuffer_depth(pixel) != 1.0) {
					shown = gbuffer_normal(pixel) * 0.5 + 0.5;
				}

				// a half sphere in the corner shaded like the surfaces, as seen from the camera: each pixel is the
				// normal a surface facing that way on screen would have. the map view is tangent space, so its
				// sphere is not rotated into the world
				float radius = debug_data.render_size.y * 0.1;
				vec2 offset = vec2(debug_data.render_size.x - radius * 1.4, debug_data.render_size.y - radius * 1.4);
				vec2 d = (gl_FragCoord.xy - offset) / radius;
				d.y = -d.y;
				float len = length(d);

				if (len < 1.0) {
					vec3 view_normal = vec3(d, sqrt(1.0 - len * len));
					vec3 sphere = debug_data.mode == ]] .. normal_debug.MAP .. [[ ? view_normal : normalize(mat3(debug_data.inv_view) * view_normal);
					shown = sphere * 0.5 + 0.5;
				} else if (len < 1.04) {
					shown = vec3(0.0);
				}

				set_color(vec4(shown, 1.0));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
