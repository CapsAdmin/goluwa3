local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local texture_compress = import("goluwa/render/texture_compress.lua")
local codec = import("goluwa/codec.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local fs = import("goluwa/filesystem/fs.lua")
local crypto = import("goluwa/crypto.lua")
local objects = import("goluwa/objects/objects.lua")
local material_bake = {}
material_bake.estimators = {albedo = true, roughness = true, normal = true}
material_bake.estimator_params = {
	flatten = 0.35,
	local_contrast = 0.4,
	saturation = 0.8,
	normal = 0.5,
	normal_noise = 0.33,
}
material_bake.CacheDirectory = "storage/cache/baked_materials/"
pvars.StartGroup("Rendering", "Materials", {store = false})
material_bake.enabled = pvars.Setup2{
	key = "r_bake_materials",
	default = true,
	help = "bakes what a material's flags derive (roughness, metallic, normals, tints) and the estimators into compressed textures once, cached under storage/cache. the vmt loader requests it",
}
pvars.EndGroup()
local stats = {baked = 0, cached = 0, skipped = {}, failed = 0, requested = 0, processed = 0}
local queue = {}
local frame = 0
local READY_FRAME_DELAY = 3
local queued = setmetatable({}, {__mode = "k"})
local pipeline
local quad
local identity = Matrix44()

local function get_quad()
	if not quad then
		quad = Polygon3D.New()
		local normal = Vec3(0, 0, 1)
		local tangent = {x = 1, y = 0, z = 0, w = 1}

		local function add(x, y)
			quad:AddVertex{
				pos = Vec3(x * 2 - 1, y * 2 - 1, 0),
				uv = Vec2(x, y),
				normal = normal,
				tangent = tangent,
			}
		end

		add(0, 0)
		add(1, 0)
		add(0, 1)
		add(0, 1)
		add(1, 0)
		add(1, 1)
		quad:BuildBoundingBox()
		quad:Upload()
	end

	return quad
end

local render_tileable = false
local render_normal_estimate = true
local render_texel = 1 / 256

local function get_uniform_buffers()
	local buffers = {
		{
			name = "bake_data",
			block = {
				{"camera_position", "vec3"},
				{"terrain_only", "int"},
				{"normal_map_strength", "float"},
				{"noise_phase", "float"},
				{"estimate_albedo", "int"},
				{"estimate_tileable", "int"},
				{"estimate_roughness", "int"},
				{"estimate_texel", "float"},
				{"estimate_flatten", "float"},
				{"estimate_local_contrast", "float"},
				{"estimate_saturation", "float"},
				{"estimate_normal", "int"},
				{"estimate_normal_strength", "float"},
				{"estimate_normal_noise", "float"},
			},
			write = function(self, block)
				block.camera_position[0] = 0
				block.camera_position[1] = 0
				block.camera_position[2] = 0
				block.terrain_only = 0
				block.normal_map_strength = 1
				block.noise_phase = 0
				block.estimate_albedo = material_bake.estimators.albedo and 1 or 0
				block.estimate_tileable = render_tileable and 1 or 0
				block.estimate_roughness = material_bake.estimators.roughness and 1 or 0
				block.estimate_texel = render_texel
				block.estimate_flatten = material_bake.estimator_params.flatten
				block.estimate_local_contrast = material_bake.estimator_params.local_contrast
				block.estimate_saturation = material_bake.estimator_params.saturation
				block.estimate_normal = (material_bake.estimators.normal and render_normal_estimate) and 1 or 0
				block.estimate_normal_noise = material_bake.estimator_params.normal_noise
				block.estimate_normal_strength = material_bake.estimator_params.normal
				return block
			end,
		},
	}

	for _, buffer in ipairs(model_pipeline.GetPBRUniformBuffers()) do
		buffers[#buffers + 1] = buffer
	end

	return buffers
end

local BAKE_FRAGMENT = [[

			vec3 blurred_albedo(vec2 uv, float radius) {
				vec3 sum = vec3(0.0);

				for (int i = 0; i < 12; i++) {
					float angle = float(i) * 2.399963;
					float distance = sqrt((float(i) + 0.5) / 12.0) * radius;
					sum += get_albedo_world(uv + vec2(cos(angle), sin(angle)) * distance, vec3(0.0));
				}

				return sum / 12.0;
			}

			vec3 estimate_albedo(vec3 albedo, vec2 uv) {
				if (bake_data.estimate_albedo == 0) return albedo;

				float lum = max(luminance(albedo), 0.001);

				if (bake_data.estimate_tileable != 0) {
					float mid_lum = max(luminance(blurred_albedo(uv, 0.06)), 0.001);
					float coarse_lum = max(luminance(blurred_albedo(uv, 0.3)), 0.001);
					float global_lum = 0.25 * (
						luminance(blurred_albedo(uv + vec2(0.25, 0.25), 0.3)) +
						luminance(blurred_albedo(uv + vec2(0.75, 0.25), 0.3)) +
						luminance(blurred_albedo(uv + vec2(0.25, 0.75), 0.3)) +
						luminance(blurred_albedo(uv + vec2(0.75, 0.75), 0.3))
					);
					albedo *= clamp(pow(global_lum / coarse_lum, bake_data.estimate_flatten), 0.6, 1.6);
					albedo *= clamp(pow(lum / mid_lum, -bake_data.estimate_local_contrast), 0.7, 1.4);
				}

				float high = max(albedo.r, max(albedo.g, albedo.b));
				float saturation = high > 0.001 ? (high - min(albedo.r, min(albedo.g, albedo.b))) / high : 0.0;

				if (saturation > 0.001) {
					albedo = vec3(high) - (vec3(high) - albedo) * (pow(saturation, bake_data.estimate_saturation) / saturation);
				}

				vec3 smooth_albedo = blurred_albedo(uv, bake_data.estimate_texel * 4.0);
				float local_lum = luminance(smooth_albedo);
				float darkness = 1.0 - smoothstep(0.003, 0.02, local_lum);
				albedo = mix(albedo, smooth_albedo, 0.5 * darkness);
				float lift = clamp(0.035 / max(local_lum, 0.0005), 1.0, 6.0);
				vec2 grain_seed = gl_FragCoord.xy;
				float grain = fract(sin(dot(grain_seed, vec2(12.9898, 78.233))) * 43758.5453) + fract(sin(dot(grain_seed, vec2(39.3468, 11.135))) * 24634.6345) - 1.0;
				albedo = albedo * lift + vec3(0.006) + vec3(grain * 0.0006 * lift * darkness);
				return albedo * min(1.0, 0.9 / max(max(albedo.r, albedo.g), max(albedo.b, 0.001)));
			}

			float noise_hash(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
			}

			float value_noise(vec2 p) {
				vec2 cell = floor(p);
				vec2 f = fract(p);
				f = f * f * (3.0 - 2.0 * f);
				return mix(mix(noise_hash(cell), noise_hash(cell + vec2(1.0, 0.0)), f.x), mix(noise_hash(cell + vec2(0.0, 1.0)), noise_hash(cell + vec2(1.0, 1.0)), f.x), f.y);
			}

			float shading_height(vec2 uv) {
				vec2 source_size = vec2(textureSize(TEXTURE(model.AlbedoTexture), 0));
				float source_texel = 1.0 / max(source_size.x, source_size.y);
				vec2 warp = (vec2(value_noise(uv * source_size * 0.9), value_noise(uv * source_size * 0.9 + 17.3)) - 0.5) * bake_data.estimate_normal_noise / source_size;
				vec2 p = uv + warp;
				float small = max(luminance(blurred_albedo(p, source_texel * 2.0)), 0.002);
				float large = max(luminance(blurred_albedo(p, source_texel * 16.0)), 0.002);
				float height = clamp(log(small / large), -0.6, 0.15) + (value_noise(uv * source_size * 2.3 + 5.1) - 0.5) * 0.06 * bake_data.estimate_normal_noise;
				return height * smoothstep(0.01, 0.04, small);
			}

			vec3 estimate_normal(vec3 n, vec2 uv) {
				vec2 source_size = vec2(textureSize(TEXTURE(model.AlbedoTexture), 0));
				float step_size = bake_data.estimate_texel * 1.5;
				vec2 slope = vec2(
					shading_height(uv + vec2(step_size, 0.0)) - shading_height(uv - vec2(step_size, 0.0)),
					shading_height(uv + vec2(0.0, step_size)) - shading_height(uv - vec2(0.0, step_size))
				) * (2.0 / (step_size * max(source_size.x, source_size.y)));
				return normalize(vec3(n.xy - slope * bake_data.estimate_normal_strength, n.z));
			}

			float estimate_roughness(float perceptual, vec2 uv) {
				float radius = bake_data.estimate_texel * 3.0;
				float lum_mean = 0.0;
				float lum_square = 0.0;
				vec2 slope_mean = vec2(0.0);
				vec2 slope_square = vec2(0.0);

				for (int i = 0; i < 12; i++) {
					float angle = float(i) * 2.399963;
					vec2 offset = vec2(cos(angle), sin(angle)) * sqrt((float(i) + 0.5) / 12.0) * radius;
					float lum = luminance(get_albedo_world(uv + offset, vec3(0.0)));
					vec2 slope = get_normal_map(uv + offset).xy;
					lum_mean += lum;
					lum_square += lum * lum;
					slope_mean += slope;
					slope_square += slope * slope;
				}

				lum_mean /= 12.0;
				vec2 slope_variance = max(slope_square / 12.0 - (slope_mean / 12.0) * (slope_mean / 12.0), vec2(0.0));
				float contrast = sqrt(max(lum_square / 12.0 - lum_mean * lum_mean, 0.0)) / max(lum_mean, 0.02);
				float alpha = perceptual * perceptual;
				alpha = sqrt(alpha * alpha + 2.0 * (slope_variance.x + slope_variance.y));
				return clamp(sqrt(alpha) + 0.35 * clamp(contrast - 0.2, -0.1, 0.5), 0.04, 1.0);
			}

			void main() {
				vec2 uv = in_uv;
				Surface s;
				init_surface_features(s, uv);

				if (bake_data.estimate_roughness != 0 && get_roughness_texel(uv) < 0.0) {
					float perceptual = estimate_roughness(sqrt(s.roughness_alpha), uv);
					s.roughness_alpha = perceptual * perceptual;
				}

				float alpha = get_alpha_uv(uv);
				vec3 albedo = estimate_albedo(get_albedo_world(uv, vec3(0.0)), uv);

				vec3 n = get_normal_map(uv);

				if (bake_data.estimate_normal != 0 && model.NormalTexture == -1 && !has_heightmap() && model.AlbedoTexture != -1) {
					n = estimate_normal(n, uv);
				}
				set_bake_albedo(vec4(albedo, alpha));
				set_bake_normal(vec4(n.xy * 0.5 + 0.5, 0.0, 1.0));
				set_bake_mr(vec4(s.metallic, sqrt(s.roughness_alpha), clamp(s.specular * 0.5, 0.0, 1.0), 0.0));
				set_bake_emissive(vec4(get_emissive(uv) / EMISSIVE_REFERENCE_LUMINANCE, 1.0));
			}
]]
local get_fragment_source

do
	local source

	function get_fragment_source()
		source = source or model_pipeline.BuildPBRSurfaceGlsl("bake_data") .. BAKE_FRAGMENT
		return source
	end
end

local function to_hex(raw)
	return (raw:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- the cache is valid for exactly this source: this file, the encoder and the generated surface shader
do
	local version

	function material_bake.GetVersion()
		if not version then
			version = "v" .. to_hex(
					crypto.SHA1(
						fs.read_file("goluwa/render3d/material_bake.lua") .. fs.read_file("goluwa/render/texture_compress.lua") .. get_fragment_source()
					)
				):sub(1, 10)
		end

		return version
	end
end

local function create_pipeline()
	return EasyPipeline.New{
		name = "material_bake",
		dont_create_framebuffers = true,
		ColorFormat = {
			{"r8g8b8a8_srgb", {"bake_albedo", "rgba"}},
			{"r8g8b8a8_unorm", {"bake_normal", "rgba"}},
			{"r8g8b8a8_unorm", {"bake_mr", "rgba"}},
			{"r8g8b8a8_srgb", {"bake_emissive", "rgba"}},
		},
		RasterizationSamples = "1",
		vertex = model_pipeline.CreateVertexStage{
			normal = true,
			tangent = true,
			uv = true,
			enable_vertex_animation = false,
			get_projection_view_world_matrix = function()
				return identity
			end,
		},
		fragment = {
			uniform_buffers = get_uniform_buffers(),
			shader = get_fragment_source(),
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
		Blend = false,
		ColorWriteMask = "rgba",
		on_draw = function(self)
			self:UploadConstants()
			get_quad():Draw()
		end,
	}
end

-- Evaluates the material's own surface shader code over uv space into render targets, one texel per
-- uv texel: albedo (rgb in the encoding of the target, alpha is the material's alpha), normal (xy in rg)
-- and metallic, roughness, specular scale in rgb. Returns the framebuffer, its attachments are
-- Textures 1 to 4: the fourth is the emissive color without the multiplier, which stays on the material.
-- skip_normal_estimate leaves the normal of a material without one flat (Bake renders that normal
-- on its own at twice the size).
function material_bake.Render(material, width, height, skip_normal_estimate)
	pipeline = pipeline or create_pipeline()
	local framebuffer = Framebuffer.New{
		width = width,
		height = height,
		formats = {"r8g8b8a8_srgb", "r8g8b8a8_unorm", "r8g8b8a8_unorm", "r8g8b8a8_srgb"},
		clear_colors = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}},
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
	local previous_material = render3d.GetMaterial()
	local previous_world = render3d.GetWorldMatrix()
	render_tileable = not tostring(material.vmt_path):find("^materials/models/")
	render_texel = 1 / width
	render_normal_estimate = not skip_normal_estimate
	local micro_detail = material:GetMicroDetailTexture()
	local emissive_multiplier = material:GetEmissiveMultiplier()
	local specular_multiplier = material:GetSpecularMultiplier()
	material:SetSpecularMultiplier(1)
	material:SetMicroDetailTexture(nil)
	material:SetEmissiveMultiplier(Color(1, 1, 1, 1))
	render3d.SetMaterial(material)
	render3d.SetWorldMatrix(identity)
	local ok, err = xpcall(
		function()
			pipeline:Draw(framebuffer:GetCommandBuffer(), framebuffer)
		end,
		debug.traceback
	)
	render3d.SetMaterial(previous_material)
	render3d.SetWorldMatrix(previous_world)
	material:SetMicroDetailTexture(micro_detail)
	material:SetEmissiveMultiplier(emissive_multiplier)
	material:SetSpecularMultiplier(specular_multiplier)

	if not ok then error(err, 0) end

	return framebuffer
end

-- Bakes the material into three compressed textures, returned as dds strings:
-- Albedo (bc7 srgb, alpha is the material's alpha), Normal (bc5, the xy the shader would use) and
-- MetallicRoughness (bc7 linear: r metallic, g roughness, b specular scale / 2 with the cavity damping in it).
-- Emissive (bc7 srgb, the color before EmissiveMultiplier) is added when the material emits.
-- Texture transforms are not part of the bake, they stay on the material.
function material_bake.WantsNormalEstimate(material)
	return material_bake.estimators.normal and
		not material:GetNormalTexture()
		and
		not (
			material:GetHeightTexture() and
			material:GetHeightScale() > 0
		)
		and
		material:GetAlbedoTexture() ~= nil
end

function material_bake.Bake(material, width, height)
	local estimate_normal = material_bake.WantsNormalEstimate(material)
	local framebuffer = material_bake.Render(material, width, height, estimate_normal)
	local result = {
		Albedo = texture_compress.Recompress{
			sources = {{texture = framebuffer:GetAttachment(1)}},
			edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return vec4(from_linear(texel.rgb), texel.a); }",
			format = "bc7",
			kind = "srgb",
			wrap = true,
		},
		Normal = texture_compress.Recompress{
			sources = {{texture = framebuffer:GetAttachment(2)}},
			format = "bc5",
			kind = "normal",
			wrap = true,
		},
		MetallicRoughness = texture_compress.Recompress{
			sources = {{texture = framebuffer:GetAttachment(3)}},
			format = "bc7",
			kind = "linear",
			wrap = true,
		},
	}

	if material_bake.GetLayerKind(material) == "blend" then
		local layer2 = material:Copy()
		layer2:SetAlbedoTexture(material:GetAlbedo2Texture())

		if material:GetNormal2Texture() then
			layer2:SetNormalTexture(material:GetNormal2Texture())
			layer2:SetNormalMapMultiplier(1)
		end

		layer2:SetAlbedo2Texture(nil)
		layer2:SetNormal2Texture(nil)
		layer2:SetBlendTexture(nil)
		layer2.vmt_path = material.vmt_path
		local width2, height2 = 4, 4

		for _, texture in ipairs{material:GetAlbedo2Texture(), material:GetNormal2Texture() or false} do
			if texture then
				width2, height2 = math.max(width2, texture:GetWidth()), math.max(height2, texture:GetHeight())
			end
		end

		local framebuffer2 = material_bake.Render(layer2, width2, height2, true)
		result.Albedo2 = texture_compress.Recompress{
			sources = {{texture = framebuffer2:GetAttachment(1)}},
			edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return vec4(from_linear(texel.rgb), texel.a); }",
			format = "bc7",
			kind = "srgb",
			wrap = true,
		}

		if material:GetNormal2Texture() then
			result.Normal2 = texture_compress.Recompress{
				sources = {{texture = framebuffer2:GetAttachment(2)}},
				format = "bc5",
				kind = "normal",
				wrap = true,
			}
		end

		result.MetallicRoughness2 = texture_compress.Recompress{
			sources = {{texture = framebuffer2:GetAttachment(3)}},
			format = "bc7",
			kind = "linear",
			wrap = true,
		}
		framebuffer2:Remove()
		layer2:Remove()
	end

	if estimate_normal then
		local normal_framebuffer = material_bake.Render(material, math.min(width * 2, 2048), math.min(height * 2, 2048))
		result.Normal = texture_compress.Recompress{
			sources = {{texture = normal_framebuffer:GetAttachment(2)}},
			format = "bc5",
			kind = "normal",
			wrap = true,
		}
		normal_framebuffer:Remove()
	end

	if material_bake.Emits(material) then
		result.Emissive = texture_compress.Recompress{
			sources = {{texture = framebuffer:GetAttachment(4)}},
			edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return vec4(from_linear(texel.rgb), texel.a); }",
			format = "bc7",
			kind = "srgb",
			wrap = true,
		}
	end

	framebuffer:Remove()
	return result
end

local function is_identity(u, v)
	return u.x == 1 and u.y == 0 and u.z == 0 and v.x == 0 and v.y == 1 and v.z == 0
end

-- nil: one layer. "multiply": the second albedo only modulates the first, a bake of the whole is
-- exact. "blend": the vertex blend weight mixes two layers, each layer is baked and the shader
-- mixes them. "unsupported": a blend whose layers cannot be baked separately.
function material_bake.GetLayerKind(material)
	local albedo2 = material:GetAlbedo2Texture()
	local normal2 = material:GetNormal2Texture()
	local blend = material:GetBlendTexture()

	if not (albedo2 or normal2 or blend) then return nil end

	if albedo2 and material:GetMultiplyAlbedo2() and not normal2 and not blend then
		return "multiply"
	end

	if
		not albedo2 or
		material:GetMultiplyAlbedo2() or
		material:GetBlendTintByBaseAlpha() or
		material:GetAlbedoTextureAlphaIsRoughness() or
		not is_identity(material:GetTexture2TransformU(), material:GetTexture2TransformV())
	then
		return "unsupported"
	end

	return "blend"
end

function material_bake.Emits(material)
	return material:GetEmissiveTexture() ~= nil or
		material:GetAlbedoAlphaIsEmissive() or
		material:GetMetallicTextureAlphaIsEmissive()
end

-- what the bake does not cover yet: blends whose layers cannot be baked apart, terrain, additive
-- materials, texture transforms (the baked textures are the untransformed content, the
-- transforms stay on the material but one packed texture could not follow three of them) and the
-- specular masks. Returns true, or false and the reason.
function material_bake.CanBake(material)
	if material.has_proxies then return false, "proxies" end

	if material:GetNoDraw() then return false, "nodraw" end

	if not material:GetAlbedoTexture() and not material:GetNormalTexture() then
		return false, "no textures"
	end

	local kind = material_bake.GetLayerKind(material)

	if kind == "unsupported" then return false, "blend" end

	if kind == "blend" and material_bake.Emits(material) then
		return false, "blend emissive"
	end

	if material:GetTerrainMaterialTexture() or material:GetGroundColorTexture() then
		return false, "terrain"
	end

	if material.Additive then return false, "additive" end

	if
		material:GetRoughnessMaskOnlyScalesSpecular() or
		material:GetSpecularFromRoughnessMask()
	then
		return false, "specular mask"
	end

	if
		not is_identity(material:GetBaseTextureTransformU(), material:GetBaseTextureTransformV()) or
		not is_identity(material:GetBumpTransformU(), material:GetBumpTransformV())
	then
		return false, "texture transform"
	end

	return true
end

-- replaces the textures and every property that only existed to derive them with the baked set
local SRGB_SLOTS = {Albedo = true, Albedo2 = true, Emissive = true}

function material_bake.CreateTextures(baked)
	local textures = {}

	for slot, data in pairs(baked) do
		textures[slot] = Texture.New{
			decoded = assert(codec.DecodeData("baked.dds", data)),
			srgb = SRGB_SLOTS[slot] or false,
		}
	end

	return textures
end

function material_bake.Apply(material, textures)
	if textures.Albedo2 then
		textures.Albedo2.is_grass_texture = Material.IsGrassTexture(material:GetAlbedo2Texture())
	end

	material:SetAlbedoTexture(textures.Albedo)
	material:SetNormalTexture(textures.Normal)
	material:SetMetallicRoughnessTexture(textures.MetallicRoughness)
	material:SetMetallicRoughnessIsMR(true)
	material:SetPackedSpecularScale(2)
	material:SetAlbedo2Texture(textures.Albedo2)
	material:SetNormal2Texture(textures.Normal2)
	material:SetMetallicRoughness2Texture(textures.MetallicRoughness2)

	if textures.Emissive then
		material:SetEmissiveTexture(textures.Emissive)
		material:SetEmissiveTextureIsColor(true)
		material:SetAlbedoAlphaIsEmissive(false)
		material:SetMetallicTextureAlphaIsEmissive(false)
	end

	material:SetColorMultiplier(Color(1, 1, 1, 1))
	material:SetBlendTintByBaseAlpha(false)
	material:SetMultiplyAlbedo2(false)
	material:SetNormalMapMultiplier(1)
	material:SetNormalTextureIsSSBump(false)
	material:SetNormalTextureAlphaIsRoughness(false)
	material:SetNormalAlphaIsCoverage(false)
	material:SetMetallicTexture(nil)
	material:SetRoughnessTexture(nil)
	material:SetRoughnessMultiplier(1)
	material:SetRoughnessMin(0)
	material:SetRoughnessMax(1)
	material:SetInvertRoughnessTexture(false)
	material:SetMetallicMultiplier(1)
	material:SetMetallicMaskMin(0)
	material:SetMetallicMaskMax(1)
	material:SetMetallicFromRoughnessMask(false)
	material:SetAlbedoTextureAlphaIsRoughness(false)
	material:SetAlbedoLuminanceIsRoughness(false)
	material:SetDerivedRoughnessAlbedo(0)
	material:SetDerivedRoughnessNormal(0)
	material:SetDerivedRoughnessMetal(0)
	material:SetDerivedSpecularCavity(0)
	material:SetDerivedSpecularRoughness(0)
	material.baked = true
end

local SKIPPED_VARIABLES = {Name = true, Flags = true, OriginalMaterial = true}
local TEXTURE_GETTERS = {
	"GetAlbedoTexture",
	"GetNormalTexture",
	"GetMetallicRoughnessTexture",
	"GetMetallicTexture",
	"GetRoughnessTexture",
	"GetEmissiveTexture",
}
local READY_GETTERS = {unpack(TEXTURE_GETTERS)}
table.insert(READY_GETTERS, "GetAlbedo2Texture")
table.insert(READY_GETTERS, "GetNormal2Texture")

-- a key for everything the bake reads: every property and the identity of the textures, nil when a
-- texture has no path to identify it by
function material_bake.GetKey(material)
	local parts = {material_bake.GetVersion()}

	for _, info in ipairs(objects.GetStorableVariables(material)) do
		if not SKIPPED_VARIABLES[info.var_name] then
			local value = material[info.get_name](material)

			if type(value) == "table" and value.config then
				if not value.config.path then return nil end

				value = value.config.path .. "|" .. tostring(value.config.srgb)
			end

			parts[#parts + 1] = info.var_name .. "=" .. tostring(value)
		end
	end

	table.sort(parts)
	local hash = to_hex(crypto.SHA1(table.concat(parts, "\n")))
	local name = material.vmt_path:gsub("^materials/maps/[^/]+/", ""):gsub("^materials/", ""):gsub("%.vmt$", ""):gsub("_%-?%d+_%-?%d+_%-?%d+$", ""):gsub("[^%w]+", "_"):sub(1, 80)
	return name .. "_" .. hash
end

local FILES = {
	Albedo = "albedo.dds",
	Normal = "normal.dds",
	MetallicRoughness = "metallicroughness.dds",
	Emissive = "emissive.dds",
	Albedo2 = "albedo2.dds",
	Normal2 = "normal2.dds",
	MetallicRoughness2 = "metallicroughness2.dds",
}

local function slots_of(material)
	local slots = {"Albedo", "Normal", "MetallicRoughness"}

	if material_bake.Emits(material) then slots[#slots + 1] = "Emissive" end

	if material_bake.GetLayerKind(material) == "blend" then
		slots[#slots + 1] = "Albedo2"
		slots[#slots + 1] = "MetallicRoughness2"

		if material:GetNormal2Texture() then slots[#slots + 1] = "Normal2" end
	end

	return slots
end

local function cache_path(key)
	return material_bake.CacheDirectory .. material_bake.GetVersion() .. "/" .. key .. "/"
end

local function has_cache(material, key)
	for _, slot in ipairs(slots_of(material)) do
		if not fs.exists(cache_path(key) .. FILES[slot]) then return false end
	end

	return true
end

local function save_cache(key, baked)
	assert(fs.create_directory_recursive(cache_path(key)))

	for slot, data in pairs(baked) do
		assert(fs.write_file(cache_path(key) .. FILES[slot], data))
	end
end

do
	local pruned = false

	function material_bake.PruneCache(force)
		if pruned and not force then return end

		pruned = true
		local current = material_bake.GetVersion()

		for _, name in ipairs(fs.get_files(material_bake.CacheDirectory) or {}) do
			if name ~= current then
				assert(fs.remove_directory_recursive(material_bake.CacheDirectory .. name))
			end
		end
	end
end

local function apply_cached(material, generation, key)
	material_bake.ReleaseAdjustments(material, false)
	material_bake.LoadDeferred(material, true)
	local directory = cache_path(key)
	local textures = {}
	local pending = 0

	local function ready()
		pending = pending - 1

		if pending > 0 then return end

		stats.processed = stats.processed + 1

		if material.baked or material.vmt_generation ~= generation then return end

		stats.cached = stats.cached + 1
		material_bake.Apply(material, textures)
	end

	for _, slot in ipairs(slots_of(material)) do
		textures[slot] = Texture.New{path = directory .. FILES[slot], srgb = SRGB_SLOTS[slot] or false}
		pending = pending + 1
	end

	for _, texture in pairs(textures) do
		texture:AddOnReady(ready)
	end
end

local function process(material, generation, key)
	stats.processed = stats.processed + 1

	if material.baked or material.vmt_generation ~= generation then return end

	if has_cache(material, key) then
		stats.processed = stats.processed - 1
		return apply_cached(material, generation, key)
	end

	local width, height = 0, 0

	for _, getter in ipairs(READY_GETTERS) do
		local texture = material[getter](material)

		if texture then
			assert(
				texture:IsReady(),
				"baking " .. tostring(material.vmt_path) .. " but " .. getter .. " is not loaded: " .. tostring(texture.config.path)
			)

			if texture:IsFallback() then
				stats.skipped["missing texture"] = (stats.skipped["missing texture"] or 0) + 1
				return
			end

			if getter ~= "GetAlbedo2Texture" and getter ~= "GetNormal2Texture" then
				width, height = math.max(width, texture:GetWidth()), math.max(height, texture:GetHeight())
			end
		end
	end

	if width < 4 or height < 4 then
		stats.skipped["texture too small"] = (stats.skipped["texture too small"] or 0) + 1
		return
	end

	local baked = material_bake.Bake(material, width, height)
	save_cache(key, baked)
	stats.baked = stats.baked + 1
	material_bake.Apply(material, material_bake.CreateTextures(baked))
	return true
end

do
	local BAKED_SLOTS = {}

	for _, getter in ipairs(READY_GETTERS) do
		BAKED_SLOTS[getter] = true
	end

	function material_bake.ReleaseAdjustments(material, run)
		local pending = material.deferred_adjustments
		material.deferred_adjustments = nil

		if run and pending then
			for _, entry in ipairs(pending) do
				entry[1]:AddOnReady(entry[2])
			end
		end
	end

	function material_bake.LoadDeferred(material, except_baked_slots)
		if not except_baked_slots then
			material_bake.ReleaseAdjustments(material, true)
		end

		for _, info in ipairs(objects.GetStorableVariables(material)) do
			if not (except_baked_slots and BAKED_SLOTS[info.get_name]) then
				local value = material[info.get_name](material)

				if type(value) == "table" and value.deferred_load then value:Load() end
			end
		end
	end
end

local function skip(material, reason)
	stats.skipped[reason] = (stats.skipped[reason] or 0) + 1
	stats.processed = stats.processed + 1
	material_bake.LoadDeferred(material)
end

-- Asks for a material to be baked. Needs the material's textures created but deferred: a cache hit
-- loads the baked textures and never loads the originals. A no-op unless r_bake_materials is on.
function material_bake.Request(material)
	if not material_bake.enabled:Get() then return end

	material_bake.PruneCache()
	local generation = material.vmt_generation

	if material.baked or queued[material] == generation then
		material_bake.LoadDeferred(material)
		return
	end

	queued[material] = generation
	stats.requested = stats.requested + 1
	local ok, reason = material_bake.CanBake(material)

	if not ok then return skip(material, reason) end

	local key = material_bake.GetKey(material)

	if not key then return skip(material, "no texture path") end

	if has_cache(material, key) then
		return apply_cached(material, generation, key)
	end

	material_bake.LoadDeferred(material)
	local pending = 0

	local function ready()
		pending = pending - 1

		if pending == 0 then queue[#queue + 1] = {material, generation, key, frame} end
	end

	for _, getter in ipairs(READY_GETTERS) do
		local texture = material[getter](material)

		if texture and not texture:IsReady() then
			pending = pending + 1
			texture:AddOnReady(ready)
		end
	end

	if pending == 0 then queue[#queue + 1] = {material, generation, key, frame} end
end

function material_bake.GetStats()
	return stats
end

function material_bake.IsIdle()
	return stats.requested == stats.processed
end

do
	local head = 1

	event.AddListener("Update", "material_bake", function()
		local budget = 2
		frame = frame + 1

		while budget > 0 and queue[head] and frame - queue[head][4] >= READY_FRAME_DELAY do
			local entry = queue[head]
			queue[head] = false
			head = head + 1
			local ok, worked = xpcall(process, debug.traceback, entry[1], entry[2], entry[3])

			if not ok then
				stats.failed = stats.failed + 1
				logn("material_bake: ", worked)
			elseif worked then
				budget = budget - 1
			end
		end

		if head > #queue then
			table.clear(queue)
			head = 1
		end
	end)
end

return material_bake
