local T = import("test/environment.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local crylevel = import("goluwa/cry_engine/level.lua")
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

local empty_libraries = {prefabs = {}, archetypes = {}, archetype_nodes = {}}

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
		archetype_nodes = {
			["{A}"] = assert(
				xml.Decode([[
<EntityPrototype Id="{A}" Class="RigidBodyEx">
	<Properties object_Model="objects/archetype.cgf">
		<Physics bPhysicalize="1" bRigidBody="1" Mass="5" />
	</Properties>
</EntityPrototype>
			]])
			).children[1],
		},
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
	T(by_name.archetype.physics.motion)["=="]("dynamic")
	T(by_name.archetype.physics.mass)["=="](5)
	T(by_name.entity.model_path)["=="]("objects/entity.cgf")
	local child = crylevel.ConvertCryWorldMatrixToEngineTransform(by_name.child.world_matrix)
	T((child.position - Vec3(99, 0, 0)):GetLength())["~"](0, 0.001)
	local prefab_child = crylevel.ConvertCryWorldMatrixToEngineTransform(by_name.prefab_child.world_matrix)
	T((prefab_child.position - Vec3(1, 50, 0)):GetLength())["~"](0, 0.001)
	T(by_name.child.group.name)["=="]("root")
	T(by_name.child.group.parent)["=="](nil)
	T(by_name.prefab_child.group.name)["=="]("prefab")
	T(by_name.root.group)["=="](nil)
end)

T.Test("Cry level entries remember their layer and group chain", function()
	local entries = crylevel.ExtractVisualObjects(
		assert(
			crylevel.ParseEditorObjectsData([[
<Level>
	<Objects>
		<Object Type="Group" Id="{G1}" Layer="Main" Name="outer" Pos="0,0,0">
			<Objects>
				<Object Type="Group" Id="{G2}" Name="inner" Pos="0,0,0">
					<Objects>
						<Object Type="Brush" Id="{B}" Name="leaf" Prefab="objects/leaf.cgf" />
					</Objects>
				</Object>
			</Objects>
		</Object>
	</Objects>
</Level>
			]])
		),
		{prefabs = {}, archetypes = {}, archetype_nodes = {}}
	)
	T(#entries)["=="](1)
	T(entries[1].layer)["=="]("Main")
	T(entries[1].group.name)["=="]("inner")
	T(entries[1].group.parent.name)["=="]("outer")
	T(entries[1].group.parent.parent)["=="](nil)
	T(entries[1].group.key ~= entries[1].group.parent.key)["=="](true)
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
	T(entries[2].prototype_id)["=="](3)
	T(entries[2].model_path)["=="]("objects/natural/bushes/groundfernbush/ground_fern_bush_big_a.cgf")
	T(entries[2].yaw)["~"](64 / 255 * math.pi * 2, 0.001)
	T(entries[3].prototype_id)["=="](56)
	T(entries[3].terrain_normal ~= nil)["=="](true)
end)

T.Test("Cry terrain height drops to zero outside the heightmap", function()
	local raw = pack_u16_le(65535)
	local terrain = {
		world_size = 10,
		heightmap_max_height = 100,
		height_data = raw .. raw .. raw .. raw,
		height_data_offset = 1,
		height_sample_width = 2,
		height_sample_height = 2,
		height_world_to_sample_x = 0.1,
		height_world_to_sample_y = 0.1,
	}
	T(crylevel.SampleTerrainHeight(terrain, 5, -5))["~"](100, 0.001)
	T(crylevel.SampleTerrainHeight(terrain, 0, 0))["~"](100, 0.001)
	T(crylevel.SampleTerrainHeight(terrain, 10, -10))["~"](100, 0.001)
	T(crylevel.SampleTerrainHeight(terrain, -0.01, -5))["=="](0)
	T(crylevel.SampleTerrainHeight(terrain, 10.01, -5))["=="](0)
	T(crylevel.SampleTerrainHeight(terrain, 5, 0.01))["=="](0)
	T(crylevel.SampleTerrainHeight(terrain, 5, -10.01))["=="](0)
	T(crylevel.SampleTerrainHeight(terrain, 1000, 1000))["=="](0)
	T(crylevel.SampleRenderedTerrainHeight(terrain, 5, -5))["~"](100, 0.001)
	T(crylevel.SampleRenderedTerrainHeight(terrain, 0, 0))["~"](100, 0.001)
	T(crylevel.SampleRenderedTerrainHeight(terrain, -0.01, -5))["=="](0)
	T(crylevel.SampleRenderedTerrainHeight(terrain, 10.01, -5))["=="](0)
	T(crylevel.SampleRenderedTerrainHeight(terrain, 5, 0.01))["=="](0)
	T(crylevel.SampleRenderedTerrainHeight(terrain, 5, -10.01))["=="](0)
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

T.Test("Cry level parser extracts lights and skips inactive ones", function()
	local _, extra = crylevel.ExtractVisualObjects(
		assert(
			crylevel.ParseLayerData([[
<ObjectLayer>
	<Layer Name="lights" Hidden="0">
		<LayerObjects>
			<Object Type="Entity" Name="lamp" Pos="1,2,3" EntityClass="Light">
				<Properties bActive="1" Radius="6">
					<Color clrDiffuse="1,0.5,0.25" fDiffuseMultiplier="10"/>
					<Options bCastShadow="1"/>
					<Projector bProjectInAllDirs="0" fProjectorFov="60" texture_Texture="a.dds"/>
				</Properties>
			</Object>
			<Object Type="Entity" Name="fill" Pos="0,0,0" EntityClass="SimpleIndirectLight">
				<Properties bActive="1" Radius="5">
					<Color clrColor="1,1,1" fColorMultiplier="2"/>
					<Options bCastShadow="1"/>
					<Projector bProjectInAllDirs="0" fProjectorFov="90" texture_Texture=""/>
				</Properties>
			</Object>
			<Object Type="Entity" Name="off" Pos="0,0,0" EntityClass="SimpleLight">
				<Properties bActive="0" Radius="5">
					<Color clrColor="1,1,1" fColorMultiplier="2"/>
					<Options bCastShadow="0"/>
					<Projector bProjectInAllDirs="0" fProjectorFov="90" texture_Texture=""/>
				</Properties>
			</Object>
		</LayerObjects>
	</Layer>
</ObjectLayer>
]]),
			"layer parse failed"
		),
		empty_libraries
	)
	T(#extra.lights)["=="](2)
	T(extra.lights[1].radius)["=="](6)
	T(extra.lights[1].multiplier)["=="](10)
	T(extra.lights[1].spot_fov)["=="](60)
	T(extra.lights[1].cast_shadow)["=="](true)
	T(extra.lights[1].color.y)["=="](0.5)
	T(extra.lights[2].indirect)["=="](true)
	T(extra.lights[2].cast_shadow)["=="](false)
	T(extra.lights[2].spot_fov)["=="](nil)
end)

T.Test("Cry brush list parser reads materials, models and transforms", function()
	local brush_list = import("goluwa/cry_engine/brush_list.lua")

	local function padded(text, size)
		return text .. string.rep("\0", size - #text)
	end

	local geom = pack_u32_le(160) .. padded("objects/a/box.cgf", 128) .. pack_u32_le(1)
	local bounds = {-1, -2, -3, 1, 2, 3}

	for _, value in ipairs(bounds) do
		geom = geom .. pack_f32_le(value)
	end

	local matrix = {0, 2, 0, 10, -1, 0, 0, 20, 0, 0, 1, 30}
	local brush = pack_u32_le(0) .. pack_u32_le(7) .. pack_u32_le(0) .. pack_u32_le(0) .. pack_u32_le(8) .. pack_u32_le(0)

	for _, value in ipairs(matrix) do
		brush = brush .. pack_f32_le(value)
	end

	brush = brush .. string.char(100, 40, 0, 0)
	local data = "CRY" .. pack_u32_le(1) .. pack_u32_le(3) .. pack_u32_le(1) .. pack_u32_le(68) .. padded("materials/test", 64) .. pack_u32_le(1) .. geom .. pack_u32_le(1) .. brush
	local parsed = assert(brush_list.Parse(data))
	T(#parsed.brushes)["=="](1)
	T(parsed.geoms[1].name)["=="]("objects/a/box.cgf")
	T(parsed.geoms[1].max[3])["=="](3)
	T(parsed.brushes[1].material.name)["=="]("materials/test")
	T(parsed.brushes[1].view_distance_ratio)["=="](100)
	T(parsed.brushes[1].lod_ratio)["=="](40)
	local origin = parsed.brushes[1].world_matrix:TransformVector(Vec3(0, 0, 0))
	T(origin.x)["=="](10)
	T(origin.y)["=="](20)
	T(origin.z)["=="](30)
	local x_axis = parsed.brushes[1].world_matrix:TransformVector(Vec3(1, 0, 0)) - origin
	T(x_axis.y)["=="](-1)
	T(x_axis.x)["=="](0)
end)

T.Test("Cry compiled terrain rebuilds an editor layout height array from sector nodes", function()
	local compiled_terrain = import("goluwa/cry_engine/compiled_terrain.lua")

	local function pack_i16_le(value)
		return string.char(value % 256, math.floor(value / 256) % 256)
	end

	local header = string.char(22, 0, 0, 0) .. pack_u32_le(0) .. pack_u32_le(32) .. pack_u32_le(2) .. pack_u32_le(64) .. pack_u32_le(1) .. pack_f32_le(0.015625) .. pack_f32_le(0)
	local heights = ""

	for x = 0, 2 do
		for y = 0, 2 do
			heights = heights .. pack_i16_le(1600 * x + 160 * y + (x + y) % 3)
		end
	end

	local node = pack_i16_le(5) .. pack_i16_le(0)

	for _, value in ipairs{0, 0, 0, 64, 64, 100} do
		node = node .. pack_f32_le(value)
	end

	node = node .. "\0" .. pack_f32_le(10) .. pack_f32_le(0.5) .. pack_u32_le(3) .. pack_u32_le(1) .. heights .. "\0" .. string.rep("\0", 20)
	local data = header .. pack_u32_le(0) .. pack_u32_le(0) .. pack_u32_le(0) .. node
	local result = compiled_terrain.Parse(data, 1024)
	local samples = ffi.cast("const uint16_t *", result.height_data)
	local to_raw = 65535 / 1024
	T(result.size)["=="](32)
	T(samples[0])["=="](math.floor(14 * to_raw + 0.5))
	T(samples[16 * 32])["=="](math.floor(814 * to_raw + 0.5))
	T(samples[8])["=="](math.floor(54 * to_raw + 0.5))
	T(result.surface_indices[0])["=="](1)
	T(result.surface_indices[16 * 32])["=="](2)
	T(result.surface_indices[8])["=="](2)
end)

T.Test("Cry compiled vegetation reads the group table and instances inside their boxes", function()
	local compiled_vegetation = import("goluwa/cry_engine/compiled_vegetation.lua")
	local group_size = 332
	local name = "objects/natural/trees/palm_tree/palm.cgf"
	local params = {}

	for i = 0, 17 do
		params[i] = pack_u32_le(0)
	end

	params[1] = pack_f32_le(0.25)
	params[5] = pack_f32_le(2)
	params[16] = pack_u32_le(3)
	local group = pack_u32_le(0) .. name .. string.rep("\0", 256 - #name) .. table.concat(params, "", 0, 17)
	local groups = group .. string.rep("\0", group_size * 1023)

	local function instance(x, y, z, flags)
		local record = "\0"

		for _, value in ipairs{x - 1, y - 1, z - 1, x + 1, y + 1, z + 1} do
			record = record .. pack_f32_le(value)
		end

		record = record .. pack_u32_le(0) .. pack_f32_le(500) .. pack_u32_le(flags) .. string.char(100, 100, 0)

		for _, value in ipairs{x, y, z, 1.5} do
			record = record .. pack_f32_le(value)
		end

		return record .. string.char(0, 7, 128, 0, 0, 0)
	end

	local data = string.rep("\0", 36) .. groups .. string.rep("\0", 5) .. instance(100, 200, 30, 0x80c) .. instance(300, 400, 50, 0x2428) .. instance(500, 600, 70, 0x808)
	local prototypes, instances = compiled_vegetation.Parse(data, 36 + #groups)
	T(#prototypes.list)["=="](1)
	T(prototypes.by_id[0].category)["=="]("Trees")
	T(prototypes.by_id[0].bending)["=="](0.25)
	T(prototypes.by_id[0].size)["=="](2)
	T(prototypes.by_id[0].align_to_terrain)["=="](true)
	T(prototypes.by_id[0].use_terrain_color)["=="](true)
	T(#instances)["=="](2)
	T(instances[1].x)["=="](100)
	T(instances[1].scale)["=="](1.5)
	T(instances[1].angle)["=="](128)
	T(instances[2].z)["=="](70)
end)

T.Test("Cry mission environment reads sun, fog and wind from the mission node", function()
	local document = assert(
		xml.Decode([[
<Mission Name="Mission0">
	<Environment>
		<EnvState WindVector="-6,-2, 0"/>
		<Lighting SunRotation="0" Longitude="90"/>
	</Environment>
	<TimeOfDay Time="12">
		<Variable Name="Volumetric fog: Global density" Value="2"/>
		<Variable Name="Volumetric fog: Atmosphere height" Value="1300"/>
		<Variable Name="Volumetric fog: Density offset (in reality 0)" Value="0.5"/>
	</TimeOfDay>
</Mission>
]])
	)
	local environment = crylevel.ParseMissionEnvironment(document.children[1])
	T(environment.sun_direction.y)[">"](0.999)
	T(environment.fog_density)["=="](2)
	T(environment.fog_atmosphere_height)["=="](1300)
	T(environment.fog_density_offset)["=="](0.5)
	T(environment.wind.x)["=="](-6)
	T(environment.wind.y)["=="](0)
	T(environment.wind.z)["=="](2)
end)
