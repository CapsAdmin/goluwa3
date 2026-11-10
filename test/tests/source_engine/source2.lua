local T = import("test/environment.lua")
local ffi = require("ffi")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local codec = import("goluwa/codec.lua")
local kv3 = import("goluwa/source_engine/source2/kv3.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local vbib = import("goluwa/source_engine/source2/vbib.lua")
local vtex_c = import("goluwa/codecs/vtex_c.lua")
local entity_lump = import("goluwa/source_engine/source2/entity_lump.lua")

T.Test("source 2 text kv3", function()
	local data = kv3.DecodeText([[<!-- kv3 encoding:text:version{e21c7f3c} format:generic:version{7412167c} -->
{
	name = "a b"
	flag = true
	"quoted.key" = -1.5
	list = [ 1, 2, "x" ]
	res = resource:"a/b.vmat"
}]])
	T(data.name)["=="]("a b")
	T(data.flag)["=="](true)
	T(data["quoted.key"])["=="](-1.5)
	T(#data.list)["=="](3)
	T(data.res)["=="]("a/b.vmat")
end)

T.Test("source 2 entity key hash", function()
	T(entity_lump.Hash("classname"))["=="](3323665506)
	T(entity_lump.Hash("origin"))["=="](3827302934)
end)

T.Test("source 2 alyx resources", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local res = resource.Load(vfs, "models/props_c17/oildrum001.vmdl_c")
	local control = resource.ReadKV3(res, "CTRL")
	local lod0 = control.embedded_meshes[1]
	local mesh = resource.ReadKV3(res, lod0.data_block)
	local buffers = vbib.Parse(res.data, res.list[lod0.vbib_block].offset)
	local draw_call = mesh.m_sceneObjects[1].m_drawCalls[1]
	local vb = buffers.vertex[draw_call.m_vertexBuffers[1].m_hBuffer]
	local ib = buffers.index[draw_call.m_indexBuffer.m_hBuffer]
	T(vb.element_count > 0)["=="](true)
	local position = vbib.GetField(vb, "POSITION")
	local normal = vbib.GetField(vb, "NORMAL")

	for i = 0, vb.element_count - 1 do
		local x, y, z = vbib.Read(vb, position, i)
		T(math.abs(x) < 100 and math.abs(y) < 100 and math.abs(z) < 100)["=="](true)
		local nx, ny, nz = vbib.ReadNormalTangent(vb, normal, i)
		T(math.abs(nx * nx + ny * ny + nz * nz - 1) < 0.01)["=="](true)
	end

	local indices = ffi.cast(ib.element_size == 2 and "const uint16_t *" or "const uint32_t *", ib.data)

	for i = 0, draw_call.m_nIndexCount - 1 do
		T(indices[draw_call.m_nStartIndex + i] < draw_call.m_nVertexCount)["=="](true)
	end

	local material = resource.ReadKV3(resource.Load(vfs, "materials/models/props/hooks_2.vmat_c"))
	local data = vfs.Read(material.m_textureParams[2].m_pValue .. "_c")
	local img = codec.DecodeWithModule("x.vtex_c", data, vtex_c)
	T(img.width > 0 and img.mip_count > 0)["=="](true)
	T(img.vulkan_format)["=="]("bc7_unorm_block")
end)

T.Test("source 2 world physics", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	vfs.Mount(info.vdf_directory .. "maps/a2_pistol.vpk/")
	local children, body = import("goluwa/source_engine/source2/vphys.lua").Load("maps/a2_pistol/world_physics.vphys_c")
	T(#children > 1000)["=="](true)
	T(body.Friction > 0.5 and body.Friction <= 1)["=="](true)
	T(body.FrictionCombineMode)["=="]("multiply")
	local meshes = 0

	for _, child in ipairs(children) do
		if child.Shape and child.Shape:GetTypeName() == "mesh" then
			meshes = meshes + 1
		end
	end

	T(meshes > 0)["=="](true)
end)

T.Test("source 2 surface properties", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local surface_properties = import("goluwa/source_engine/source2/surface_properties.lua")
	local default = surface_properties.GetByHash(1977497166)
	T(default.friction)["=="](0.8)
	T(default.elasticity)["=="](0.25)
	T(surface_properties.GetByHash(0))["=="](default)
end)

T.Test("source 2 material info", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("goluwa/source_engine/source2/material.lua")
	local complex = material.GetInfo("materials/models/props/hooks_2.vmat")
	T(complex.shader)["=="]("vr_complex.vfx")
	T(complex.textures.g_tNormal ~= nil)["=="](true)
	T(complex.blend)["=="](false)
	T(material.GetInfo("materials/blend/concrete_5_floor_2_to_5b.vmat").blend)["=="](true)
	T(material.GetInfo("materials/tools/toolsnodraw.vmat").no_draw)["=="](true)
	T(material.GetInfo("materials/tools/toolsblocklight.vmat").block_light)["=="](true)
	T(material.GetInfo("materials/tools/toolssolidblocklight.vmat").block_light)["=="](true)
	local legacy = material.GetInfo("materials/architecture/hotspot/concrete_hs01a.vmat")
	T(legacy.shader)["=="]("vr_simple_2way_blend.vfx")
	T(legacy.textures.g_tColorA ~= nil)["=="](true)
	T(legacy.blend)["=="](true)
	local detail = material.GetInfo("materials/concrete/concrete_bunker_1_hs.vmat")
	T(detail.ints.F_DETAIL_TEXTURE)["=="](4)
	T(detail.textures.g_tNormalDetail ~= nil)["=="](true)
	local decal = material.GetInfo("materials/graffiti/graffiti015_decal.vmat")
	T(decal.decal)["=="](true)
	T(decal.translucent)["=="](true)
end)

T.Test("visual tint multiplies the material color once per material", function()
	local Material = import("goluwa/render3d/material.lua")
	local Color = import("goluwa/structs/color.lua")
	local Visual = import("goluwa/entities/components/visual.lua")
	local base = Material.New()
	base:SetColorMultiplier(Color(0.5, 1, 1, 1))
	base:SetBlendTintByBaseAlpha(true)
	local self = {MaterialOverride = base, Tint = {0.5, 0.25, 1}}
	local entry = {polygon3d = {}}
	local tinted = Visual.GetResolvedMaterial(self, entry)
	T(tinted ~= base)["=="](true)
	T(tinted:GetColorMultiplier().r)["=="](0.25)
	T(tinted:GetColorMultiplier().g)["=="](0.25)
	T(tinted:GetBlendTintByBaseAlpha())["=="](true)
	T(Visual.GetResolvedMaterial(self, entry))["=="](tinted)
	T(Visual.GetResolvedMaterial(self, {polygon3d = {}}))["=="](tinted)
	T(base:GetColorMultiplier().r)["=="](0.5)
end)
