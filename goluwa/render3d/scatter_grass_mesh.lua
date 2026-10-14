local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Texture = import("goluwa/render/texture.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local scatter_grass_mesh = {}
local SEGMENTS = 4
local GRADIENT_WIDTH = 8
local GRADIENT_HEIGHT = 16
local material

-- a blade is lit by its tuft rather than by its own facing, so the vertex normal is mostly up
local NORMAL_UP = 0.6

local function get_material()
	if material then return material end

	local pixels = ffi.new("uint8_t[?]", GRADIENT_WIDTH * GRADIENT_HEIGHT * 4)

	for y = 0, GRADIENT_HEIGHT - 1 do
		local t = y / (GRADIENT_HEIGHT - 1)

		for x = 0, GRADIENT_WIDTH - 1 do
			local edge = math.abs(x / (GRADIENT_WIDTH - 1) * 2 - 1)
			local shade = math.lerp(0.45, 1.0, t) * (1 - edge * edge * 0.18)
			local i = (y * GRADIENT_WIDTH + x) * 4
			-- near neutral, the tint of the instance brings the color
			pixels[i] = math.min(shade * 0.62 * 255, 255)
			pixels[i + 1] = math.min(shade * 0.72 * 255, 255)
			pixels[i + 2] = math.min(shade * 0.42 * 255, 255)
			pixels[i + 3] = 255
		end
	end

	material = Material.New()
	material:SetAlbedoTexture(
		Texture.New{
			width = GRADIENT_WIDTH,
			height = GRADIENT_HEIGHT,
			format = "r8g8b8a8_srgb",
			buffer = pixels,
			mip_map_levels = 1,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	material:SetDoubleSided(true)
	material:SetMetallicMultiplier(0)
	material:SetRoughnessMultiplier(0.7)
	-- F0 0.02 rather than 0.04, edge on blades otherwise get a white sheen from the fresnel
	material:SetSpecularMultiplier(0.5)
	-- light through the blade, a yellow green tint with luminance 1
	material:SetDiffuseTransmission(0.4)
	material:SetTransmissionScattering(0.5)
	material:SetTransmissionColor(Color(0.9, 1.07, 0.6, 1))
	material:SetBending(1)
	material:SetDetailBending("grass")
	return material
end

-- one tuft of curved blades around the origin, up is +y. the vertex colors are the vegetation bending
-- convention: r edge flutter, g phase, b stiffness (1 rigid), a occlusion
function scatter_grass_mesh.Build(options)
	local blade_count = options.blades
	local state = options.seed * 2654435761 % 4294967296

	local function rand()
		state = (state * 1664525 + 1013904223) % 4294967296
		return state / 4294967296
	end

	local polygon = Polygon3D.New()
	local indices = {}
	local vertex_count = 0

	for _ = 1, blade_count do
		local angle = rand() * math.pi * 2
		local distance = math.sqrt(rand()) * options.radius
		local root = Vec3(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local facing_angle = rand() * math.pi * 2
		local facing = Vec3(math.cos(facing_angle), 0, math.sin(facing_angle))
		local side = Vec3(-facing.z, 0, facing.x)
		-- blades toward the middle of the tuft stand taller and straighter
		local centered = 1 - distance / options.radius
		local height = options.height * math.lerp(0.55, 1.0, rand()) * math.lerp(0.75, 1.0, centered)
		local lean = math.lerp(0.1, options.lean, rand() * rand()) * math.lerp(1.0, 0.6, centered)
		local width = options.width * math.lerp(0.7, 1.4, rand())
		local phase = rand()
		local first = vertex_count + 1

		for row = 0, SEGMENTS do
			local t = row / SEGMENTS
			local center = root + Vec3(0, height * t, 0) + facing * (lean * height * t * t)
			local tangent = (Vec3(0, height, 0) + facing * (2 * lean * height * t)):GetNormalized()
			local normal = tangent:GetCross(side):GetNormalized()
			normal = (normal * (1 - NORMAL_UP) + Vec3(0, 1, 0) * NORMAL_UP):GetNormalized()
			local color = {t * (0.5 + rand() * 0.5), phase, 1 - t, 1}

			if row == SEGMENTS then
				polygon:AddVertex{pos = center, normal = normal, uv = Vec2(0.5, 1), color = color}
				vertex_count = vertex_count + 1
			else
				local half = width * 0.5 * (1 - t ^ 1.4)

				for across = -1, 1, 2 do
					polygon:AddVertex{
						pos = center + side * (half * across),
						normal = normal,
						uv = Vec2(across * 0.5 + 0.5, t),
						color = color,
					}
					vertex_count = vertex_count + 1
				end
			end
		end

		for row = 0, SEGMENTS - 2 do
			local a = first + row * 2
			list.insert(indices, a)
			list.insert(indices, a + 1)
			list.insert(indices, a + 2)
			list.insert(indices, a + 1)
			list.insert(indices, a + 3)
			list.insert(indices, a + 2)
		end

		local a = first + (SEGMENTS - 1) * 2
		list.insert(indices, a)
		list.insert(indices, a + 1)
		list.insert(indices, a + 2)
	end

	polygon:Upload(indices)
	polygon:SetBendHeight(options.height)
	return {{mesh = polygon, material = get_material()}}
end

return scatter_grass_mesh
