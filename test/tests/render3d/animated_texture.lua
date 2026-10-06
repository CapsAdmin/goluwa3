local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local material_proxies = import("goluwa/render3d/material_proxies.lua")
local Texture = import("goluwa/render/texture.lua")
local Entity = import("goluwa/entities/entity.lua")
local codec = import("goluwa/codec.lua")
local vtf = import("goluwa/codecs/vtf.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local build = import("test/vtf_frames.lua")
local vmt = [[
"UnlitGeneric"
{
	"Proxies"
	{
		"AnimatedTexture"
		{
			"animatedtexturevar" "$basetexture"
			"animatedtextureframenumvar" "$frame"
			"animatedtextureframerate" 1
		}
	}
}
]]

T.Test3D("Graphics render3d animated vtf frames reach the albedo", function(draw)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local data = build{0xF800, 0x07E0, 0x001F, 0xFFFF}
	local meta, blob = vtf.DecodeBuffer(Buffer.New(data, #data))
	local decoded = codec.AttachBlob(meta, {ptr = blob, len = ffi.sizeof(blob), owner = blob})
	local texture = Texture.New{decoded = decoded, srgb = true}
	T(texture:GetFrameCount())["=="](4)
	local material = Material.New{DoubleSided = true}
	material:SetAlbedoTexture(texture)
	T(material_proxies.Attach(material, vmt))
	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 0.5, 1.0)
	cube:BuildBoundingBox()
	cube:Upload()
	local entity = Entity.New{Name = "animated_texture_cube"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -2))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "animated_texture_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(cube)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	local size = render.GetRenderImageSize()
	local seen = {}

	for frame = 0, 3 do
		material_proxies.Update(frame)
		draw()
		local r, g, b = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
		seen[frame + 1] = (r > 128 and "r" or "") .. (g > 128 and "g" or "") .. (b > 128 and "b" or "")
	end

	entity:Remove()
	T(seen[1])["=="]("r")
	T(seen[2])["=="]("g")
	T(seen[3])["=="]("b")
	T(seen[4])["=="]("rgb")
end)
