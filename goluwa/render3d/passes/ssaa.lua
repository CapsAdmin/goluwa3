local Vec2 = import("goluwa/structs/vec2.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
pvars.StartGroup("ssaa", {store = false})
local sample_count = pvars.Setup2{
	key = "r_ssaa_samples",
	default = 64,
	min = 1,
	max = 4096,
	help = "how many jittered frames are averaged per pixel before the image is held. the average restarts when the camera moves",
}
pvars.EndGroup()
local halton

do
	function halton(i, base)
		local f, r = 1, 0

		while i > 0 do
			f = f / base
			r = r + f * (i % base)
			i = math.floor(i / base)
		end

		return r
	end
end

local count = 0
local last_x, last_y, last_z = 0, 0, 0
local last_qx, last_qy, last_qz, last_qw = 0, 0, 0, 0
local last_fov = 0
local last_width, last_height = 0, 0
local weight = 1
return {
	{
		name = "ssaa",
		is_enabled = function()
			return render3d.IsAntiAliasingEnabled("ssaa")
		end,
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		pre_render = function()
			if not render3d.IsAntiAliasingEnabled("ssaa") then
				count = 0
				return
			end

			local camera = render3d.GetMainCamera()
			local pos = camera:GetPosition()
			local rot = camera:GetRotation()
			local size = render.GetRenderImageSize()

			if
				pos.x ~= last_x or
				pos.y ~= last_y or
				pos.z ~= last_z or
				rot.x ~= last_qx or
				rot.y ~= last_qy or
				rot.z ~= last_qz or
				rot.w ~= last_qw or
				camera:GetFOV() ~= last_fov or
				size.x ~= last_width or
				size.y ~= last_height
			then
				count = 0
			end

			last_x, last_y, last_z = pos.x, pos.y, pos.z
			last_qx, last_qy, last_qz, last_qw = rot.x, rot.y, rot.z, rot.w
			last_fov = camera:GetFOV()
			last_width, last_height = size.x, size.y
			count = count + 1

			if count > sample_count:Get() then
				weight = 0
				count = count - 1
				return
			end

			weight = 1 / count
			camera:SetJitter(Vec2(halton(count, 2) - 0.5, halton(count, 3) - 0.5))
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "ssaa_data",
					binding_index = 2,
					block = {
						{"source_tex", "int"},
						{"history_tex", "int"},
						{"weight", "float"},
						post_source.pre_exposure_block,
					},
					write = function(self, block)
						local frame = system.GetFrameNumber()
						block.source_tex = self:GetTextureIndex(post_source.GetRawSceneSourceTexture())
						block.history_tex = self:GetTextureIndex(render3d.pipelines.ssaa:GetFramebuffer((frame + 1) % 2 + 1):GetAttachment(1))
						block.weight = weight
						post_source.WritePreExposureBlock(self, block)
						return block
					end,
				},
			},
			shader = [[
]] .. post_source.GetCompressGLSL() .. post_source.GetPreExposureGLSL("ssaa_data") .. [[

			void main() {
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				vec4 current = texelFetch(TEXTURE(ssaa_data.source_tex), pixel, 0);
				vec3 history = texelFetch(TEXTURE(ssaa_data.history_tex), pixel, 0).rgb;

				if (ssaa_data.weight >= 1.0) {
					set_color(current);
					return;
				}

				float exposure = ssaa_data.pre_exposure_tex != -1 ? ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
				// the history was pre-exposed for last frame. the average is of what is
				// shown, the exposed and compressed colour, so a bright sample can't
				// outweigh the rest
				history *= get_pre_exposure() / get_previous_pre_exposure();
				vec3 result = mix(compress(history, exposure), compress(current.rgb, exposure), ssaa_data.weight);
				set_color(vec4(decompress(result, exposure), current.a));
			}
		]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
