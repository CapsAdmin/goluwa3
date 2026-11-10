local model_loader = import("goluwa/render3d/model_loader.lua")
local vphys = import("goluwa/source_engine/source2/vphys.lua")

model_loader.AddModelDecoder("vphys_c", function(path, full_path, mesh_callback, physics_callback)
	local children, body = vphys.Load(full_path)
	physics_callback{children = children, body = body}
end)
