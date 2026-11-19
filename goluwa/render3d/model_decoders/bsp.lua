local model_loader = import("goluwa/render3d/model_loader.lua")
local bsp = import("addons/source_loader/lua/source_loader/bsp.lua")
local static_geometry = import("addons/source_loader/lua/source_loader/static_geometry.lua")
import("addons/source_loader/lua/source_loader/source_loader.lua")

model_loader.AddModelDecoder("bsp", function(path, full_path, mesh_callback)
	local ok, result = pcall(bsp.Load, full_path, true)

	if not ok then error("Failed to load BSP map: " .. tostring(result)) end

	local brushes, displacements, meshes = static_geometry.ExpandWorld(result.world)

	for _, batch in ipairs(
		static_geometry.Finalize(static_geometry.Build(brushes, displacements, meshes, path)).batches
	) do
		mesh_callback(batch.mesh, batch.material)
	end
end)
