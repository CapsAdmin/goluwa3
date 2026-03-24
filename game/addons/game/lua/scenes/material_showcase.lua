local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local shapes = import("lua/shapes.lua")
local materials = {}
local pos = Vec3(0, -0.75, 0)
local PADDING = 2.3

local function sphere(material)
	local sphere_radius = 1
	local sphere_position = (pos * PADDING):Copy()
	pos.x = pos.x + 1

	if pos.x >= 3 then
		pos.x = 0
		pos.z = pos.z + 1
	end

	shapes.Sphere{
		Name = "debug_ent",
		Position = sphere_position,
		Radius = sphere_radius,
		Material = material,
		RigidBody = {
			Shape = SphereShape.New(sphere_radius),
			LinearDamping = 0.08,
			AngularDamping = 0.35,
			Friction = 0.2,
			Restitution = 0.25,
		},
	}
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
			
			float EPS = 5e-3;
			float strength = 0.02;
			
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
sphere{
	Shared = shared,
	Albedo = "return vec4(1.022, 0.782, 0.344, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = "return vec4(0.05);",
	Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = "return vec4(0.2);",
	Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.955, 0.637, 0.538, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = "return vec4(0.3);",
	Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0, 1, 0, 1.0);",
	Metallic = "return vec4(0.0);",
	Roughness = "return vec4(0.00);",
	Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.875, 0.125, 0.0, 1.0);",
	Metallic = "return vec4(0.0);",
	Roughness = "return vec4(0.05);",
	Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = [[
			float m = smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n)));

			return mix(
				vec4(0.0125, 0.2625, 0.3125, 1.0),
				vec4(1.022, 0.782, 0.344, 1.0),
				m
			);
		]],
	Metallic = "return vec4(smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n))));",
	Roughness = [[
			float m = smoothstep(0.38, 0.42, length(getTriplanar(12.0*p, n)));
			float r = mix(
				length(getTriplanar(12.0*p, n)),
				0.25 * saturate(length(getTriplanar(1.0*p, n))),
				m
			);
			return vec4(clamp(r, 0.05, 0.999));
		]],
	Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = "return vec4(1.0 / 3.0);",
	Normal = "return vec4(getDetailNormal(p, n, 0.2) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = [[
			return vec4(mix(vec3(0.0625), vec3(1.0, 0.8125, 0.125), 
				smoothstep(0.0, 0.2, sin(5.8*p.y + 5.8*p.z))), 1.0);
		]],
	Metallic = "return vec4(0.0);",
	Roughness = "return vec4(1.0 / 3.0);",
	Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.1125, 0.4125, 1.0, 1.0);",
	Metallic = "return vec4(0.0);",
	Roughness = "return vec4(2.0 / 3.0);",
	Normal = "return vec4(getDetailNormal(p, n, 1.0) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = [[
			float weight = length(getTriplanar(8.0*(p.xxx+p.yyy+p.zzz), n));
			return vec4(saturate(0.6 + max(0.2, weight)) * vec3(0.955, 0.637, 0.538), 1.0);
		]],
	Metallic = "return vec4(1.0);",
	Roughness = "return vec4(0.3);",
	Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.91, 0.92, 0.92, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = [[
            float large_wear = perlin_noise(p * 2.0) * 0.5 + 0.5;
            float medium_wear = perlin_noise(p * 6.0) * 0.5 + 0.5;
            float fine_detail = perlin_noise(p * 20.0) * 0.5 + 0.5;
            float roughness = mix(0.05, 0.6, large_wear * 0.6 + medium_wear * 0.3 + fine_detail * 0.1);
            return vec4(roughness);
        ]],
	Normal = "return vec4(getDetailNormal(p, n, 0.3) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.972, 0.960, 0.915, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = [[
            float streaks = sin(p.x * 40.0 + perlin_noise(p * 8.0) * 2.0) * 0.5 + 0.5;
            float base_rough = 0.15;
            float roughness = base_rough + streaks * 0.25;
            return vec4(roughness);
        ]],
	Normal = "return vec4(getDetailNormal(p, n, 0.15) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = "return vec4(0.91, 0.92, 0.92, 1.0);",
	Metallic = "return vec4(1.0);",
	Roughness = [[
            float smudge1 = smoothstep(0.3, 0.7, perlin_noise(p * 3.0 + vec3(0.0)));
            float smudge2 = smoothstep(0.2, 0.6, perlin_noise(p * 4.0 + vec3(5.0)));
            float smudges = max(smudge1, smudge2 * 0.7);
            return vec4(mix(0.02, 0.4, smudges));
        ]],
	Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = [[
            float age = smoothstep(0.3, 0.7, perlin_noise(p * 4.0) * 0.5 + 0.5);
            vec3 fresh = vec3(0.955, 0.637, 0.538);
            vec3 aged = vec3(0.4, 0.65, 0.55);
            return vec4(mix(fresh, aged, age * 0.3), 1.0);
        ]],
	Metallic = "return vec4(1.0);",
	Roughness = [[
            float age = perlin_noise(p * 4.0) * 0.5 + 0.5;
            float detail = perlin_noise(p * 15.0) * 0.5 + 0.5;
            return vec4(mix(0.1, 0.7, age * 0.8 + detail * 0.2));
        ]],
	Normal = "return vec4(getDetailNormal(p, n, 0.4) * 0.5 + 0.5, 1.0);",
}
sphere{
	Shared = shared,
	Albedo = [[
            float is_metal = step(0.0, n.y);
            vec3 plastic_color = vec3(0.8, 0.1, 0.1);
            vec3 metal_color = vec3(0.91, 0.92, 0.92);
            return vec4(mix(metal_color, plastic_color, is_metal), 1.0);
        ]],
	Metallic = [[
            return vec4(step(0.0, n.y));
        ]],
	Roughness = [[
            float roughness = smoothstep(-1.0, 1.0, n.x);
            return vec4(mix(0.02, 0.95, roughness));
        ]],
	Normal = "return vec4(0.5, 0.5, 1.0, 1.0);",
}
