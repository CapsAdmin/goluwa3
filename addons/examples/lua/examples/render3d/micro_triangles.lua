local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local shapes = import("goluwa/render3d/shapes.lua")
import("lua/saved_views.lua").SetScene{
	MICRO_GRID = os.getenv("MICRO_GRID") or "24",
	MICRO_SUBDIVISIONS = os.getenv("MICRO_SUBDIVISIONS") or "6",
	MICRO_GROUND = os.getenv("MICRO_GROUND") or "1",
	MICRO_ROCKS = os.getenv("MICRO_ROCKS") or "1",
}
local GRID = tonumber(os.getenv("MICRO_GRID") or "24")
local SUBDIVISIONS = tonumber(os.getenv("MICRO_SUBDIVISIONS") or "6")
local SPACING = 6
local root = Entity.New{Name = "micro_triangles"}

local function noise(x, y, z)
	return math.sin(5.1 * x + 1.3) * math.cos(4.3 * y + 0.7) * math.sin(6.2 * z + 2.1) * 0.5 + math.sin(13.7 * x + 3.1 * z) * math.cos(11.3 * y) * 0.18 + math.sin(31.0 * y + 2.0 * x) * math.cos(29.0 * z) * 0.05
end

local function build_rock(subdivisions)
	local t = (1 + math.sqrt(5)) / 2
	local px = {-1, 1, -1, 1, 0, 0, 0, 0, t, t, -t, -t}
	local py = {t, t, -t, -t, -1, 1, -1, 1, 0, 0, 0, 0}
	local pz = {0, 0, 0, 0, t, t, -t, -t, -1, 1, -1, 1}
	local faces = {
		0,
		11,
		5,
		0,
		5,
		1,
		0,
		1,
		7,
		0,
		7,
		10,
		0,
		10,
		11,
		1,
		5,
		9,
		5,
		11,
		4,
		11,
		10,
		2,
		10,
		7,
		6,
		7,
		1,
		8,
		3,
		9,
		4,
		3,
		4,
		2,
		3,
		2,
		6,
		3,
		6,
		8,
		3,
		8,
		9,
		4,
		9,
		5,
		2,
		4,
		11,
		6,
		2,
		10,
		8,
		6,
		7,
		9,
		8,
		1,
	}

	for i = 1, 12 do
		local l = math.sqrt(px[i] ^ 2 + py[i] ^ 2 + pz[i] ^ 2)
		px[i], py[i], pz[i] = px[i] / l, py[i] / l, pz[i] / l
	end

	for _ = 1, subdivisions do
		local cache, next_faces = {}, {}

		local function middle(a, b)
			local key = math.min(a, b) * 4194304 + math.max(a, b)

			if cache[key] then return cache[key] end

			local x, y, z = px[a + 1] + px[b + 1], py[a + 1] + py[b + 1], pz[a + 1] + pz[b + 1]
			local l = math.sqrt(x * x + y * y + z * z)
			px[#px + 1], py[#py + 1], pz[#pz + 1] = x / l, y / l, z / l
			cache[key] = #px - 1
			return #px - 1
		end

		for f = 1, #faces, 3 do
			local a, b, c = faces[f], faces[f + 1], faces[f + 2]
			local ab, bc, ca = middle(a, b), middle(b, c), middle(c, a)

			for _, v in ipairs{a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca} do
				next_faces[#next_faces + 1] = v
			end
		end

		faces = next_faces
	end

	local count = #px
	local vertices = vertex_layout.ArrayType(count)
	local positions = {}

	for i = 1, count do
		local x, y, z = px[i], py[i], pz[i]
		local r = 1 + 0.35 * noise(x, y, z)
		positions[i] = {x * r, y * r * 0.7, z * r}
	end

	local normals = {}

	for i = 1, count do
		normals[i] = {0, 0, 0}
	end

	for f = 1, #faces, 3 do
		local a, b, c = positions[faces[f] + 1], positions[faces[f + 1] + 1], positions[faces[f + 2] + 1]
		local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
		local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx

		for k = 0, 2 do
			local n = normals[faces[f + k] + 1]
			n[1], n[2], n[3] = n[1] + nx, n[2] + ny, n[3] + nz
		end
	end

	for i = 0, count - 1 do
		local p, n = positions[i + 1], normals[i + 1]
		local l = math.max(math.sqrt(n[1] ^ 2 + n[2] ^ 2 + n[3] ^ 2), 1e-12)
		local v = vertices[i]
		v.position[0], v.position[1], v.position[2] = p[1], p[2], p[3]
		v.normal[0], v.normal[1], v.normal[2] = n[1] / l, n[2] / l, n[3] / l
		v.uv[0], v.uv[1] = math.atan2(pz[i + 1], px[i + 1]) / math.pi + 1, py[i + 1] * 0.5 + 0.5
		v.tangent[0], v.tangent[1], v.tangent[2], v.tangent[3] = -pz[i + 1], 0, px[i + 1], 1
	end

	local indices = ffi.new("uint32_t[?]", #faces)

	for f = 1, #faces, 3 do
		indices[f - 1], indices[f], indices[f + 1] = faces[f], faces[f + 2], faces[f + 1]
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, count, indices, #faces, true)
	return polygon
end

if os.getenv("MICRO_ROCKS") ~= "0" then
	local rock = build_rock(SUBDIVISIONS)
	local material = shapes.Material{
		Color = Color(0.62, 0.58, 0.52, 1),
		Roughness = 0.85,
		Metallic = 0,
		AlbedoTexture = shapes.Texture([[
			float n = fract(sin(dot(floor(uv * vec2(64.0, 32.0)), vec2(12.9898, 78.233))) * 43758.5453);
			float veins = smoothstep(0.45, 0.5, abs(fract(uv.x * 7.0 + uv.y * 3.0) - 0.5));
			return vec4(vec3(0.75 + 0.25 * n) * (1.0 - 0.35 * veins), 1.0);
		]]),
	}
	local seed = 1

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	for gx = 0, GRID - 1 do
		for gz = 0, GRID - 1 do
			local scale = 1.2 + random() * 1.6
			local entity = Entity.New{Name = "micro_rock", Parent = root}
			entity:AddComponent("transform")
			entity.transform:SetPosition(
				Vec3(
					(gx - GRID / 2 + random() * 0.6) * SPACING,
					scale * 0.45,
					-10 - (gz + random() * 0.6) * SPACING
				)
			)
			entity.transform:SetRotation(QuatDeg3(0, random() * 360, 0))
			entity.transform:SetScale(Vec3(scale, scale, scale))
			entity:AddComponent("visual")
			local primitive = Entity.New{Name = "micro_rock_primitive", Parent = entity}
			primitive:AddComponent("transform")
			primitive:AddComponent("visual_primitive"):SetPolygon3D(rock)
			primitive.visual_primitive:SetMaterial(material)
			entity.visual:BuildAABB()
		end
	end
end

if os.getenv("MICRO_GROUND") ~= "0" then
	shapes.Polygon{
		Name = "micro_ground",
		Parent = root,
		Material = shapes.Material{
			Color = Color(0.45, 0.42, 0.36, 1),
			Roughness = 0.9,
			Metallic = 0,
			AlbedoTexture = shapes.Texture([[
				float n = fract(sin(dot(floor(uv * 16.0), vec2(12.9898, 78.233))) * 43758.5453);
				return vec4(vec3(0.8 + 0.2 * n), 1.0);
			]]),
			HeightTexture = shapes.Texture([[
				vec2 p = uv * 6.2831853;
				float h = 0.5 + 0.25 * sin(p.x * 1.3) * sin(p.y * 1.1) + 0.15 * sin(p.x * 4.7 + p.y * 3.1) + 0.1 * sin(p.x * 13.0) * sin(p.y * 11.0);
				return vec4(clamp(h, 0.0, 1.0));
			]]),
			HeightScale = 0.05,
			HeightTessellate = true,
		},
		RigidBody = {MotionType = "static", Friction = 0.8, Restitution = 0},
		Polygon = function(poly)
			shapes.BuildPlane(poly, Vec3(0, 0, -90), Vec3(0, 1, 0), 240, 240, 24, 96, 96)
		end,
	}
end

return root
