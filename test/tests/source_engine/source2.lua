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

T.Test("textures inside archives decode on a worker that reads the bytes itself", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = resource.ReadKV3(resource.Load(vfs, "materials/models/props/hooks_2.vmat_c"))
	local path = material.m_textureParams[2].m_pValue .. "_c"
	local location, offset, size = vfs.GetReadLocation(path)
	T(location ~= nil and offset >= 0 and size > 16384)["=="](true)
	local expected = assert(codec.DecodeWithModule("x.vtex_c", vfs.Read(path), vtex_c))
	local async

	codec.DecodeFileAsync(path, function(img, err)
		async = img or err
	end)

	T.WaitUntilReal(function()
		return async ~= nil
	end, 20, "the archive texture to decode")

	T(type(async))["=="]("table")
	T(async.width)["=="](expected.width)
	T(async.mip_count)["=="](expected.mip_count)
	T(async.data_size)["=="](expected.data_size)
	T(ffi.string(async.data, 4096))["=="](ffi.string(expected.data, 4096))
	T(ffi.string(async.data + async.data_size - 4096, 4096))["=="](ffi.string(expected.data + expected.data_size - 4096, 4096))
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

T.Test("source 2 maps name their skybox in a skybox_reference entity", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local world = import("goluwa/source_engine/source2/world.lua")

	for name, expected in pairs{
		a3_hotel_street = "maps/a3_hotel_street/hotel_street_skybox_static",
		a3_c17_processing_plant = "maps/a3_c17_processing_plant/skybox",
		a2_pistol = "maps/a2_pistol/a2_pistol_skybox",
	} do
		vfs.Mount(world.GetMapDirectory(info) .. name .. ".vpk/")
		T(world.FindSkybox(name))["=="](expected)
		T(vfs.IsFile("os:" .. info.vdf_directory .. expected .. ".vpk"))["=="](true)
	end

	vfs.Mount(world.GetMapDirectory(info) .. "a2_headcrabs_tunnel.vpk/")
	T(world.FindSkybox("a2_headcrabs_tunnel"))["=="](nil)
end)

T.Test("source 2 maps keep vr hand poses out and build their constraints", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local world = import("goluwa/source_engine/source2/world.lua")
	vfs.Mount(world.GetMapDirectory(info) .. "a3_hotel_street.vpk/")
	local data = world.Translate("a3_hotel_street", nil)
	local kinds, banned, drawer = {}, 0, nil

	for _, record in ipairs(data.entities) do
		local components = record.components
		local visual = components and components.visual
		local path = visual and visual.ModelPath or ""

		if
			path:find("handposes/", 1, true) or
			path:find("washing_machine01a_door", 1, true) or
			path:find("washing_machine01a_loader", 1, true)
		then
			banned = banned + 1
		end

		local constraint = components and components.map_constraint

		if constraint then
			kinds[constraint.Kind] = (kinds[constraint.Kind] or 0) + 1

			if constraint.Kind == "slider" then drawer = drawer or constraint end
		end
	end

	T(banned)["=="](0)
	T(kinds.hinge > 50)["=="](true)
	T(kinds.slider > 20)["=="](true)
	T(kinds.weld >= 1)["=="](true)
	T(drawer.HasLimits)["=="](true)
	T(drawer.Upper - drawer.Lower)[">"](0.3)
	T(drawer.Entity0 ~= "")["=="](true)
end)

T.Test("xen foliage materials get subsurface scattering and transmission", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("goluwa/source_engine/source2/material.lua")
	local Material = import("goluwa/render3d/material.lua")
	local foam = material.GetInfo("materials/models/props/xen/xen_foam_straight_anchor01_to_xen_cleanup.vmat")
	T(foam.shader)["=="]("vr_xen_foliage.vfx")
	local self = Material.New()
	material.ApplyXenFoliage(self, foam)
	T(self:GetSubsurface())["=="](1)
	T(self:GetSubsurfaceColor().r > self:GetSubsurfaceColor().b)["=="](true)
	T(self:GetSubsurfaceRadius())["=="](7.5)
	T(self:GetSubsurfaceColor().g < 0.3)["=="](true)
	T(self:GetDiffuseTransmission() > 0.35 and self:GetDiffuseTransmission() < 0.6)["=="](true)
	T(self:GetTransmissionColor().g > self:GetTransmissionColor().b)["=="](true)
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

T.Test("source 2 models are listed by the asset index", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local index = import("goluwa/assets.lua").GetIndex("models")
	T(index.by_path["models/props/traffic_drum/traffic_drum.vmdl_c"] ~= nil)["=="](true)
end)

T.Test("source 2 default animation pose", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local animation = import("goluwa/source_engine/source2/animation.lua")
	local res = resource.Load(vfs, "models/a2_destruction/a2_beam_destruciton.vmdl_c")
	local model_data = resource.ReadKV3(res)
	local default = animation.GetDefaultAnimation(res)
	T(default)["=="](1)

	local function moved_bones(index)
		local bones, pose = animation.GetPose(res, model_data, index, 0)
		local moved = 0

		for i, bone in ipairs(bones) do
			local a, b = bone.position, pose[i].position

			if math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]) > 0.5 then
				moved = moved + 1
			end
		end

		return moved
	end

	T(moved_bones(1) > 200)["=="](true)
	T(moved_bones(3))["=="](0)
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
