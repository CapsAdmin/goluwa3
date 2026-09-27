local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = library()
-- The gbuffer's targets in attachment order: the format, the channels the
-- gbuffer shaders write through set_<name>, and the texture a pass reads
-- them from (<texture>_tex in gbuffer_layout.block). How the values are
-- packed into the channels is in the GLSL below.
gbuffer_layout.targets = {
	{
		texture = "albedo",
		format = "r8g8b8a8_srgb",
		channels = {{"albedo", "rgb"}, {"alpha", "a"}},
	},
	{
		texture = "normal",
		format = "b10g11r11_ufloat_pack32",
		channels = {{"normal", "rgb"}},
	},
	{
		texture = "mra",
		format = "r8g8b8a8_unorm",
		-- roughness is ggx alpha
		channels = {{"metallic", "r"}, {"roughness", "g"}, {"ao", "b"}, {"transmission", "a"}},
	},
	{
		texture = "emissive",
		format = "b10g11r11_ufloat_pack32",
		channels = {{"emissive", "rgb"}},
	},
	{
		texture = "transmission",
		format = "r8g8b8a8_unorm",
		channels = {
			{"transmission_scattering", "r"},
			{"transmission_tint_r", "g"},
			{"specular", "b"},
			{"transmission_tint_b", "a"},
		},
	},
	{
		texture = "velocity",
		format = "r16g16b16a16_sfloat",
		channels = {{"velocity", "rg"}, {"prev_view_depth", "b"}},
	},
}
gbuffer_layout.DEPTH_FORMAT = "d32_sfloat"
gbuffer_layout.color_format = {}
gbuffer_layout.block = {{"depth_tex", "int"}}
gbuffer_layout.attachment_index = {}

for i, target in ipairs(gbuffer_layout.targets) do
	gbuffer_layout.color_format[i] = {target.format, unpack(target.channels)}
	gbuffer_layout.block[i + 1] = {target.texture .. "_tex", "int"}
	gbuffer_layout.attachment_index[target.texture] = i
end

-- the target called name ("albedo", "normal", ...) of the main gbuffer
function gbuffer_layout.GetTexture(name)
	return render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(gbuffer_layout.attachment_index[name])
end

function gbuffer_layout.GetDepthTexture()
	return render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture()
end

function gbuffer_layout.WriteBlock(self, block)
	local framebuffer = render3d.pipelines.gbuffer:GetFramebuffer()
	block.depth_tex = self:GetTextureIndex(framebuffer:GetDepthTexture())

	for i, target in ipairs(gbuffer_layout.targets) do
		block[target.texture .. "_tex"] = self:GetTextureIndex(framebuffer:GetAttachment(i))
	end

	if not render3d.IsVelocityEnabled() then block.velocity_tex = -1 end

	return block
end

-- for the shaders writing the gbuffer
function gbuffer_layout.GetEncodeGLSL()
	return [[
		vec3 gbuffer_encode_normal(vec3 N) {
			return N * 0.5 + 0.5;
		}

		// a multiplier of 1 is dielectric F0 0.04; up to 2 fits
		float gbuffer_encode_specular(float multiplier) {
			return clamp(multiplier * 0.5, 0.0, 1.0);
		}

		// red and blue, halved to fit up to 2. the tint's luminance is 1, which
		// gives the green back
		vec2 gbuffer_encode_transmission_tint(vec3 tint) {
			return tint.rb * 0.5;
		}
	]]
end

do
	local decoders = [[
		vec3 gbuffer_albedo(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).rgb; }
		float gbuffer_alpha(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).a; }
		float gbuffer_depth(COORD c) { return gbuffer_fetch(GBUFFER.depth_tex, c).r; }
		vec3 gbuffer_normal(COORD c) { return gbuffer_fetch(GBUFFER.normal_tex, c).xyz * 2.0 - 1.0; }
		float gbuffer_metallic(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).r; }
		float gbuffer_roughness(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).g; }
		float gbuffer_ao(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).b; }
		float gbuffer_transmission(COORD c) { return gbuffer_fetch(GBUFFER.mra_tex, c).a; }
		vec3 gbuffer_emissive(COORD c) { return gbuffer_fetch(GBUFFER.emissive_tex, c).rgb; }
		float gbuffer_transmission_scattering(COORD c) { return gbuffer_fetch(GBUFFER.transmission_tex, c).r; }
		float gbuffer_dielectric_f0(COORD c) { return gbuffer_fetch(GBUFFER.transmission_tex, c).b * 0.08; }

		vec3 gbuffer_transmission_color(COORD c) {
			vec4 packed = gbuffer_fetch(GBUFFER.transmission_tex, c);
			float r = packed.g * 2.0;
			float b = packed.a * 2.0;
			return vec3(r, max((1.0 - 0.2126 * r - 0.0722 * b) / 0.7152, 0.0), b);
		}
	]]
	local code = [[
		vec4 gbuffer_fetch(int tex, vec2 uv) {
			return texture(TEXTURE(tex), uv);
		}

		vec4 gbuffer_fetch(int tex, ivec2 pixel) {
			return texelFetch(TEXTURE(tex), pixel, 0);
		}
	]] .. decoders:gsub("COORD", "vec2") .. decoders:gsub("COORD", "ivec2")

	-- reading what GetEncodeGLSL packed, at a uv or a pixel. block_name is the
	-- uniform block holding gbuffer_layout.block
	function gbuffer_layout.GetDecodeGLSL(block_name)
		return (code:gsub("GBUFFER%.", block_name .. "."))
	end
end

return gbuffer_layout
