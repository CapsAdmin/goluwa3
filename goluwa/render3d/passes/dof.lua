local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local exposure_model = import("goluwa/render3d/exposure.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local View = import("goluwa/render3d/view.lua")
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
	local target = hit and math.max(hit.distance, MIN_FOCUS) or FAR_FOCUS
	focus_distance = math.lerp(1 - math.exp(-system.GetFrameTime() / FOCUS_SECONDS), focus_distance, target)
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
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.source_tex = self:GetTextureIndex(post_source.GetSceneSourceTexture({name = "dof"}))
						block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
						post_source.WritePreExposureBlock(self, block)
						exposure_model.WriteCameraBlock(block)
						local focus = update_focus()
						local height = render3d.GetRenderSize().y
						local focal_mm = SENSOR_HEIGHT_MM / 2 / math.tan(render3d.GetCamera():GetFOV() / 2)
						block.focus = focus
						block.coc_k = 0.5 * focal_mm * focal_mm / math.max(focus * 1000 - focal_mm, 1) * height / SENSOR_HEIGHT_MM
						block.max_radius = max_radius:Get()
						block.frame = system.GetFrameNumber()
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("dof_data") .. exposure_model.GetCameraSettingsGLSL("dof_data") .. screen_reconstruct.GetViewDepthGLSL("dof_data") .. [[

			const int SAMPLES = ]] .. SAMPLES .. [[;

			ivec2 size;
			float coc_scale;

			float coc_at(ivec2 pixel, out float z) {
				pixel = clamp(pixel, ivec2(0), size - 1);
				float depth = texelFetch(TEXTURE(dof_data.depth_tex), pixel, 0).r;
				z = depth > 0.0 ? get_view_depth((vec2(pixel) + 0.5) / vec2(size), depth) : 1e4;
				return min(coc_scale * abs(z - dof_data.focus) / z, dof_data.max_radius);
			}

			void main() {
				size = textureSize(TEXTURE(dof_data.source_tex), 0);
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				float exposure = dof_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				vec4 center = texelFetch(TEXTURE(dof_data.source_tex), pixel, 0);
				float aperture = dof_data.pre_exposure_tex != -1 ? camera_settings(get_exposure()).y : 64.0;
				coc_scale = dof_data.coc_k / aperture;
				float radius = min(coc_scale * 4.0, dof_data.max_radius);

				if (radius < 0.75) {
					set_color(center);
					return;
				}

				float center_z;
				float center_coc = coc_at(pixel, center_z);
				float angle_offset = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)) + float(dof_data.frame % 8) * 0.618034)) * 6.2831853;
				float center_weight = 1.0 / max(center_coc * center_coc, 1.0);
				vec3 sum = compress(center.rgb, exposure) * center_weight;
				float total = center_weight;

				for (int i = 0; i < SAMPLES; i++) {
					float dist = sqrt((float(i) + 0.5) / float(SAMPLES)) * radius;
					float angle = float(i) * 2.39996323 + angle_offset;
					ivec2 p = pixel + ivec2(round(vec2(cos(angle), sin(angle)) * dist));
					float z;
					float coc = coc_at(p, z);
					float spread = z < center_z ? coc : center_coc;
					float weight = clamp(spread - dist + 1.0, 0.0, 1.0) / max(spread * spread, 1.0);
					sum += compress(texelFetch(TEXTURE(dof_data.source_tex), clamp(p, ivec2(0), size - 1), 0).rgb, exposure) * weight;
					total += weight;
				}

				set_color(vec4(decompress(sum / total, exposure), center.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
