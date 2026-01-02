local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local skybox = require("render3d.skybox")
local Material = require("render3d.material")
local Texture = require("render.texture")
local materials = {}

local function shaded_texture(glsl, shared)
	if type(glsl) ~= "string" then return glsl end -- already a texture
	local tex = Texture.New(
		{
			width = 512,
			height = 512,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "repeat",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	tex:Shade(glsl, {custom_declarations = shared})
	return tex
end

local function MATERIAL(config)
	local mat = Material.New()

	local function get(name)
		return config[name] or config[name:lower()]
	end

	local albedo = get("Albedo")

	if albedo then mat:SetAlbedoTexture(shaded_texture(albedo, config.shared)) end

	local normal = get("Normal")

	if normal then mat:SetNormalTexture(shaded_texture(normal, config.shared)) end

	local metallic = get("Metallic") or get("Metal")

	if metallic then
		mat:SetMetallicTexture(shaded_texture(metallic, config.shared))
	end

	local roughness = get("Roughness")

	if roughness then
		mat:SetRoughnessTexture(shaded_texture(roughness, config.shared))
	end

	table.insert(materials, mat)
end

do
	local ecs = require("ecs")
	local ffi = require("ffi")
	local Polygon3D = require("render3d.polygon_3d")
	local material_index = 1
	local pos = Vec3(0, 0, 0)
	local PADDING = 3

	local function spawn()
		local ent = ecs.CreateEntity("debug_ent")
		ent:AddComponent("transform", {
			position = (pos * PADDING):Copy(),
		})
		pos.x = pos.x + 1

		if pos.x >= 3 then
			pos.x = 0
			pos.z = pos.z + 1
		end

		local poly = Polygon3D.New()
		poly:CreateSphere(1)
		poly.material = materials[material_index]
		material_index = material_index + 1

		if material_index > #materials then material_index = 1 end

		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		ent:AddComponent("model", {
			mesh = poly,
		})
	end

	local shared = [[
		#define PI 3.14159265359
		#define saturate(x) clamp(x, 0.0, 1.0)
		#define MOD3 vec3(.1031,.11369,.13787)

		vec3 hash33(vec3 p3) {
			p3 = fract(p3 * MOD3);
			p3 += dot(p3, p3.yxz+19.19);
			return -1.0 + 2.0 * fract(vec3((p3.x + p3.y)*p3.z, (p3.x+p3.z)*p3.y, (p3.y+p3.z)*p3.x));
		}

		float perlin_noise(vec3 p) {
			vec3 pi = floor(p);
			vec3 pf = p - pi;
			vec3 w = pf * pf * (3.0 - 2.0 * pf);
			return mix(
				mix(mix(dot(pf - vec3(0, 0, 0), hash33(pi + vec3(0, 0, 0))), 
						dot(pf - vec3(1, 0, 0), hash33(pi + vec3(1, 0, 0))), w.x),
					mix(dot(pf - vec3(0, 0, 1), hash33(pi + vec3(0, 0, 1))), 
						dot(pf - vec3(1, 0, 1), hash33(pi + vec3(1, 0, 1))), w.x), w.z),
				mix(mix(dot(pf - vec3(0, 1, 0), hash33(pi + vec3(0, 1, 0))), 
						dot(pf - vec3(1, 1, 0), hash33(pi + vec3(1, 1, 0))), w.x),
					mix(dot(pf - vec3(0, 1, 1), hash33(pi + vec3(0, 1, 1))), 
						dot(pf - vec3(1, 1, 1), hash33(pi + vec3(1, 1, 1))), w.x), w.z), w.y);
		}

		vec3 getTriplanar(vec3 position, vec3 normal) {
			return vec3(perlin_noise(position * 0.2));
		}

		void pixarONB(vec3 n, out vec3 b1, out vec3 b2){
			float sign_ = n.z >= 0.0 ? 1.0 : -1.0;
			float a = -1.0 / (sign_ + n.z);
			float b = n.x * n.y * a;
			b1 = vec3(1.0 + sign_ * n.x * n.x * a, sign_ * b, -sign_ * n.x);
			b2 = vec3(b, sign_ + n.y * n.y * a, -n.y);
		}

		vec3 getDetailNormal(vec3 p, vec3 normal, float m) {
			vec3 tangent, bitangent;
			pixarONB(normal, tangent, bitangent);
			float EPS = 1e-3;
			float h = length(getTriplanar(12.0 * p, normal));
			float hT = length(getTriplanar(12.0 * (p + tangent * EPS), normal));
			float hB = length(getTriplanar(12.0 * (p + bitangent * EPS), normal));
			
			vec3 delTangent = (tangent * EPS + normal * m * 0.05 * hT) - (normal * m * 0.05 * h);
			vec3 delBitangent = (bitangent * EPS + normal * m * 0.05 * hB) - (normal * m * 0.05 * h);
			vec3 worldNormal = normalize(cross(delTangent, delBitangent));
			
			return vec3(
				dot(worldNormal, tangent),
				dot(worldNormal, bitangent),
				dot(worldNormal, normal)
			);
		}

		vec3 get_equirect_dir(vec2 uv) {
			float phi = (0.75 - uv.x) * 2.0 * 3.14159265359;
			float theta = uv.y * 3.14159265359;
			return vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));
		}
		#define p (get_equirect_dir(uv) * 3.0)
		#define n get_equirect_dir(uv)
	]]
	-- (0, 0) Green corner sphere
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.0625, 0.375, 0.0625, 1.0);",
			metal = "return vec4(0.0);",
			roughness = "return vec4(0.05);",
			normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		}
	)
	-- (1, 0) Gold
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(1.022, 0.782, 0.344, 1.0);",
			metal = "return vec4(1.0);",
			roughness = "return vec4(0.05);",
			normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		}
	)
	-- (2, 0) Orange
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.875, 0.125, 0.0, 1.0);",
			metal = "return vec4(0.0);",
			roughness = "return vec4(0.05);",
			normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		}
	)
	-- (0, 1) Mixed sphere
	MATERIAL(
		{
			shared = shared,
			albedo = [[
				float m = length(getTriplanar(12.0*p, n)) > 0.4 ? 1.0 : 0.0;

				if (m == 1.0) {
					return vec4(vec3(1.022, 0.782, 0.344), 1.0);
				}

			return vec4(0.0125, 0.2625, 0.3125, 1.0);]],
			metal = "return vec4(length(getTriplanar(12.0*p, n)) > 0.4 ? 1.0 : 0.0);",
			roughness = [[
			float m = length(getTriplanar(12.0*p, n)) > 0.4 ? 1.0 : 0.0;
			float r = m == 1.0 ? 0.25*saturate(length(getTriplanar(1.0*p, n))) : 0.5*length(getTriplanar(12.0*p, n));
			return vec4(clamp(r, 0.05, 0.999));
		]],
			normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		}
	)
	-- (1, 1) Silver
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
			metal = "return vec4(1.0);",
			roughness = "return vec4(1.0 / 3.0);",
			normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		}
	)
	-- (2, 1) Striped
	MATERIAL(
		{
			shared = shared,
			albedo = [[
			return vec4(mix(vec3(0.0625), vec3(1.0, 0.8125, 0.125), 
				smoothstep(0.0, 0.2, sin(5.8*p.y + 5.8*p.z))), 1.0);
		]],
			metal = "return vec4(0.0);",
			roughness = "return vec4(1.0 / 3.0);",
			normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		}
	)
	-- (0, 2) Sky blue
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.1125, 0.4125, 1.0, 1.0);",
			metal = "return vec4(0.0);",
			roughness = "return vec4(2.0 / 3.0);",
			normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		}
	)
	-- (1, 2) Copper
	MATERIAL(
		{
			shared = shared,
			albedo = [[
			float weight = length(getTriplanar(8.0*(p.xxx+p.yyy+p.zzz), n));
			return vec4(saturate(0.6 + max(0.2, weight)) * vec3(0.955, 0.637, 0.538), 1.0);
		]],
			metal = "return vec4(1.0);",
			roughness = "return vec4(0.3);",
			normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		}
	)
	-- (2, 2) Smooth white
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(1.0, 1.0, 1.0, 1.0);",
			metal = "return vec4(0.0);",
			roughness = "return vec4(2.0 / 3.0);",
			normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		}
	)

	for i = 1, 9 do
		spawn()
	end
end
