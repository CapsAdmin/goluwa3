-- every preset of the foliage laid out on the ground in rows, a block for each category: grass at the front (at the
-- origin), then the plants, the rocks and the trees towards -z. each is an entity with a visual of its model path
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local foliage = import("lua/foliage/foliage.lua")
local gallery = {}
gallery.BLOCKS = {
	{category = "grass", spacing = 1.6, columns = 10},
	{category = "plants", spacing = 3, columns = 11},
	{category = "rocks", spacing = 4.5, columns = 12},
	{category = "trees", spacing = 15, columns = 8},
}
-- meters between two blocks, from the last row of one to the first of the next
gallery.GAP = 5

-- returns the root entity and the placements, {path = model path, position = Vec3}
function gallery.Spawn(parent, origin)
	local root = Entity.New{Name = "foliage_gallery", Parent = parent}
	root:AddComponent("transform")
	local placements = {}
	local z = origin.z

	for _, block in ipairs(gallery.BLOCKS) do
		local paths = foliage.GetModelPaths(block.category)
		local columns = math.min(block.columns, #paths)
		local rows = math.ceil(#paths / columns)

		for i, path in ipairs(paths) do
			local column = (i - 1) % columns
			local row = math.floor((i - 1) / columns)
			local position = Vec3(origin.x + (column - (columns - 1) / 2) * block.spacing, origin.y, z - row * block.spacing)
			local ent = Entity.New{Name = path, Parent = root}
			ent:AddComponent("transform"):SetPosition(position)
			ent:AddComponent("visual"):SetModelPath(path)
			placements[#placements + 1] = {path = path, position = position}
		end

		z = z - (rows - 1) * block.spacing - gallery.GAP - block.spacing * 0.5
	end

	return root, placements
end

return gallery
