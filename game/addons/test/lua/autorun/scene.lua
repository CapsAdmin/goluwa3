local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local lightprobes = require("render3d.lightprobes")
local Material = require("render3d.material")
local Texture = require("render.texture")
local ecs = require("ecs.ecs")
local ffi = require("ffi")
local Polygon3D = require("render3d.polygon_3d")
local transform = require("ecs.components.3d.transform")
local model = require("ecs.components.3d.model")
local materials = {}

if HOTRELOAD then ecs.Clear3DWorld() end

local function shaded_texture(glsl, shared)
	if type(glsl) ~= "string" then return glsl end -- already a texture
	local tex = Texture.New(
		{
			width = 1024,
			height = 1024,
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
	local material_index = 1
	local pos = Vec3(0, -0.75, 0)
	local PADDING = 2.3

	local function spawn()
		local ent = ecs.CreateEntity("debug_ent")
		local transform = ent:AddComponent(transform)
		transform:SetPosition((pos * PADDING):Copy())
		pos.x = pos.x + 1

		if pos.x >= 3 then
			pos.x = 0
			pos.z = pos.z + 1
		end

		local poly = Polygon3D.New()
		poly:CreateSphere(1)
		local material = materials[material_index]
		material_index = material_index + 1

		if material_index > #materials then material_index = 1 end

		poly:Upload()
		local model = ent:AddComponent(model)
		model:AddPrimitive(poly, material)
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
			
			float EPS = 5e-3;  // increased from 1e-3 for smoother sampling
			float strength = 0.02;  // reduced from 0.05 for gentler bumps
			
			float h = length(getTriplanar(12.0 * p, normal));
			float hT = length(getTriplanar(12.0 * (p + tangent * EPS), normal));
			float hB = length(getTriplanar(12.0 * (p + bitangent * EPS), normal));
			
			vec3 delTangent = (tangent * EPS + normal * m * strength * hT) - (normal * m * strength * h);
			vec3 delBitangent = (bitangent * EPS + normal * m * strength * hB) - (normal * m * strength * h);
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
	--gold
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(1.022, 0.782, 0.344, 1.0);",
			metal = "return vec4(1.0);",
			roughness = "return vec4(0.05);",
			normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		}
	)
	-- silver
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
			metal = "return vec4(1.0);",
			roughness = "return vec4(0.2);",
			normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		}
	)
	-- copper
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.955, 0.637, 0.538, 1.0);",
			metal = "return vec4(1.0);",
			roughness = "return vec4(0.3);",
			normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
		}
	)
	--green plastic
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0, 1, 0, 1.0);",
			metal = "return vec4(0.0);",
			roughness = "return vec4(0.00);",
			normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
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
			float m = smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n)));

			return mix(
				vec4(0.0125, 0.2625, 0.3125, 1.0),
				vec4(1.022, 0.782, 0.344, 1.0),
				m
			);
		]],
			metal = "return vec4(smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n))));",
			roughness = [[
			float m = smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n)));
			float r = mix(
				length(getTriplanar(12.0*p, n)),
				0.25 * saturate(length(getTriplanar(1.0*p, n))),
				m
			);
			return vec4(clamp(r, 0.05, 0.999));
		]],
			normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
		--heightmap = [[return vec4(length(getTriplanar(12.0*p, n)));]],
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
	-- light blue ball
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
	-- Worn/polished metal - roughness varies based on noise (like naturally worn metal)
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.91, 0.92, 0.92, 1.0);", -- Silver base
			metal = "return vec4(1.0);",
			roughness = [[
            // Layered noise for organic worn-metal look
            float large_wear = perlin_noise(p * 2.0) * 0.5 + 0.5;
            float medium_wear = perlin_noise(p * 6.0) * 0.5 + 0.5;
            float fine_detail = perlin_noise(p * 20.0) * 0.5 + 0.5;
            
            // Combine: large patches of polish/roughness with fine scratches
            float roughness = mix(0.05, 0.6, large_wear * 0.6 + medium_wear * 0.3 + fine_detail * 0.1);
            return vec4(roughness);
        ]],
			normal = "return vec4(getDetailNormal(p, n, 0.3) * 0.5 + 0.5, 1.0);",
		}
	)
	-- Brushed metal - directional roughness variation
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.972, 0.960, 0.915, 1.0);", -- Silver
			metal = "return vec4(1.0);",
			roughness = [[
            // Brushed streaks along one direction
            float streaks = sin(p.x * 40.0 + perlin_noise(p * 8.0) * 2.0) * 0.5 + 0.5;
            float base_rough = 0.15;
            float roughness = base_rough + streaks * 0.25;
            return vec4(roughness);
        ]],
			normal = "return vec4(getDetailNormal(p, n, 0.15) * 0.5 + 0.5, 1.0);",
		}
	)
	-- Fingerprint/smudge metal - glossy with matte patches
	MATERIAL(
		{
			shared = shared,
			albedo = "return vec4(0.91, 0.92, 0.92, 1.0);",
			metal = "return vec4(1.0);",
			roughness = [[
            // Soft blobs like fingerprints/smudges on polished metal
            float smudge1 = smoothstep(0.3, 0.7, perlin_noise(p * 3.0 + vec3(0.0)));
            float smudge2 = smoothstep(0.2, 0.6, perlin_noise(p * 4.0 + vec3(5.0)));
            float smudges = max(smudge1, smudge2 * 0.7);
            
            // Mostly glossy (0.02) with matte smudges (0.4)
            return vec4(mix(0.02, 0.4, smudges));
        ]],
			normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		}
	)
	-- Aged/patina copper with varying roughness
	MATERIAL(
		{
			shared = shared,
			albedo = [[
            float age = smoothstep(0.3, 0.7, perlin_noise(p * 4.0) * 0.5 + 0.5);
            // Fresh copper to aged patina
            vec3 fresh = vec3(0.955, 0.637, 0.538);
            vec3 aged = vec3(0.4, 0.65, 0.55); // greenish patina tint
            return vec4(mix(fresh, aged, age * 0.3), 1.0);
        ]],
			metal = "return vec4(1.0);",
			roughness = [[
            float age = perlin_noise(p * 4.0) * 0.5 + 0.5;
            float detail = perlin_noise(p * 15.0) * 0.5 + 0.5;
            // Polished areas (0.1) vs aged rough areas (0.7)
            return vec4(mix(0.1, 0.7, age * 0.8 + detail * 0.2));
        ]],
			normal = "return vec4(getDetailNormal(p, n, 0.4) * 0.5 + 0.5, 1.0);",
		}
	)
	MATERIAL(
		{
			shared = shared,
			albedo = [[
            float is_metal = step(0.0, n.y);
            
            vec3 plastic_color = vec3(0.8, 0.1, 0.1);  // Red plastic
            vec3 metal_color = vec3(0.91, 0.92, 0.92); // Silver metal
            
            return vec4(mix(metal_color, plastic_color, is_metal), 1.0);
        ]],
			metal = [[
            return vec4(step(0.0, n.y));
        ]],
			roughness = [[
            float roughness = smoothstep(-1.0, 1.0, n.x);
            return vec4(mix(0.02, 0.95, roughness));
        ]],
			normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
		}
	)

	for i = 1, #materials do
		spawn()
	end
end

if false then -- reflection plane
	local reflection_mat = Material.New()
	reflection_mat:SetAlbedoTexture(shaded_texture([[
		return vec4(0.8, 0.9, 1.0, 1.0);
	]]))
	reflection_mat:SetMetallicTexture(shaded_texture("return vec4(1.0);"))
	reflection_mat:SetRoughnessTexture(shaded_texture("return vec4(0.0);"))
	local poly = Polygon3D.New()
	poly:CreateSphere(1)
	poly:Upload()
	local ent = ecs.CreateEntity("reflection_plane")
	local transform = ent:AddComponent(transform)
	transform:SetPosition(Vec3(17.9, -243.3, 1.1))
	transform:SetScale(Vec3(100, 1, 100))
	local model = ent:AddComponent(model)
	model:AddPrimitive(poly, reflection_mat)
end

if false then
	local vfs = require("vfs")
	local steam = require("steam")
	steam.MountSourceGame("gmod")
	local models = {
		"models/zombie/classic.mdl",
		"models/zombie/zombie_soldier.mdl",
		"models/vehicles/prisoner_pod_inner.mdl",
		"models/vehicle/vehicle_rich.mdl",
		--"models/shadertest/*",
		"models/props_trainstation/train_engine.mdl",
		"models/props_trainstation/train001.mdl",
		"models/props_rooftop/end_parliament_dome.mdl",
		"models/props_foliage/tree_pine_large.mdl",
		"models/props_foliage/ah_ash_tree_med.mdl",
		"models/props_foliage/bush2.mdl",
		"models/props_foliage/treepine03c.mdl",
		"models/props_docks/channelmarker_gib02.mdl",
		"models/props_canal/boat002b.mdl",
		"models/props_c17/oildrum001_explosive.mdl",
		"models/props_debris/barricade_tall04a.mdl",
		"models/props_combine/combine_monitorbay.mdl",
		"models/props_combine/combine_interface002.mdl",
		"models/props_combine/combine_interface002.mdl",
		"models/props_combine/combinetrain01a.mdl",
		"models/props_combine/masterinterface_dyn.mdl",
		"models/props_combine/breendesk.mdl",
		"models/props_combine/breenglobe.mdl",
		"models/props_combine/breenchair.mdl",
		"models/props_combine/combine_bridge_b.mdl",
		"models/props_combine/combine_booth_short01a.mdl",
		"models/props_combine/weaponstripper.mdl",
		"models/props_c17/oildrum001.mdl",
		"models/props_c17/trappropeller_blade.mdl",
		"models/props_borealis/bluebarrel001.mdl",
		"models/cliffs/rocks_small01_veg.mdl",
		"models/combine_helicopter/helicopter_bomb01.mdl",
		"models/combine_turrets/combine_cannon_gun.mdl",
		"models/player/alyx.mdl",
		"models/player/combine_super_soldier.mdl",
		"models/player/vortigaunt.mdl",
		"models/player/combine_soldier.mdl",
		"models/player/eli.mdl",
		"models/player/gman_high.mdl",
	}

	for _, path in ipairs(vfs.Find("models/shadertest/")) do
		if path:ends_with(".mdl") then
			table.insert(models, "models/shadertest/" .. path)
		end
	end

	local pos = Vec3(-10, -10, 0)

	for _, model_path in ipairs(models) do
		if not vfs.IsFile(model_path) then
			print(model_path .. " not found!")
		else
			local e = ecs.CreateEntity("model_ent")
			local t = e:AddComponent(transform)
			t:SetPosition(pos:Copy())
			pos.x = pos.x + 5

			if pos.x > 10 then
				pos.x = -10
				pos.z = pos.z + 5
			end

			e:AddComponent(model)
			e.model:SetModelPath(model_path)
		end
	end
end
