local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local dlss = import("goluwa/render3d/dlss.lua")
local ngx = import("goluwa/bindings/ngx.lua")
local inputs = {}

local function is_enabled()
	return render3d.IsAntiAliasingEnabled("dlss") or
		render3d.IsAntiAliasingEnabled("dlss_rr")
end

local function is_ray_reconstruction()
	return render3d.IsAntiAliasingEnabled("dlss_rr")
end

local function get_hit_distance_texture()
	if not render3d.IsPassEnabled("reflections") then return nil end

	local trace = render3d.pipelines.reflections_trace

	if not trace.framebuffers then return nil end

	return trace:GetFramebuffer(1):GetAttachment(2)
end

local function guide_attachment(index)
	return render3d.pipelines.dlss_guides:GetFramebuffer():GetAttachment(index)
end

return {
	{
		name = "dlss_guides",
		resolution = "internal",
		lazy_framebuffers = true,
		is_enabled = is_ray_reconstruction,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"diffuse_albedo", "rgba"}},
			{"r16g16b16a16_sfloat", {"specular_albedo", "rgba"}},
			{"r16g16b16a16_sfloat", {"normal_roughness", "rgba"}},
			{"r16g16_sfloat", {"specular_motion", "rg"}},
		},
		fragment = {
			uniform_buffers = {
				{
					name = "guide_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						render3d.prev_camera_block,
						gbuffer_layout.block,
						{"brdf_lut_tex", "int"},
						{"hit_distance_tex", "int"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WritePreviousCameraBlock(self, block)
						gbuffer_layout.WriteBlock(self, block)
						local hit_distance = get_hit_distance_texture()
						block.hit_distance_tex = hit_distance and self:GetTextureIndex(hit_distance) or -1
						block.brdf_lut_tex = self:GetTextureIndex(assert(assets.GetTexture("textures/render/brdf_lut.lua")))
						return block
					end,
				},
			},
			shader = glsl_common.GetLuminanceGLSL() .. ibl.GetBRDFGLSLCode() .. gbuffer_layout.GetDecodeGLSL("guide_data") .. [[
			void main() {
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				float depth = gbuffer_depth(pixel);

				if (depth == 0.0) {
					set_diffuse_albedo(vec4(0.0));
					set_specular_albedo(vec4(0.0));
					set_normal_roughness(vec4(0.0, 0.0, 1.0, 1.0));
					set_specular_motion(vec2(0.0));
					return;
				}

				vec2 uv = (vec2(pixel) + 0.5) / guide_data.render_size;
				vec4 view_position = guide_data.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
				vec3 V = normalize(-view_position.xyz / view_position.w);
				vec3 N = gbuffer_normal(pixel);
				vec3 albedo = gbuffer_albedo(pixel);
				float metallic = gbuffer_metallic(pixel);
				float perceptual_roughness = sqrt(gbuffer_roughness(pixel));
				float NoV = clamp(dot(mat3(guide_data.view) * N, V), 0.001, 1.0);
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				vec2 env_brdf = texture(TEXTURE(guide_data.brdf_lut_tex), vec2(NoV, perceptual_roughness)).rg;
				vec3 specular = (F0 * env_brdf.x + vec3(F90(F0)) * env_brdf.y) * GGXEnergyCompensation(F0, env_brdf);
				set_diffuse_albedo(vec4(albedo * max(1.0 - specular, vec3(0.0)) * (1.0 - metallic), 1.0));
				set_specular_albedo(vec4(specular, 1.0));
				set_normal_roughness(vec4(N, perceptual_roughness));
				float hit_distance = guide_data.hit_distance_tex != -1 ? texelFetch(TEXTURE(guide_data.hit_distance_tex), pixel, 0).r : 0.0;

				if (hit_distance <= 0.0) hit_distance = 1000.0;

				vec3 view_position_3d = view_position.xyz / view_position.w;
				float view_distance = length(view_position_3d);
				vec3 image_position = (guide_data.inv_view * vec4(view_position_3d / view_distance * (view_distance + hit_distance), 1.0)).xyz;
				vec4 previous_clip = guide_data.prev_projection * (guide_data.prev_view * vec4(image_position, 1.0));
				set_specular_motion(uv - (previous_clip.xy / previous_clip.w * 0.5 + 0.5));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "dlss",
		ComputePass = true,
		is_enabled = is_enabled,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = 0, attachment = 1, dst_stage = {"compute", "fragment"}}},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D dlss_output;
		]],
		shader = [[
			void main() {
			}
		]],
		on_draw = function(self, cmd, fb, frame, desc)
			local camera = render3d.GetCamera()
			local viewport = camera:GetViewport()
			local jitter = camera:GetJitter()
			local color = post_source.GetSceneSourceTexture(self)
			local output = fb:GetAttachment(1)
			local ray_reconstruction = is_ray_reconstruction()
			inputs.render_width = color:GetWidth()
			inputs.render_height = color:GetHeight()
			inputs.output_width = output:GetWidth()
			inputs.output_height = output:GetHeight()
			inputs.color = color
			inputs.depth = gbuffer_layout.GetDepthTexture()
			inputs.motion = gbuffer_layout.GetTexture("velocity")
			inputs.output = output
			inputs.jitter_x = jitter.x * inputs.render_width / viewport.w
			inputs.jitter_y = jitter.y * inputs.render_height / viewport.h
			inputs.reset = render3d.IsCameraCut()
			inputs.motion_scale_x = -inputs.render_width
			inputs.motion_scale_y = -inputs.render_height

			if ray_reconstruction then
				inputs.diffuse_albedo = guide_attachment(1)
				inputs.specular_albedo = guide_attachment(2)
				inputs.normals = guide_attachment(3)
				inputs.specular_motion = guide_attachment(4)
				inputs.hit_distance = get_hit_distance_texture()
			end

			dlss.Evaluate(
				cmd,
				ray_reconstruction and ngx.Feature.RayReconstruction or ngx.Feature.SuperSampling,
				inputs
			)
		end,
	},
}
