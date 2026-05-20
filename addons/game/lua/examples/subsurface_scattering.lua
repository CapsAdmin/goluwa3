local Entity = import("goluwa/ecs/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local noise = import("goluwa/noise.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local ffi = require("ffi")

local function new_plane(width, height, normal, right, up)
	local poly = Polygon3D.New()
	poly:CreatePlane(Vec3(0, 0, 0), normal, right, up, width, height, 1, 1, 1)
	poly:Upload()
	return poly
end

local function new_sphere(radius, segments, rings)
	local poly = Polygon3D.New()
	poly:CreateSphere(radius, segments or 24, rings or 24)
	poly:Upload()
	return poly
end

local function new_cube(size, subdivisions)
	local poly = Polygon3D.New()
	poly:CreateCube(size or 0.5, 1, subdivisions or 1)
	poly:Upload()
	return poly
end

local function make_thickness_texture(size)
	size = size or 128
	local buffer = ffi.new("uint8_t[?]", size * size * 4)

	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local u = x / math.max(size - 1, 1)
			local v = y / math.max(size - 1, 1)
			local cx = u * 2 - 1
			local cy = v * 2 - 1
			local edge_distance = math.max(math.abs(cx), math.abs(cy))
			local falloff = math.clamp(1 - edge_distance, 0, 1)
			local center_weight = math.clamp(0.45 + falloff * 0.55, 0, 1)
			local broad_noise = noise.Simplex2D(u * 2.25 + 11.7, v * 2.25 - 4.3) * 0.5 + 0.5
			local detail_noise = noise.Simplex2D(u * 7.5 - 3.1, v * 7.5 + 8.4) * 0.5 + 0.5
			local patch_noise = noise.Simplex2D(u * 4.0 + 21.5, v * 4.0 - 17.2) * 0.5 + 0.5
			local noise_mask = broad_noise * 0.4 + patch_noise * 0.35 + detail_noise * 0.25
			local thickness = center_weight * 0.35 + noise_mask * 0.65
			thickness = thickness * 0.9 + falloff * 0.1
			thickness = math.clamp(thickness, 0.12, 1)
			local value = math.floor(thickness * 255 + 0.5)
			local idx = (y * size + x) * 4
			buffer[idx + 0] = value
			buffer[idx + 1] = value
			buffer[idx + 2] = value
			buffer[idx + 3] = value
		end
	end

	return Texture.New{
		width = size,
		height = size,
		format = "r8g8b8a8_unorm",
		buffer = buffer,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

local function spawn_primitive(name, position, polygon, material)
	local ent = Entity.New{Name = name, Parent = Entity.World}
	ent:AddComponent("transform")
	ent:AddComponent("visual")
	ent.transform:SetPosition(position)
	ent.visual:CreatePrimitiveEntity(polygon, material, name .. "_primitive")
	return ent
end

local thickness_texture = make_thickness_texture(128)

local function make_subsurface_material(albedo, transmission_color, view_dependency, blocking)
	return Material.New{
		ColorMultiplier = albedo,
		RoughnessMultiplier = 0.85,
		MetallicMultiplier = 0,
		DoubleSided = true,
		OpacityTexture = thickness_texture,
		Subsurface = true,
		TransmissionColor = transmission_color,
		TransmissionViewDependency = view_dependency,
		TransmissionBlocking = blocking,
	}
end

local function make_occluder_material(albedo, metallic, roughness)
	return Material.New{
		ColorMultiplier = albedo,
		MetallicMultiplier = metallic,
		RoughnessMultiplier = roughness,
	}
end

local forward = Vec3(0, 0, 1)
local right = Vec3(1, 0, 0)
local up = Vec3(0, 1, 0)
local anchor = Vec3(0, 7.5, 0)
local plane_polygon = new_plane(0.9, 0.9, forward * -1, right, up)
local sphere_polygon = new_sphere(0.55, 24, 24)
local cube_polygon = new_cube(0.55, 1)
spawn_primitive(
	"subsurface_reference_plane",
	anchor + right * -3.2 + up * 1.2,
	plane_polygon,
	Material.New{
		ColorMultiplier = Color(0.18, 0.42, 0.12, 1),
		RoughnessMultiplier = 0.9,
		MetallicMultiplier = 0,
		DoubleSided = true,
	}
)
spawn_primitive(
	"subsurface_thin_plane",
	anchor + right * -1.05 + up * 1.2,
	plane_polygon,
	make_subsurface_material(Color(0.2, 0.45, 0.14, 1), Color(0.72, 0.88, 0.34, 0.75), 0.25, 0.2)
)
spawn_primitive(
	"subsurface_mid_plane",
	anchor + right * 1.05 + up * 1.2,
	plane_polygon,
	make_subsurface_material(Color(0.22, 0.48, 0.15, 1), Color(0.8, 0.94, 0.38, 0.85), 0.45, 0.5)
)
spawn_primitive(
	"subsurface_thick_plane",
	anchor + right * 3.2 + up * 1.2,
	plane_polygon,
	make_subsurface_material(Color(0.24, 0.5, 0.16, 1), Color(0.92, 1.0, 0.42, 1.0), 0.7, 0.9)
)
spawn_primitive(
	"subsurface_thin_sphere",
	anchor + right * -2.1 + up * -1.05,
	sphere_polygon,
	make_subsurface_material(Color(0.35, 0.18, 0.18, 1), Color(1.0, 0.42, 0.32, 0.85), 0.2, 0.2)
)
spawn_primitive(
	"subsurface_mid_sphere",
	anchor + up * -1.05,
	sphere_polygon,
	make_subsurface_material(Color(0.45, 0.22, 0.18, 1), Color(1.0, 0.55, 0.34, 0.95), 0.45, 0.55)
)
spawn_primitive(
	"subsurface_thick_sphere",
	anchor + right * 2.1 + up * -1.05,
	sphere_polygon,
	make_subsurface_material(Color(0.5, 0.24, 0.2, 1), Color(1.0, 0.66, 0.38, 1.0), 0.7, 0.95)
)
spawn_primitive(
	"subsurface_occluder_left_sphere",
	anchor + right * -2.7 + up * 2.9 + forward * 0.75,
	sphere_polygon,
	make_occluder_material(Color(0.72, 0.76, 0.82, 1), 1.0, 0.18)
)
spawn_primitive(
	"subsurface_occluder_right_sphere",
	anchor + right * 2.4 + up * 2.6 + forward * -0.55,
	sphere_polygon,
	make_occluder_material(Color(0.86, 0.72, 0.42, 1), 0.85, 0.22)
)
spawn_primitive(
	"subsurface_occluder_center_cube",
	anchor + up * 3.45,
	cube_polygon,
	make_occluder_material(Color(0.7, 0.74, 0.78, 1), 1.0, 0.08)
)
spawn_primitive(
	"subsurface_occluder_side_plane_a",
	anchor + right * -4.3 + up * 1.0 + forward * 0.35,
	new_plane(0.35, 1.8, right, forward, up),
	make_occluder_material(Color(0.14, 0.16, 0.2, 1), 0.0, 0.28)
)
spawn_primitive(
	"subsurface_occluder_side_plane_b",
	anchor + right * 4.3 + up * 0.7 + forward * -0.35,
	new_plane(0.35, 1.8, right * -1, forward, up),
	make_occluder_material(Color(0.22, 0.18, 0.16, 1), 0.0, 0.35)
)
print("spawned subsurface scattering test scene at", anchor)
