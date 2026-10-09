local model_loader = import("goluwa/render3d/model_loader.lua")
local bsp = import("goluwa/source_engine/bsp.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
import("goluwa/source_engine/source_engine.lua")

model_loader.AddModelDecoder("bsp", function(path, full_path, mesh_callback)
	local ok, result = pcall(bsp.Load, full_path)

	if not ok then error("Failed to load BSP map: " .. tostring(result)) end

	for _, batch in ipairs(static_geometry.Finalize(static_geometry.Build(result.world, path)).batches) do
		mesh_callback(batch.mesh, batch.material)
	end
end)
