local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local model_file = import("goluwa/render3d/model_file.lua")

model_loader.AddModelDecoder("mesh", function(
	path,
	full_path,
	mesh_callback,
	physics_callback,
	skeleton_callback,
	bounds_callback
)
	import("goluwa/render3d/material_file.lua")
	local header, reader = model_file.Read(assert(vfs.Read(full_path) or fs.read_file(full_path)))
	local directory = file_path.GetFolderFromPath(full_path) or ""
	local skins = {}

	if header.skeleton then skeleton_callback(reader.Skeleton(header.skeleton)) end

	if header.physics then physics_callback(reader.Physics(header.physics)) end

	for _, info in ipairs(header.meshes) do
		local vertices, indices = reader.Mesh(info)
		local polygon = Polygon3D.New()
		local aabb = info.aabb
		polygon:UploadVertexArray(
			vertices,
			info.vertex_count,
			indices,
			info.index_count,
			true,
			nil,
			AABB(aabb[1], aabb[2], aabb[3], aabb[4], aabb[5], aabb[6])
		)
		polygon:SetBendHeight(info.bend_height)
		polygon:SetRootChain(info.root_chain)
		polygon:SetMaterialSlot(info.material_slot)
		polygon:SetLODLevel(info.lod_level)
		polygon:SetLODDistance(info.lod_distance)
		polygon:SetLODBillboard(info.lod_billboard)
		polygon:SetName(path)

		if info.skin then
			skins[info.skin] = skins[info.skin] or reader.Skin(header.skins[info.skin])
			polygon.Skin = skins[info.skin]
		end

		local material

		if info.material then
			material = select(2, Material.GetOverrideFromPath(file_path.Normalize(directory .. info.material)))
		end

		mesh_callback(polygon, material)
	end

	if header.bounds then bounds_callback(header.bounds[1], header.bounds[2]) end
end)
