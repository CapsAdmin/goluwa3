local Polygon3D = require("render3d.polygon_3d")
local Texture = require("render.texture")
local Material = require("render3d.material")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local utility = require("utility")
local transform = require("ecs.components.3d.transform")
local model = require("ecs.components.3d.model")
local Entity = require("ecs.entity")
local HEADER = [[
float n2D(vec2 p) {
	vec2 i = floor(p); p -= i; 
    p *= p*(3. - p*2.);  
    return dot(mat2(fract(sin(mod(vec4(0, 1, 113, 114) + dot(i, vec2(1, 113)), 6.2831853))*
               43758.5453))*vec2(1. - p.y, p.y), vec2(1. - p.x, p.x) );
}

mat2 rot2(in float a){ float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }

vec2 hash22(vec2 p) {
    float n = sin(dot(p, vec2(113, 1)));
    return fract(vec2(2097152, 262144)*n)*2. - 1.;
}

float gradN2D(in vec2 f){
    const vec2 e = vec2(0, 1);
    vec2 p = floor(f);
    f -= p;
    vec2 w = f*f*(3. - 2.*f);
    float c = mix(mix(dot(hash22(p + e.xx), f - e.xx), dot(hash22(p + e.yx), f - e.yx), w.x),
                  mix(dot(hash22(p + e.xy), f - e.xy), dot(hash22(p + e.yy), f - e.yy), w.x), w.y);
    return c*.5 + .5;
}

float grad(float x, float offs){
    x = abs(fract(x/6.283 + offs - .25) - .5)*2.;
    float x2 = clamp(x*x*(-1. + 2.*x), 0., 1.);
    x = smoothstep(0., 1., x);
    return mix(x, x2, .15);
}

float sandL(vec2 p){
    vec2 q = rot2(3.14159/18.)*p;
    q.y += (gradN2D(q*18.) - .5)*.05;
    float grad1 = grad(q.y*80., 0.);
   
    q = rot2(-3.14159/20.)*p;
    q.y += (gradN2D(q*12.) - .5)*.05;
    float grad2 = grad(q.y*80., .5);
      
    q = rot2(3.14159/4.)*p;
    float a2 = dot(sin(q*12. - cos(q.yx*12.)), vec2(.25)) + .5;
    float a1 = 1. - a2;
    
    return 1. - (1. - grad1*a1)*(1. - grad2*a2);
}

float sand(vec2 p){
    p = vec2(p.y - p.x, p.x + p.y)*.7071/4.;
    float c1 = sandL(p);
    vec2 q = rot2(3.14159/12.)*p;
    float c2 = sandL(q*1.25);
    return mix(c1, c2, smoothstep(.1, .9, gradN2D(p*vec2(4))));
}

float surfFunc(vec3 p){
    p /= 2.5;
    float layer1 = n2D(p.xz*.2)*2. - .5;
    layer1 = smoothstep(0., 1.05, layer1);
    float layer2 = n2D(p.xz*.275);
    layer2 = 1. - abs(layer2 - .5)*2.;
    layer2 = smoothstep(.2, 1., layer2*layer2);
	float layer3 = n2D(p.xz*.5*3.);
    return layer1*.7 + layer2*.25 + layer3*.05;
}

float fBm(vec2 p){
    return gradN2D(p)*.57 + gradN2D(p*2.)*.28 + gradN2D(p*4.)*.15;
}
]]

local function CreateDesertTerrain()
	local albedo_tex = Texture.New(
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
				wrap_t = "repeat",
			},
		}
	)
	albedo_tex:Shade(
		[[
        vec2 p = uv * 20.0;
        
        // Base colors
        vec3 col = mix(vec3(1.0, 0.95, 0.7), vec3(0.9, 0.6, 0.4), fBm(p * 16.0));
        col = mix(col * 1.4, col * 0.6, fBm(p * 32.0 - 0.5));
        
        // Sand ripples
        float s = sand(p);
        col *= s * 0.75 + 0.5;
        
        // Grit
        float grit = (fract(sin(dot(floor(p * 192.0), vec2(12.9898, 78.233))) * 43758.5453));
        col = mix(col * 0.8, col, grit * 0.3 + 0.7);
        
        return vec4(col, 1.0);
    ]],
		{header = HEADER}
	)
	local normal_tex = Texture.New(
		{
			width = 1024,
			height = 1024,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
		}
	)
	normal_tex:Shade(
		[[
        vec2 p = uv * 20.0;
        
        // Sand ripples
        float s = sand(p);
    
        // Calculate normal from height differences
        float eps = 1.0 / 1024.0;
        float hL = sand(p - vec2(eps, 0.0));
        float hR = sand(p + vec2(eps, 0.0));
        float hD = sand(p - vec2(0.0, eps));
        float hU = sand(p + vec2(0.0, eps));
        
        float strength = 0.03;  // Adjust this value: 0.0 = flat, 1.0 = full strength
        
        vec3 normal;
        normal.x = (hL - hR) * strength;
        normal.z = 2.0 * eps;
        normal.y = (hD - hU) * strength;
        normal = normalize(normal);
        
        // Convert from [-1,1] to [0,1] range for storage
        normal = normal * 0.5 + 0.5;
        
        return vec4(normal, 1.0);
	]],
		{header = HEADER}
	)

	do
		local ent = Entity.New({Name = "debug_ent"})
		local transform = ent:AddComponent("transform")
		transform:SetPosition(Vec3(0, -10, 0))
		local poly = Polygon3D.New()
		poly:CreateSphere(1)
		local mat = Material.New()
		mat:SetAlbedoTexture(albedo_tex)
		mat:SetNormalTexture(normal_tex)
		mat:SetRoughnessMultiplier(0.9)
		mat:SetMetallicMultiplier(0)
		poly:Upload()
		local model = ent:AddComponent("model")
		model:AddPrimitive(poly, mat)
	end

	-- 1. Heightmap Texture
	local height_tex = Texture.New({
		width = 512,
		height = 512,
		format = "r8g8b8a8_unorm",
	})
	height_tex:Shade(
		[[
        vec3 p = vec3(uv.x * 20.0, 0.0, uv.y * 20.0);
        float h = surfFunc(p);
        return vec4(h, h, h, 1.0);
    ]],
		{header = HEADER}
	)
	-- 4. Build Mesh
	local poly = Polygon3D.New()
	poly:LoadHeightmap(height_tex, Vec2(4096, 4096), Vec2(64, 64), Vec2() + 128, 512, 1)
	local mat = Material.New()
	mat:SetAlbedoTexture(albedo_tex)
	mat:SetNormalTexture(normal_tex)
	mat:SetRoughnessMultiplier(0.9)
	mat:SetMetallicMultiplier(0.1)
	poly:BuildNormals(true)
	poly:SmoothNormals()
	poly:BuildBoundingBox()
	poly:Upload()
	local ent = Entity.New({Name = "desert_terrain"})
	local transform = ent:AddComponent("transform")
	local model = ent:AddComponent("model")
	transform:SetPosition(Vec3(0, -127, 0))
	model:AddPrimitive(poly, mat)
	return ent
end

-- Run it
if _G.desert_ent then _G.desert_ent:Remove() end

require("timer").Delay(0.2, function()
	_G.desert_ent = CreateDesertTerrain()
	print("Desert terrain created!")
end)
