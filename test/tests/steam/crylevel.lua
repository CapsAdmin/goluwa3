local T = import("test/environment.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local crylevel = import("goluwa/steam/crylevel.lua")
local xml = import("goluwa/codecs/xml.lua")
local ffi = require("ffi")

local function pack_u32_le(value)
	return string.char(
		bit.band(value, 0xFF),
		bit.band(bit.rshift(value, 8), 0xFF),
		bit.band(bit.rshift(value, 16), 0xFF),
		bit.band(bit.rshift(value, 24), 0xFF)
	)
end

local function pack_f32_le(value)
	local u32f = ffi.new("union { uint32_t u; float f; }")
	u32f.f = value
	return pack_u32_le(tonumber(u32f.u))
end

local function pack_u16_le(value)
	return string.char(bit.band(value, 0xFF), bit.band(bit.rshift(value, 8), 0xFF))
end

local function build_engine_matrix(transform)
	local matrix = Matrix44()
	matrix:Identity()
	matrix:SetRotation(transform.rotation)

	if transform.scale.x ~= 1 or transform.scale.y ~= 1 or transform.scale.z ~= 1 then
		matrix:Scale(transform.scale.x, transform.scale.y, transform.scale.z)
	end

	matrix:SetTranslation(transform.position.x, transform.position.y, transform.position.z)
	return matrix
end

local empty_libraries = {prefabs = {}, archetypes = {}}

local function get_basis(transform)
	local basis = Matrix44():SetRotation(transform.rotation)
	return basis:TransformVector(Vec3(1, 0, 0)),
	basis:TransformVector(Vec3(0, 1, 0)),
	basis:TransformVector(Vec3(0, 0, -1))
end

T.Test("Cry level parser flattens group transforms for visual cgf objects", function()
	local entries = crylevel.ExtractVisualObjects(
		assert(
			crylevel.ParseLayerData([[
<ObjectLayer>
	<Layer Name="natural" Hidden="0">
		<LayerObjects>
			<Object Type="Group" Name="group" Pos="10,20,30" Rotate="1,0,0,0" Scale="2,3,4">
				<Objects>
					<Object Type="Brush" Name="rock" Pos="1,2,3" Rotate="1,0,0,0" Scale="5,6,7" Prefab="objects/natural/rocks/test_rock.cgf" />
					<Object Type="AIPoint" Name="skip_me" Pos="9,9,9" />
				</Objects>
			</Object>
		</LayerObjects>
	</Layer>
</ObjectLayer>
			]])
		),
		empty_libraries
	)
	T(#entries)["=="](1)
	T(entries[1].name)["=="]("rock")
	T(entries[1].model_path)["=="]("objects/natural/rocks/test_rock.cgf")
	local transform = crylevel.ConvertCryWorldMatrixToEngineTransform(entries[1].world_matrix)
	T(transform.position.x)["~"](12)
	T(transform.position.y)["~"](42)
	T(transform.position.z)["~"](-26)
	T(transform.scale.x)["~"](10)
	T(transform.scale.y)["~"](28)
	T(transform.scale.z)["~"](18)
	local basis = Matrix44():SetRotation(transform.rotation)
	local right = basis:TransformVector(Vec3(1, 0, 0))
	local up = basis:TransformVector(Vec3(0, 1, 0))
	local forward = basis:TransformVector(Vec3(0, 0, -1))
	T(right.x)["~"](1)
	T(right.y)["~"](0)
	T(right.z)["~"](0)
	T(up.x)["~"](0)
	T(up.y)["~"](1)
	T(up.z)["~"](0)
	T(forward.x)["~"](0)
	T(forward.y)["~"](0)
	T(forward.z)["~"](-1)
end)

T.Test("Cry level parser reads terrain metadata from leveldata xml", function()
	local terrain = assert(
		crylevel.ParseLevelData([[
<LevelData SandboxVersion="1.1.1.1">
	<LevelInfo HeightmapSize="2048" HeightmapUnitSize="2" HeightmapMaxHeight="1024" WaterLevel="100" TerrainSectorSizeInMeters="64" />
</LevelData>
		]])
	)
	T(terrain.heightmap_size)["=="](2048)
	T(terrain.heightmap_unit_size)["=="](2)
	T(terrain.heightmap_max_height)["=="](1024)
	T(terrain.water_level)["=="](100)
	T(terrain.terrain_sector_size)["=="](64)
	T(terrain.world_size)["=="](4096)
end)

T.Test("Cry level parser reads editor terrain metadata from level archive xml", function()
	local editor_level = assert(
		crylevel.ParseEditorLevelData([[
<Level HeightmapWidth="2048" HeightmapHeight="2048" WaterColor="16711680" SandboxVersion="1.1.1.1" TileCountX="4" TileCountY="4" TileResolution="512">
	<View ViewerPos="1089.1659,712.61017,184.97169" ViewerAngles="-0.6900003,0,0.52959281"/>
</Level>
		]])
	)
	T(editor_level.heightmap_width)["=="](2048)
	T(editor_level.heightmap_height)["=="](2048)
	T(editor_level.tile_count_x)["=="](4)
	T(editor_level.tile_count_y)["=="](4)
	T(editor_level.tile_resolution)["=="](512)
end)

T.Test("Cry level parser reads visual objects from editor level xml", function()
	local entries = crylevel.ExtractVisualObjects(
		assert(
			crylevel.ParseEditorObjectsData([[
<Level HeightmapWidth="2048" HeightmapHeight="2048">
	<ObjectLayers>
		<Layer Name="Main" Hidden="0" />
		<Layer Name="HiddenStuff" Hidden="1" />
	</ObjectLayers>
	<Objects NumObjects="3">
		<Object Type="Brush" Layer="Main" Name="crate" Pos="1,2,3" Rotate="1,0,0,0" Scale="1,1,1" Prefab="Objects\library\props\crate.cgf" />
		<Object Type="GeomEntity" Layer="Main" Name="tower" Pos="4,5,6" Rotate="1,0,0,0" Scale="1,1,1" Geometry="objects/structures/tower.cgf" />
		<Object Type="Brush" Layer="HiddenStuff" Name="skip_me" Pos="7,8,9" Rotate="1,0,0,0" Scale="1,1,1" Prefab="objects/hidden/skip.cgf" />
	</Objects>
</Level>
			]])
		),
		empty_libraries
	)
	T(#entries)["=="](2)
	T(entries[1].name)["=="]("crate")
	T(entries[1].model_path)["=="]("Objects/library/props/crate.cgf")
	T(entries[2].name)["=="]("tower")
	T(entries[2].model_path)["=="]("objects/structures/tower.cgf")
end)

T.Test("Cry quaternions are w first and cry yaw maps to engine yaw", function()
	local transform = crylevel.ConvertCryWorldMatrixToEngineTransform(crylevel.BuildCryLocalMatrix{Pos = "1967,2682,203", Rotate = "0.70710659,0,0,0.70710695"})
	local right, up, forward = get_basis(transform)
	T((transform.position - Vec3(1967, 203, -2682)):GetLength())["~"](0, 0.001)
	T((right - Vec3(0, 0, -1)):GetLength())["~"](0, 0.001)
	T((up - Vec3(0, 1, 0)):GetLength())["~"](0, 0.001)
	T((forward - Vec3(-1, 0, 0)):GetLength())["~"](0, 0.001)
end)

T.Test("Cry 180 degree yaw converts to a valid rotation", function()
	local transform = crylevel.ConvertCryWorldMatrixToEngineTransform(crylevel.BuildCryLocalMatrix({Rotate = "8.9406967e-008,0,0,1"}))
	local right, up = get_basis(transform)
	T((right - Vec3(-1, 0, 0)):GetLength())["~"](0, 0.001)
	T((up - Vec3(0, 1, 0)):GetLength())["~"](0, 0.001)
end)

T.Test("Cry negative scale is kept as a mirrored scale", function()
	local transform = crylevel.ConvertCryWorldMatrixToEngineTransform(crylevel.BuildCryLocalMatrix({Scale = "-2,1,1"}))
	local right, up = get_basis(transform)
	T(transform.scale.x)["~"](-2, 0.001)
	T((right - Vec3(1, 0, 0)):GetLength())["~"](0, 0.001)
	T((up - Vec3(0, 1, 0)):GetLength())["~"](0, 0.001)
end)

T.Test("Cry prefabs, archetypes, entity models, parents and hidden groups", function()
	local libraries = {
		prefabs = {
			["{P}"] = assert(
				xml.Decode([[
<Prefab Name="thing" Id="{P}">
	<Objects>
		<Object Type="Brush" Name="prefab_child" Pos="1,0,0" Prefab="objects/prefab_child.cgf" />
	</Objects>
</Prefab>
			]])
			).children[1],
		},
		archetypes = {["{A}"] = {object_Model = "objects/archetype.cgf"}},
	}
	local entries = crylevel.ExtractVisualObjects(
		assert(
			crylevel.ParseEditorObjectsData([[
<Level>
	<Objects>
		<Object Type="Brush" Id="{CHILD}" Parent="{ROOT}" Name="child" Pos="0,1,0" Prefab="objects/child.cgf" />
		<Object Type="Brush" Id="{ROOT}" Name="root" Pos="100,0,0" Rotate="0.70710678,0,0,0.70710678" Prefab="objects/root.cgf" />
		<Object Type="Prefab" Name="prefab" Pos="0,0,50" PrefabGUID="{P}" />
		<Object Type="EntityArchetype" Name="archetype" Prototype="{A}" Pos="0,0,0" />
		<Object Type="Entity" Name="entity" EntityClass="BasicEntity" Pos="0,0,0">
			<Properties object_Model="objects/entity.cgf" />
		</Object>
		<Object Type="Group" Name="hidden_group" Hidden="1" Pos="0,0,0">
			<Objects>
				<Object Type="Brush" Name="hidden_child" Prefab="objects/hidden.cgf" />
			</Objects>
		</Object>
	</Objects>
</Level>
			]])
		),
		libraries
	)
	local by_name = {}

	for _, entry in ipairs(entries) do
		by_name[entry.name] = entry
	end

	T(#entries)["=="](5)
	T(by_name.hidden_child)["=="](nil)
	T(by_name.archetype.model_path)["=="]("objects/archetype.cgf")
	T(by_name.entity.model_path)["=="]("objects/entity.cgf")
	local child = crylevel.ConvertCryWorldMatrixToEngineTransform(by_name.child.world_matrix)
	T((child.position - Vec3(99, 0, 0)):GetLength())["~"](0, 0.001)
	local prefab_child = crylevel.ConvertCryWorldMatrixToEngineTransform(by_name.prefab_child.world_matrix)
	T((prefab_child.position - Vec3(1, 50, 0)):GetLength())["~"](0, 0.001)
end)

T.Test("Cry level parser reads vegetation prototypes from editor xml", function()
	local vegetation = assert(
		crylevel.ParseVegetationMapData([[
<Level>
	<VegetationMap>
		<Objects>
			<Object Id="65" FileName="objects/natural/trees/hill_tree/hill_tree_small_bright_green.cgf" RandomRotation="0" AlignToTerrain="0" UseTerrainColor="1" Bending="1" Size="1" SizeVar="0.2" />
			<Object Id="56" FileName="objects/natural/ground_plants/grass/bigpatch_medium.cgf" RandomRotation="1" AlignToTerrain="0" UseTerrainColor="1" Bending="1" Size="0.8" SizeVar="1" />
		</Objects>
	</VegetationMap>
</Level>
		]])
	)
	T(#vegetation.list)["=="](2)
	T(vegetation.by_id[65].model_path)["=="]("objects/natural/trees/hill_tree/hill_tree_small_bright_green.cgf")
	T(vegetation.by_id[65].random_rotation)["=="](false)
	T(vegetation.by_id[65].use_terrain_color)["=="](true)
	T(vegetation.by_id[56].random_rotation)["=="](true)
end)

T.Test("Cry level parser reads painted vegetation instances", function()
	local vegetation = assert(
		crylevel.ParseVegetationMapData([[
<Level>
	<VegetationMap>
		<Objects>
			<Object Id="65" FileName="objects/natural/trees/hill_tree/hill_tree_small_bright_green.cgf" RandomRotation="0" AlignToTerrain="0" UseTerrainColor="1" Bending="1" />
			<Object Id="3" FileName="objects/natural/bushes/groundfernbush/ground_fern_bush_big_a.cgf" RandomRotation="1" AlignToTerrain="0" UseTerrainColor="0" Bending="1" />
			<Object Id="56" FileName="objects/natural/ground_plants/grass/bigpatch_medium.cgf" RandomRotation="1" AlignToTerrain="1" UseTerrainColor="1" Bending="1" />
		</Objects>
	</VegetationMap>
</Level>
		]])
	)
	local supported = pack_f32_le(1548.375) .. pack_f32_le(1903.96875) .. pack_f32_le(236.1796875) .. pack_f32_le(0.8685) .. string.char(65, 30, 0)
	local random_yaw = pack_f32_le(100) .. pack_f32_le(200) .. pack_f32_le(300) .. pack_f32_le(1.25) .. string.char(3, 30, 64)
	local unsupported = pack_f32_le(1456.9) .. pack_f32_le(2090.8) .. pack_f32_le(196.9) .. pack_f32_le(0.433) .. string.char(56, 30, 0)
	local terrain = {
		world_size = 1,
		heightmap_max_height = 1,
		height_data = pack_u16_le(0) .. pack_u16_le(0) .. pack_u16_le(0) .. pack_u16_le(0),
		height_data_offset = 1,
		height_samples_width = 2,
		height_samples_height = 2,
	}
	local entries = crylevel.ParseVegetationInstancesData(supported .. random_yaw .. unsupported, vegetation, terrain)
	T(#entries)["=="](3)
	T(entries[1].prototype_id)["=="](65)
	T(entries[1].model_path)["=="]("objects/natural/trees/hill_tree/hill_tree_small_bright_green.cgf")
	T(entries[1].position.x)["~"](1548.375, 0.001)
	T(entries[1].position.y)["~"](1903.96875, 0.001)
	T(entries[1].position.z)["~"](236.1796875, 0.001)
	T(entries[1].scale)["~"](0.8685, 0.0001)
	local transform = crylevel.ConvertCryVegetationInstanceToEngineTransform(entries[1])
	T(transform.position.x)["~"](1548.375, 0.001)
	T(transform.position.y)["~"](236.1796875, 0.001)
	T(transform.position.z)["~"](-1903.96875, 0.001)
	T(transform.scale.x)["~"](0.8685, 0.0001)
	T(transform.scale.y)["~"](0.8685, 0.0001)
	T(transform.scale.z)["~"](0.8685, 0.0001)
	T(entries[2].prototype_id)["=="](3)
	T(entries[2].model_path)["=="]("objects/natural/bushes/groundfernbush/ground_fern_bush_big_a.cgf")
	T(entries[2].yaw)["~"](64 / 255 * math.pi * 2, 0.001)
	T(entries[2].brightness)["=="](30)
	local random_transform = crylevel.ConvertCryVegetationInstanceToEngineTransform(entries[2])
	T(random_transform.position.x)["~"](100, 0.001)
	T(random_transform.position.y)["~"](300, 0.001)
	T(random_transform.position.z)["~"](-200, 0.001)
	local random_right = get_basis(random_transform)
	T((random_right - Vec3(0, 0, -1)):GetLength())["~"](0, 0.01)
	T(entries[3].prototype_id)["=="](56)
	T(entries[3].terrain_normal ~= nil)["=="](true)
	local aligned_transform = crylevel.ConvertCryVegetationInstanceToEngineTransform(entries[3])
	local aligned_up = aligned_transform.rotation:GetUp()
	T(aligned_up.x)["~"](0, 0.001)
	T(aligned_up.y)["~"](1, 0.001)
	T(aligned_up.z)["~"](0, 0.001)
	local fit = crylevel.ConvertCryVegetationInstanceToEngineTransform{
		position = Vec3(0, 0, 0),
		scale = 2,
		yaw = 0,
		fit_to_terrain = true,
		terrain_normal = Vec3(-1, 1, 0):GetNormalized(),
	}
	local fit_origin = fit.matrix:TransformVector(Vec3(0, 0, 0))
	T((fit.matrix:TransformVector(Vec3(1, 0, 0)) - fit_origin - Vec3(2, 2, 0)):GetLength())["~"](0, 0.001)
	T((fit.matrix:TransformVector(Vec3(0, 1, 0)) - fit_origin - Vec3(0, 2, 0)):GetLength())["~"](0, 0.001)
end)

T.Test("Cry cover parser reads the terrain texture quadtree", function()
	local function u16(v)
		return string.char(bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF))
	end

	local header = "CRY\0" .. "\100\0" .. u16(8) .. u16(1) .. u16(1) .. ffi.string(ffi.new("float[1]", 0.5), 4)
	local layer = u16(4) .. u16(0) .. pack_u32_le(0x18) .. pack_u32_le(16)
	local index = {
		0,
		0xffff,
		1,
		0xffff,
		0xffff,
		0xffff,
		0xffff,
		0xffff,
		2,
		0xffff,
		0xffff,
		0xffff,
		0xffff,
	}
	local parts = {header, layer, u16(#index)}

	for _, v in ipairs(index) do
		parts[#parts + 1] = u16(v)
	end

	for id = 0, 2 do
		parts[#parts + 1] = string.rep(string.char(id), 16)
	end

	local data = table.concat(parts)
	local cover = assert(crylevel.ParseCoverData(data))
	T(cover.sector_size)["=="](4)
	T(cover.max_level)["=="](1)
	T(#cover.nodes)["=="](3)
	T(cover.nodes[1].level)["=="](0)
	local by_offset = {}

	for _, node in ipairs(cover.nodes) do
		by_offset[data:byte(node.offset + 1)] = node
	end

	T(by_offset[1].x)["=="](0)
	T(by_offset[1].y)["=="](1)
	T(by_offset[2].x)["=="](1)
	T(by_offset[2].y)["=="](1)
	T(select(2, crylevel.ParseCoverData(data:sub(1, #data - 1))))["=="]("cover.ctc sector data is truncated")
end)
