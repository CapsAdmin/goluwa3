local T = import("test/environment.lua")
local ffi = require("ffi")
local steam = import("goluwa/steam/steam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local vfs = import("goluwa/vfs.lua")
local codec = import("goluwa/codec.lua")
local kv3 = import("lua/source_loader/source2/kv3.lua")
local resource = import("lua/source_loader/source2/resource.lua")
local vbib = import("lua/source_loader/source2/vbib.lua")
local vtex_c = import("lua/codecs/vtex_c.lua")
local entity_lump = import("lua/source_loader/source2/entity_lump.lua")

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
	local children, body = import("lua/source_loader/source2/vphys.lua").Load("maps/a2_pistol/world_physics.vphys_c")
	T(#children > 1000)["=="](true)
	T(body.Friction > 0.5 and body.Friction <= 1)["=="](true)
	T(body.FrictionCombineMode)["=="]("multiply")
	local meshes, hulls = 0, 0

	for _, child in ipairs(children) do
		if child.Shape and child.Shape:GetTypeName() == "mesh" then
			meshes = meshes + 1
		elseif child.ConvexHull then
			hulls = hulls + 1
			T(getmetatable(child.ConvexHull.vertices[1]))["=="](getmetatable(Vec3()))
			T(getmetatable(child.ConvexHull.faces[1].normal))["=="](getmetatable(Vec3()))
			T(getmetatable(child.Position))["=="](getmetatable(Vec3()))
		end
	end

	T(meshes > 0)["=="](true)
	T(hulls > 0)["=="](true)
end)

T.Test("source 2 maps name their skybox in a skybox_reference entity", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local world = import("lua/source_loader/source2/world.lua")

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
	local world = import("lua/source_loader/source2/world.lua")
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

T.Test("xen foliage materials absorb their transmission colour through a medium", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	local Material = import("goluwa/render3d/material.lua")
	local media = import("goluwa/render3d/media.lua")
	local foam = material.GetInfo("materials/models/props/xen/xen_foam_straight_anchor01_to_xen_cleanup.vmat")
	T(foam.shader)["=="]("vr_xen_foliage.vfx")
	local self = Material.New()
	material.ApplyXenFoliage(self, foam)
	T(self:GetSubsurface())["=="](0)
	T(self:GetDiffuseTransmission() > 0.2 and self:GetDiffuseTransmission() < 0.6)["=="](true)
	local absorption = media.presets[self:GetMedium()].Absorption
	T(absorption.x < absorption.y and absorption.y < absorption.z)["=="](true)
end)

T.Test3D("source 2 glass, bottles and liquids are refractive with their colour as a medium", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	local Material = import("goluwa/render3d/material.lua")
	local media = import("goluwa/render3d/media.lua")
	local glass_info = material.GetInfo("materials/models/particle/combine_ball_glass.vmat")
	T(glass_info.glass)["=="](true)
	local glass = Material.New()
	material.ApplyGlass(glass, glass_info)
	T(glass:GetRefraction())["=="](1)
	T(glass:GetIndexOfRefraction())["=="](1.5)
	local absorption = media.presets[glass:GetMedium()].Absorption
	T(absorption.x > absorption.y)["=="](true)
	local holo = material.GetInfo("materials/particle/hologram/box_noise_00_holo_fail.vmat")
	T(holo.additive)["=="](true)
	T(holo.translucent)["=="](true)
	T(holo.ints.F_UNLIT)["=="](1)
	T(material.GetInfo("materials/combine/combine_vault_glass_b.vmat").additive)["=="](true)
	local bottle_info = material.GetInfo("materials/models/props_interiors/waterbottle.vmat")
	T(bottle_info.bottle)["=="](true)
	local bottle = Material.New()
	material.ApplyBottle(bottle, bottle_info)
	T(bottle:GetRefraction())["=="](1)
	T(bottle:GetMedium())["=="]("")
	T(bottle:GetRoughnessTexture() ~= nil)["=="](true)
	T(math.abs(bottle:GetRoughnessMax() - 0.793) < 0.001)["=="](true)
	local liquid_info = material.GetInfo("materials/models/props_interiors/waterbottle_liquid.vmat")
	T(liquid_info.liquid)["=="](true)
	local liquid = Material.New()
	material.ApplyLiquid(liquid, liquid_info)
	T(liquid:GetRefraction())["=="](1)
	T(liquid:GetMedium() ~= "")["=="](true)
end)

T.Test("vtex textures with clamp flags are not read as cube maps", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local Buffer = import("goluwa/structs/buffer.lua")
	local vtex_c = import("lua/codecs/vtex_c.lua")
	local data = vfs.Read("materials/models/hologram_fx/combine_locker_outline_color_tga_5bb97b2e.vtex_c")
	local meta = vtex_c.DecodeBuffer(Buffer.New(data, #data))
	T(meta.width)["=="](1024)
	T(meta.depth)["=="](1)
	T(meta.mip_info[1].depth)["=="](1)
end)

T.Test3D("source 2 alpha tests follow their edge strength and only named translucent ones blend", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	local liquid = material.FromVMAT("materials/models/props/combine/combine_antlion_juice_tank_liquid_trans.vmat")
	T(liquid:GetTranslucent())["=="](true)
	T(liquid:GetAlphaTest())["=="](false)
	local van_glass = material.FromVMAT("materials/models/props_vehicles/van_a01/van_a01_glass.vmat")
	T(van_glass:GetTranslucent())["=="](true)
	T(van_glass:GetAlphaTest())["=="](false)
	local leaves = material.FromVMAT("materials/models/props_foliage/tree_branches_001_autumn.vmat")
	T(leaves:GetTranslucent())["=="](false)
	T(leaves:GetAlphaTest())["=="](true)
	T(leaves:GetAlphaCoverage())["=="](true)
	local grass = material.FromVMAT("materials/nature/dried_grass_card_01.vmat")
	T(grass:GetAlphaTest())["=="](true)
	T(grass:GetAlphaCoverage())["=="](false)
end)

T.Test3D("source 2 self illumination is a colour map scaled by the albedo factor and brightness stops", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	local liquid = material.FromVMAT("materials/models/props/combine/combine_antlion_juice_tank_liquid.vmat")
	T(liquid:GetEmissiveTextureIsColor())["=="](true)
	T(liquid:GetEmissiveAlbedoFactor())["=="](1)
	T(math.abs(liquid:GetEmissiveMultiplier().r - 2 ^ 1.5) < 1e-4)["=="](true)
	local mean = liquid:GetEmissiveMean()
	T(mean.r > mean.g and mean.g > mean.b and mean.r < 0.5)["=="](true)
	local scene_materials = import("goluwa/render3d/scene/materials.lua")
	local r = scene_materials.GetEmissive(liquid)
	T(math.abs(r - liquid:GetEmissiveMultiplier().r * mean.r) < 1e-5)["=="](true)
end)

T.Test3D("source 2 vr_complex materials without F_SPECULAR have no specular", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	T(
		material.FromVMAT("materials/particle/hologram/box_noise_00_holo_fail.vmat"):GetSpecularMultiplier()
	)["=="](0)
	T(
		material.FromVMAT("materials/models/props/combine/combine_antlion_juice_tank_liquid.vmat"):GetSpecularMultiplier()
	)["=="](1)
end)

T.Test("source 2 occluder draw calls have no material and are not packed", function()
	local mesh_pack = import("lua/source_loader/source2/mesh_pack.lua")
	local entries = {}
	local data = {
		m_sceneObjects = {
			{
				m_drawCalls = {
					{
						m_nPrimitiveType = "RENDER_PRIM_TRIANGLES",
						m_nIndexCount = 144,
						m_bIsOccluder = true,
					},
				},
			},
		},
	}
	mesh_pack.PackMeshes(nil, entries, data, nil, "occluder")
	T(#entries)["=="](0)
end)

T.Test("vtex mean colour comes from the smallest mip of a prefix of the file", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local vtex_c = import("lua/codecs/vtex_c.lua")
	local path = "models/props_combine/combine_fence/materials/combine_doorway_fence_lit_tga_ec057ec8.vtex_c"
	local file_path, offset, size = vfs.GetReadLocation(path)
	local file = assert(io.open(file_path, "rb"))
	file:seek("set", offset)
	local r, g, b = vtex_c.GetMeanColor(file:read(math.min(size, 65536)))
	file:close()
	T(r < g and r < b)["=="](true)
	T(g > 0.1 and g < 0.4)["=="](true)
end)

T.Test("source 2 draw call tints reach the model as tinted entries", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local world = import("lua/source_loader/source2/world.lua")
	vfs.Mount(world.GetMapDirectory(info) .. "a1_intro_world.vpk/")
	local resource = import("lua/source_loader/source2/resource.lua")
	local mesh_pack = import("lua/source_loader/source2/mesh_pack.lua")
	local tints = {}

	for _, batch in ipairs{"b696", "b1071"} do
		local path = "maps/a1_intro_world/worldnodes/node000_lr0_" .. batch .. "_im1_cb1_vism" .. (
				batch == "b696" and
				"23" or
				"28"
			) .. "_mt_hotel_wall_painted_001.vmdl_c"
		local res = resource.Load(vfs, path)
		local input = {path = path, model = res.data, meshes = {}}

		for _, mesh in ipairs(resource.ReadKV3(res).m_refMeshes) do
			input.meshes[#input.meshes + 1] = vfs.Read(mesh .. "_c")
		end

		tints[batch] = mesh_pack.PackModel(input).entries[1].tint
	end

	T(tints.b1071)["=="](nil)
	T(tints.b696[1] > tints.b696[2] and tints.b696[2] > tints.b696[3])["=="](true)
end)

T.Test3D("source 2 material color tints are srgb", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	local color = material.FromVMAT("materials/models/props/junk/plasticbucket001.vmat"):GetColorMultiplier()
	T(math.abs(color.r - 0.737) < 0.01)["=="](true)
	T(color.g < 0.07 and color.b < 0.05)["=="](true)
end)

T.Test3D("source 2 foliage animation becomes engine vegetation bending", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local resource = import("lua/source_loader/source2/resource.lua")
	local mesh_pack = import("lua/source_loader/source2/mesh_pack.lua")
	local material = import("lua/source_loader/source2/material.lua")
	local path = "models/props_foliage/foliage_weed_001a.vmdl_c"
	local res = resource.Load(vfs, path)
	local meta = mesh_pack.PackModel{path = path, model = res.data, meshes = {}, masks = {}, external = 0}
	T(meta.entries[1].foliage)["=="](true)
	local moving = material.FromVMAT("materials/models/props_foliage/foliage_weed_001.vmat")
	T(moving:GetDetailBending())["=="]("leaves")
	T(math.abs(moving:GetBending() - 3.5) < 0.01)["=="](true)
	local still = material.FromVMAT("materials/models/props_foliage/foliage_weed_001_nomotion.vmat")
	T(still:GetDetailBending())["=="]("none")
	T(still:GetBending())["=="](0)
end)

T.Test("source 2 surface properties", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local surface_properties = import("lua/source_loader/source2/surface_properties.lua")
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

T.Test("source 2 skinned models pack a skeleton, weights and clips", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local mesh_pack = import("lua/source_loader/source2/mesh_pack.lua")
	local animation = import("lua/source_loader/source2/animation.lua")
	local res = resource.Load(vfs, "models/characters/eli/eli.vmdl_c")
	local model_data = resource.ReadKV3(res)
	local meta, blob = mesh_pack.PackModel{
		path = "eli",
		model = res.data,
		masks = model_data.m_refLODGroupMasks,
		external = 0,
		meshes = {},
	}
	local skeleton = meta.skeleton
	T(#skeleton.names)["=="](#skeleton.kept)
	T(#skeleton.names > 500 and #skeleton.names <= 1024)["=="](true)
	T(skeleton.cloth.count)["=="](495)
	T(skeleton.cloth.rod_count)["=="](2717)
	T(skeleton.cloth.bend_count)["=="](1566)
	T(skeleton.cloth.capsule_count)["=="](13)
	T(skeleton.names[1])["=="]("pelvis")
	T(skeleton.parents[1])["=="](-1)
	local ref_pose

	for _, clip in ipairs(skeleton.clips) do
		if clip.name == "ref_pose" then ref_pose = clip end
	end

	T(ref_pose.frame_count)["=="](1)

	for _, entry in ipairs(meta.entries) do
		local weights = ffi.cast("const float *", blob + entry.bone_weights_offset)
		local indices = ffi.cast("const uint16_t *", blob + entry.bone_ids_offset)

		for v = 0, entry.vertex_count - 1 do
			T(math.abs(weights[v * 4] + weights[v * 4 + 1] + weights[v * 4 + 2] - 1) < 1e-4)["=="](true)
			T(weights[v * 4 + 3])["=="](0)

			for k = 0, 3 do
				T(indices[v * 4 + k] < #skeleton.names)["=="](true)
			end
		end
	end

	local bind = ffi.cast("const float *", blob + skeleton.bind_offset)
	local pose = ffi.new("float[?]", #skeleton.kept * 7)
	animation.NewDecoder(res, animation.ReadBones(model_data, skeleton.cloth_parents), skeleton.kept):ReadFrame(ref_pose.animation, 0, pose)

	for k = 0, #skeleton.kept - 1 do
		local o = k * 7

		for c = 0, 2 do
			T(math.abs(pose[o + c] - bind[o + c]) < 1e-3)["=="](true)
		end

		T(
			math.abs(
					pose[o + 3] * bind[o + 3] + pose[o + 4] * bind[o + 4] + pose[o + 5] * bind[o + 5] + pose[o + 6] * bind[o + 6]
				) > 0.999
		)["=="](true)
	end
end)

T.Test("source 2 material info", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
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

T.Test("source 2 sound files decode to pcm", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local sound = assert(codec.DecodeFile("sounds/physics/surfaces/cardboard/impact_a_01.vsnd_c"))
	T(sound.sample_rate)["=="](44100)
	T(sound.channels)["=="](1)
	T(sound.samples)["=="](2148)
	local peak = 0

	for i = 0, sound.samples - 1 do
		peak = math.max(peak, math.abs(sound.data[i]))
	end

	T(peak > 0.01 and peak <= 1)["=="](true)
	local stereo = assert(codec.DecodeFile("sounds/physics/breaking/break_body_01.vsnd_c"))
	T(stereo.channels)["=="](2)
end)

T.Test("source 2 materials take their physics surface", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local material = import("lua/source_loader/source2/material.lua")
	T(material.GetInfo("materials/architecture/hotel/hotel_wall_painted_001.vmat").surface)["=="]("world.plaster")
end)
