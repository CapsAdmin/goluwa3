local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local translucent_moments = import("goluwa/render3d/translucent_moments.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local surface_effects = import("goluwa/render3d/surface_effects.lua")
local sheets = {}
sheets.name = "surface_effect_sheets"
sheets.PER_SITE = 4
sheets.OPACITY = 0.75
sheets.GLOW = 0.35
local kinds = surface_effects.kinds

function sheets.IsActive()
	return render3d.IsPassEnabled("translucent") and
		surface_effects.GetSiteCount() > 0 and
		surface_effects.GetSitesAddress() ~= 0
end

event.AddListener("PreDraw3DTranslucent", "surface_effect_sheets", function()
	if sheets.IsActive() then render3d.ExtendTranslucentDepthRange(0.1, 300) end
end)

local draw_block = {
	name = "sheet_draw",
	binding_index = 3,
	block = {
		render3d.camera_block,
		post_source.pre_exposure_block,
		{"b0_tex", "int"},
		{"moments_tex", "int"},
		{"depth_warp", "vec2"},
		{"depth_tex", "int"},
		{"noise_tex", "int"},
		{"sites", "uint64_t"},
		{"time", "float"},
		{"wind", "vec3"},
		{
			"sheet_kinds",
			{
				{"height", "float"},
				{"width", "float"},
				{"lift", "float"},
				{"spread", "float"},
				{"count", "int"},
				{"value_index", "int"},
			},
			#kinds,
		},
	},
	write = function(self, block)
		render3d.WriteCameraBlock(self, block)
		post_source.WritePreExposureBlock(self, block)
		local b0, moments = translucent_moments.GetTextures()
		block.b0_tex = self:GetTextureIndex(b0)
		block.moments_tex = self:GetTextureIndex(moments)
		translucent_moments.WriteDepthWarp(block.depth_warp)
		block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
		block.noise_tex = self:GetTextureIndex(surface_effects.GetNoiseTexture())
		block.sites = surface_effects.GetSitesAddress()
		block.time = surface_effects.GetTime()
		atmosphere.GetWind():CopyToFloatPointer(block.wind)

		for _, kind in ipairs(kinds) do
			local entry = block.sheet_kinds[kind.index]
			local sheet = kind.sheet

			if sheet then
				entry.height = sheet.Height
				entry.width = sheet.Width
				entry.lift = sheet.Lift
				entry.spread = sheet.Spread
				entry.count = math.min(sheet.Count, sheets.PER_SITE)
				entry.value_index = sheet.Value
			else
				entry.count = 0
			end
		end

		return block
	end,
	upload_scope = "frame",
}
local vertex_outputs = {
	{"position", "vec3"},
	{"uv", "vec2"},
	{"value", "float"},
	{"seed", "float"},
	{"phase", "vec2"},
	{"kind", "float"},
	{"fade", "float"},
}

function sheets.Draw(pipeline, cmd)
	if not pipeline then return end

	pipeline:UploadConstants()
	cmd:Draw(4, surface_effects.GetSiteCount() * sheets.PER_SITE, 0, 0)
end

function sheets.BuildPasses()
	local functions = {}
	local cases = {}

	for _, kind in ipairs(kinds) do
		if kind.sheet then
			functions[#functions + 1] = string.format(
				"vec4 %s_sheet(vec2 uv, float value, float seed, float time) {\n%s\n}\n",
				kind.name,
				kind.sheet.glsl
			)
			cases[#cases + 1] = string.format(
				"case %du: result = %s_sheet(in_uv, in_value, in_seed, mod(sheet_draw.time * in_phase.y + in_phase.x, 1000.0)); break;",
				kind.index,
				kind.name
			)
		end
	end

	local vertex = {
		outputs = vertex_outputs,
		uniform_buffers = {draw_block},
		shader = glsl_common.GetHashGLSL() .. surface_effects.GetSitesGLSL() .. [[
					void main() {
						uint site_index = uint(gl_InstanceIndex) / ]] .. sheets.PER_SITE .. [[u;
						uint sheet = uint(gl_InstanceIndex) % ]] .. sheets.PER_SITE .. [[u;
						SurfaceEffectSite site = SurfaceEffectSites(sheet_draw.sites).s[site_index];
						uint kind = site.kind_seed & 15u;
						sheet_kinds_t k = sheet_draw.sheet_kinds[kind];
						float value = site.values[k.value_index];

						if (sheet >= uint(k.count) || value <= 0.002) {
							gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
							out_position = vec3(0.0);
							out_uv = vec2(0.0);
							out_value = 0.0;
							out_seed = 0.0;
							out_phase = vec2(0.0);
							out_kind = 0.0;
							out_fade = 0.0;
							return;
						}

						vec3 r = pcg3d_unorm(uvec3(site.kind_seed >> 4u, sheet, 51u));
						vec3 up = vec3(0.0, 1.0, 0.0);
						vec3 base = site.position + site.normal * k.lift + vec3(r.x - 0.5, 0.0, r.y - 0.5) * 2.0 * k.spread;
						vec3 view_dir = normalize(base - sheet_draw.camera_position);
						vec3 right = cross(view_dir, up);
						float side_on = length(right);
						right = side_on < 1e-3 ? mat3(sheet_draw.inv_view)[0] : right / side_on;
						vec3 axis = cross(right, view_dir);
						float height = k.height * mix(0.75, 1.25, r.z) * (0.45 + 0.55 * value) * mix(0.45, 1.0, side_on);
						float width = k.width * mix(0.8, 1.2, fract(r.z * 7.31)) * (0.6 + 0.4 * value);
						float across = float(gl_VertexIndex & 1) * 2.0 - 1.0;
						float along = float(gl_VertexIndex >> 1);
						height *= 1.0 + min(length(site.velocity) * 0.06, 0.6);
						vec3 lean = (vec3(sheet_draw.wind.x, 0.0, sheet_draw.wind.z) * 0.08 - site.velocity * 0.13) * height;
						float lean_length = length(lean);
						lean *= min(lean_length, height * 1.4) / max(lean_length, 1e-4);
						vec3 position = base + right * across * width * 0.5 + axis * (along - 0.1) * height + lean * along;
						out_position = position;
						out_uv = vec2(across, along);
						out_value = value;
						out_seed = fract(r.x * 13.1 + r.y * 7.7);
						vec3 phase = pcg3d_unorm(uvec3(site.kind_seed >> 4u, sheet, 77u));
						out_phase = vec2(phase.x * 1000.0, mix(0.75, 1.3, phase.y));
						out_kind = float(kind);
						out_fade = mix(0.5, 1.0, side_on);
						gl_Position = sheet_draw.projection * sheet_draw.view * vec4(position, 1.0);
					}
				]],
	}
	local fragment_common = translucent_moments.GLSL .. surface_effects.GetBlackbodyGLSL() .. [[
		vec4 sheet_noise(vec2 uv) {
			return texture(TEXTURE(sheet_draw.noise_tex), uv);
		}

		]] .. table.concat(functions, "\n") .. [[

		vec4 sample_sheet(out float distance_to_fragment) {
			ivec2 pixel = ivec2(gl_FragCoord.xy);
			float depth = texelFetch(TEXTURE(sheet_draw.depth_tex), pixel, 0).r;
			distance_to_fragment = distance(in_position, sheet_draw.camera_position);
			float soft = 1.0;

			if (depth > 0.0) {
				vec2 uv = gl_FragCoord.xy / vec2(sheet_draw.render_size);
				vec4 view_pos = sheet_draw.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
				soft = smoothstep(0.0, 0.6, length(view_pos.xyz / view_pos.w) - distance_to_fragment);
			}

			soft *= smoothstep(0.2, 0.8, distance_to_fragment) * in_fade;
			vec4 result = vec4(0.0);

			switch (uint(in_kind + 0.5)) {
				]] .. table.concat(cases, "\n") .. [[
			}

			return vec4(result.rgb * soft, min(result.a * ]] .. string.format("%.3f", sheets.OPACITY) .. [[, 0.98) * soft);
		}
	]]
	local blend = {
		CullMode = "none",
		Blend = true,
		SrcColorBlendFactor = "one",
		DstColorBlendFactor = "one",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "one",
		AlphaBlendOp = "add",
		DepthTest = true,
		DepthWrite = false,
		DepthCompareOp = "greater_or_equal",
	}
	return {
		table.merge(
			{
				name = "surface_effect_sheets_moments",
				draw_in_prerender = false,
				dont_create_framebuffers = true,
				ColorFormat = {
					{"r32_sfloat", {"b0", "r"}},
					{"r32g32b32a32_sfloat", {"moments", "rgba"}},
				},
				DepthFormat = gbuffer_layout.DEPTH_FORMAT,
				Topology = "triangle_strip",
				vertex = vertex,
				fragment = {
					uniform_buffers = {draw_block},
					shader = fragment_common .. [[
						void main() {
							float distance_to_fragment;
							vec4 sheet = sample_sheet(distance_to_fragment);

							if (sheet.a <= 0.001) discard;

							float absorbance = -log(1.0 - sheet.a);
							float depth = moments_warp_depth(distance_to_fragment, sheet_draw.depth_warp);
							float depth2 = depth * depth;
							set_b0(absorbance);
							set_moments(vec4(depth, depth2, depth2 * depth, depth2 * depth2) * absorbance);
						}
					]],
				},
				color_blend = {attachments = {{}, translucent_moments.ADDITIVE}},
			},
			blend
		),
		table.merge(
			{
				name = "surface_effect_sheets_accumulate",
				draw_in_prerender = false,
				dont_create_framebuffers = true,
				ColorFormat = {
					{"r16g16b16a16_sfloat", {"color", "rgba"}},
					{"r16g16b16a16_sfloat", {"motion", "rgba"}},
					{"r16g16b16a16_sfloat", {"additive", "rgba"}},
					{"r16g16b16a16_sfloat", {"modulate", "rgba"}},
				},
				DepthFormat = gbuffer_layout.DEPTH_FORMAT,
				Topology = "triangle_strip",
				vertex = vertex,
				fragment = {
					uniform_buffers = {draw_block},
					shader = post_source.GetPreExposureGLSL("sheet_draw") .. fragment_common .. [[
						void main() {
							float distance_to_fragment;
							vec4 sheet = sample_sheet(distance_to_fragment);

							if (sheet.a <= 0.001 && dot(sheet.rgb, vec3(1.0)) <= 0.0) discard;

							ivec2 pixel = ivec2(gl_FragCoord.xy);
							float transmittance = moments_transmittance(
								texelFetch(TEXTURE(sheet_draw.b0_tex), pixel, 0).r,
								texelFetch(TEXTURE(sheet_draw.moments_tex), pixel, 0),
								moments_warp_depth(distance_to_fragment, sheet_draw.depth_warp)
							);
							vec3 radiance = sheet.rgb / max(sheet.a, 1e-3);
							set_color(vec4(min(radiance * sheet.a * get_pre_exposure(), vec3(65504.0)), sheet.a) * transmittance);
							set_motion(vec4(0.0));
							set_additive(vec4(min(sheet.rgb * ]] .. string.format("%.3f", sheets.GLOW) .. [[ * transmittance * get_pre_exposure(), vec3(65504.0)), 0.0));
							set_modulate(vec4(1.0));
						}
					]],
				},
				color_blend = {
					attachments = {
						{},
						translucent_moments.ADDITIVE,
						translucent_moments.ADDITIVE,
						translucent_moments.MULTIPLY,
					},
				},
			},
			blend
		),
	}
end

return sheets
