local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local View = import("goluwa/render3d/view.lua")
local lens = import("goluwa/render3d/lens.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local lens_flare = import("goluwa/render3d/passes/lens_flare.lua")
local SAMPLES = 32
local SENSOR_HEIGHT_MM = 24
local MIN_FOCUS = 0.3
local FAR_FOCUS = 1000
local FOCUS_SECONDS = 0.15
pvars.StartGroup("Post", "Camera effects", {store = false, prefix = "dof_"})
render3d.dof_enabled = pvars.Setup2{
	key = "r_dof",
	default = false,
	help = "depth of field from the aperture the camera would pick for the exposure, focused on what the centre of the screen looks at",
}
local max_radius = pvars.Setup2{
	key = "r_dof_max",
	default = 24,
	min = 2,
	max = 64,
	help = "the largest blur radius in pixels",
}
pvars.EndGroup()
local focus_distance = FAR_FOCUS

local function is_not_ignored(entity, ignored)
	return not ignored or (entity ~= ignored and not entity:ContainsParent(ignored))
end

local function update_focus()
	local view = View.GetActive()
	local hit = raycast.CastClosestFromCamera(render3d.GetCamera(), is_not_ignored, view and view.Ignore)
	local scale = render3d.GetViewScale()
	local target = hit and math.max(hit.distance, MIN_FOCUS * scale) or FAR_FOCUS * scale
	focus_distance = math.lerp(
		1 - math.exp(-system.GetUnscaledFrameTime() / FOCUS_SECONDS),
		focus_distance,
		target
	)
	return focus_distance
end

return {
	{
		name = "dof",
		is_enabled = function()
			return render3d.dof_enabled:Get()
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			uniform_buffers = {
				{
					name = "dof_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						{"source_tex", "int"},
						{"depth_tex", "int"},
						post_source.pre_exposure_block,
						exposure_model.camera_block,
						{"focus", "float"},
						{"coc_k", "float"},
						{"max_radius", "float"},
						{"frame", "int"},
						lens.block,
						{"lens_on", "int"},
						{"focus_shift", "vec4"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "dof"}))
						block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
						post_source.WritePreExposureBlock(self, block)
						exposure_model.WriteCameraBlock(block)
						local focus = update_focus()
						local size = render.GetRenderImageSize()
						local built = not exposure_model.IsEye() and lens.GetBuilt()
						local sensor_height = built and 2 * lens.GetFrameHalfHeight(built, size.x, size.y) or SENSOR_HEIGHT_MM
						local focal_mm = sensor_height / 2 / math.tan(render3d.GetCamera():GetFOV() / 2)
						block.focus = focus
						block.coc_k = 0.5 * focal_mm * focal_mm / math.max(focus / render3d.GetViewScale() * 1000 - focal_mm, 1) * size.y / sensor_height
						block.max_radius = max_radius:Get()
						block.frame = system.GetFrameNumber()
						block.lens_on = built and 1 or 0

						if built then
							lens_flare.WriteLensBlock(self, block, built)
							local amount = lens.Get("lens.longitudinal_color")

							for channel = 1, 3 do
								block.focus_shift[channel - 1] = 0.5 * built.focus_shift[channel] * amount * focal_mm / built.focal_length * size.y / sensor_height
							end
						else
							block.focus_shift[0], block.focus_shift[1], block.focus_shift[2] = 0, 0, 0
						end

						return block
					end,
				},
			},
			shader = [[
]] .. glsl_common.GetLuminanceGLSL() .. post_source.GetPreExposureGLSL("dof_data") .. exposure_model.GetCameraSettingsGLSL("dof_data") .. lens.GetGLSL("dof_data") .. screen_reconstruct.GetViewDepthGLSL("dof_data") .. [[

			const int SAMPLES = ]] .. SAMPLES .. [[;

			ivec2 size;
			vec2 depth_scale;
			float coc_scale;
			float aperture;
			float pixels_per_mm;
			float exposure;

			vec3 compress_rgb(vec3 c) {
				c *= exposure;
				return c / (1.0 + luminance(c));
			}

			vec3 decompress_rgb(vec3 c) {
				c = max(c, vec3(0.0));
				return c / max(1.0 - luminance(c), 1e-6) / exposure;
			}

			float bokeh_coverage(ivec2 source, vec2 offset, float dist, float spread, float side) {
				if (dof_data.lens_on == 0) return clamp(spread - dist + 1.0, 0.0, 1.0);

				vec2 q = side * offset / max(spread, 0.5);
				vec2 field_mm = (vec2(source) + 0.5 - 0.5 * vec2(size)) / pixels_per_mm;
				return clamp(1.0 - lens_bokeh_distance(q, field_mm, aperture) * spread, 0.0, 1.0);
			}

			vec3 signed_coc_at(ivec2 pixel, out float z) {
				pixel = clamp(pixel, ivec2(0), size - 1);
				float depth = texelFetch(TEXTURE(dof_data.depth_tex), ivec2((vec2(pixel) + 0.5) * depth_scale), 0).r;
				z = depth > 0.0 ? get_view_depth((vec2(pixel) + 0.5) / vec2(size), depth) : 1e4;
				return (dof_data.coc_k * (dof_data.focus - z) / z + dof_data.focus_shift.rgb) / aperture;
			}

			void main() {
				size = textureSize(TEXTURE(dof_data.source_tex), 0);
				depth_scale = vec2(textureSize(TEXTURE(dof_data.depth_tex), 0)) / vec2(size);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				exposure = dof_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec4 center = texelFetch(TEXTURE(dof_data.source_tex), pixel, 0);
				aperture = dof_data.pre_exposure_tex != -1 ? camera_settings(get_exposure()).y : 64.0;
				pixels_per_mm = 0.5 * length(vec2(size)) / max(dof_data.lens_image_radius, 1e-3);
				coc_scale = dof_data.coc_k / aperture;
				vec3 shift = abs(dof_data.focus_shift.rgb) / aperture;
				float radius = min(coc_scale * 4.0 + max(shift.r, max(shift.g, shift.b)), dof_data.max_radius);

				if (radius < 0.75) {
					set_color(center);
					return;
				}

				float center_z;
				vec3 center_signed = signed_coc_at(pixel, center_z);
				vec3 center_coc = min(abs(center_signed), vec3(dof_data.max_radius));
				float angle_offset = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)) + float(dof_data.frame % 8) * 0.618034)) * 6.2831853;
				vec3 total = 1.0 / max(center_coc * center_coc, vec3(1.0));
				vec3 sum = compress_rgb(center.rgb) * total;

				for (int i = 0; i < SAMPLES; i++) {
					float dist = sqrt((float(i) + 0.5) / float(SAMPLES)) * radius;
					float angle = float(i) * 2.39996323 + angle_offset;
					ivec2 p = pixel + ivec2(round(vec2(cos(angle), sin(angle)) * dist));
					float z;
					vec3 signed_coc = signed_coc_at(p, z);
					bool nearer = z < center_z;
					vec3 chosen = nearer ? signed_coc : center_signed;
					vec3 spread = min(abs(chosen), vec3(dof_data.max_radius));
					ivec2 source = nearer ? p : pixel;
					vec2 offset = vec2(pixel - p);
					vec3 weight = vec3(
						bokeh_coverage(source, offset, dist, spread.r, chosen.r >= 0.0 ? 1.0 : -1.0),
						bokeh_coverage(source, offset, dist, spread.g, chosen.g >= 0.0 ? 1.0 : -1.0),
						bokeh_coverage(source, offset, dist, spread.b, chosen.b >= 0.0 ? 1.0 : -1.0)
					) / max(spread * spread, vec3(1.0));
					sum += compress_rgb(texelFetch(TEXTURE(dof_data.source_tex), clamp(p, ivec2(0), size - 1), 0).rgb) * weight;
					total += weight;
				}

				set_color(vec4(decompress_rgb(sum / total), center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
