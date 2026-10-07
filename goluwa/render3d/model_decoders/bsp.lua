local model_loader = import("goluwa/render3d/model_loader.lua")
local bsp = import("goluwa/source_engine/bsp.lua")
import("goluwa/source_engine/source_engine.lua")

model_loader.AddModelDecoder("bsp", function(path, full_path, mesh_callback)
	local ok, result = pcall(bsp.Load, full_path)

	if not ok then error("Failed to load BSP map: " .. tostring(result)) end

	if not result or not result.render_meshes then
		error("BSP LoadMap returned invalid data")
	end

	bsp.resolved[path] = result

	for _, prim in ipairs(result.render_meshes) do
		mesh_callback(prim.mesh, prim.material)
	end
end)
