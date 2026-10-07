local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ffi = require("ffi")

local function attach_visual_primitive(entity, poly, material)
	entity:AddComponent("visual")
	local primitive_entity = Entity.New{Name = entity:GetName() .. "_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(poly)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
end

local function create_entity(offset)
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)

	if offset then
		for _, vertex in ipairs(poly.Vertices) do
			vertex.pos = vertex.pos + offset
		end

		poly:BuildBoundingBox()
	end

	poly:Upload()
	local material = Material.New{
		ColorMultiplier = Color(1, 0.2, 0.2, 1),
		EmissiveMultiplier = Color(0.2, 0.02, 0.02, 1),
		DoubleSided = true,
	}
	local entity = Entity.New{Name = "preview_model"}
	entity:AddComponent("transform")
	attach_visual_primitive(entity, poly, material)
	return entity
end

local function create_solid_texture(r, g, b, a)
	local buffer = ffi.new("uint8_t[4]", r * 255, g * 255, b * 255, (a or 1) * 255)
	return Texture.New{
		width = 1,
		height = 1,
		format = "r8g8b8a8_unorm",
		buffer = buffer,
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
end

local function create_textured_entity()
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 0.5, 1.0)
	poly:Upload()
	local material = Material.New{
		AlbedoTexture = create_solid_texture(1, 0, 0, 1),
		ColorMultiplier = Color(1, 1, 1, 1),
		DoubleSided = true,
	}
	local entity = Entity.New{Name = "preview_textured_model"}
	entity:AddComponent("transform")
	attach_visual_primitive(entity, poly, material)
	return entity
end

T.Test3D("Model preview renders offscreen and restores the active camera", function()
	local entity = create_entity()
	local preview = ModelPreview.New()
	local camera = render3d.GetCamera()
	local old_position = camera:GetPosition():Copy()
	local old_rotation = camera:GetRotation():Copy()
	local ok, err = xpcall(
		function()
			local tex = preview:RenderTarget(entity.visual)
			T.AssertTexturePixel{
				tex = tex,
				pos = {128, 128},
				color = function(r, g, b, a)
					return r > 0.1 and g > 0.01 and a > 0.9
				end,
			}
			T.AssertTexturePixel{tex = tex, pos = {4, 4}, color = {0, 0, 0, 0}, tolerance = 0.05}
			T(render3d.GetCamera() == camera)["=="](true)
			T(camera:GetPosition() == old_position)["=="](true)
			T(camera:GetRotation() == old_rotation)["=="](true)
		end,
		debug.traceback
	)
	preview:Remove()
	entity:Remove()

	if not ok then error(err, 0) end
end)

T.Test3D("Model preview samples albedo textures", function()
	local entity = create_textured_entity()
	local preview = ModelPreview.New{
		AmbientStrength = 0.35,
		LightStrength = 0.85,
	}
	local ok, err = xpcall(
		function()
			local tex = preview:RenderTarget(entity.visual)
			T.AssertTexturePixel{
				tex = tex,
				pos = {128, 128},
				color = function(r, g, b, a)
					return r > 0.35 and g < 0.2 and b < 0.2 and a > 0.9
				end,
			}
		end,
		debug.traceback
	)
	preview:Remove()
	entity:Remove()

	if not ok then error(err, 0) end
end)

T.Test3D("Model preview draws the back faces of double sided materials", function()
	local function render_far_faces(double_sided)
		local cube = Polygon3D.New()
		shapes.BuildCube(cube, 0.5, 1.0)
		local poly = Polygon3D.New()

		for i = 1, #cube.Vertices, 3 do
			local a, b, c = cube.Vertices[i], cube.Vertices[i + 1], cube.Vertices[i + 2]
			local center = a.pos + b.pos + c.pos

			if center.x + center.y + center.z < 0 then
				poly:AddVertex(a)
				poly:AddVertex(b)
				poly:AddVertex(c)
			end
		end

		T(#poly.Vertices)["=="](18)
		poly:BuildBoundingBox()
		poly:Upload()
		local material = Material.New{
			ColorMultiplier = Color(1, 1, 1, 1),
			DoubleSided = double_sided,
		}
		local entity = Entity.New{Name = "preview_far_faces_model"}
		entity:AddComponent("transform")
		attach_visual_primitive(entity, poly, material)
		local preview = ModelPreview.New()
		local ok, a = xpcall(
			function()
				return select(4, preview:RenderTarget(entity.visual):GetPixel(128, 150))
			end,
			debug.traceback
		)
		preview:Remove()
		entity:Remove()

		if not ok then error(a, 0) end

		return a
	end

	T(render_far_faces(false))["=="](0)
	T(render_far_faces(true))["=="](255)
end)

T.Test3D("Visual MakeError creates a cube with the fallback texture", function()
	local entity = Entity.New{Name = "visual_error_test"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual:MakeError()
	local children = entity:GetChildren()
	local primitive = children[1] and children[1].visual_primitive or nil
	local material = primitive and primitive:GetMaterial() or nil
	T(#children)["=="](1)
	T(primitive ~= nil)["=="](true)
	T(material ~= nil)["=="](true)
	T(material:GetAlbedoTexture() == Texture.GetFallback())["=="](true)
	T(primitive:GetPolygon3D() ~= nil)["=="](true)
	entity:Remove()
end)

T.Test3D("Model preview Draw flips the framebuffer vertically so the model is upright", function()
	local render2d = import("goluwa/render2d/render2d.lua")
	local preview = ModelPreview.New()
	local sentinel_texture = {}
	local calls = {}
	local original = {}

	local function record(name)
		original[name] = render2d[name]
		render2d[name] = function(...)
			calls[#calls + 1] = {name, ...}
		end
	end

	for _, name in ipairs{
		"PushTexture",
		"PushColorUV",
		"SetColor",
		"DrawRect",
		"PopColorUV",
		"PopTexture",
	} do
		record(name)
	end

	preview.GetTexture = function()
		return sentinel_texture
	end
	local ok, err = pcall(preview.Draw, preview, 1, 2, 30, 40)

	for name, func in pairs(original) do
		render2d[name] = func
	end

	preview.GetTexture = nil
	preview:Remove()

	if not ok then error(err, 0) end

	local color_uv

	for _, call in ipairs(calls) do
		if call[1] == "PushColorUV" then color_uv = call end
	end

	T(calls[1][1])["=="]("PushTexture")
	T(calls[1][2] == sentinel_texture)["=="](true)
	T(color_uv[2])["=="](0)
	T(color_uv[3])["=="](1)
	T(color_uv[4])["=="](1)
	T(color_uv[5])["=="](0)

	for _, call in ipairs(calls) do
		if call[1] == "DrawRect" then
			T(call[2])["=="](1)
			T(call[3])["=="](2)
			T(call[4])["=="](30)
			T(call[5])["=="](40)
		end
	end

	T(calls[#calls][1])["=="]("PopTexture")
end)
