local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")

T.Test3D("visual retries a model that failed once the content that has it is mounted", function()
	local dir = "tmp/visual_retry_content/"
	fs.create_directory_recursive(dir .. "models/")
	fs.write_file(
		dir .. "models/visual_retry_box.lua",
		[[
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
return {
	name = "visual_retry_box",
	kind = "procedural_model",
	create_primitives = function()
		local poly = Polygon3D.New()
		shapes.BuildCube(poly, 0.5, 1.0)
		poly:BuildBoundingBox()
		poly:Upload()
		return {{mesh = poly}}
	end,
}
]]
	)

	local function has_error_cube(ent)
		for _, child in ipairs(ent:GetChildren()) do
			if child.Name:ends_with("_error") then return true end
		end

		return false
	end

	local ent = Entity.New{Name = "visual_retry"}
	ent:AddComponent("transform")
	ent:AddComponent("visual"):SetModelPath("models/visual_retry_box.lua")

	T.WaitUntil(function()
		return not ent.visual:IsLoading()
	end, 5)

	T(has_error_cube(ent))["=="](true)
	T(vfs.Mount(dir) ~= false)["=="](true)

	T.WaitUntil(
		function()
			return not ent.visual:IsLoading() and not has_error_cube(ent)
		end,
		5
	)

	T(#ent.visual:GetRenderEntries())[">"](0)
	ent:Remove()
	vfs.Unmount(dir)
end)

T.Test3D("a visual keeps the load of a model requested while its entity is built", function()
	local ent = Entity.New{transform = {}, visual = {ModelPath = "models/box.lua"}}
	T(ent.visual.LoadGeneration)["=="](1)
	ent:Remove()
end)
