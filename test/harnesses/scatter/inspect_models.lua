-- prints size and vertex count of Crysis cgf models: MODELS=Trees/Hill_Tree/hill_tree_small_bright_green,... luajit glw --3d --background --one-frame lua "./test/harnesses/scatter/inspect_models.lua"
local steam = import("goluwa/steam/steam.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local info = list.find(steam.GetGames(), function(game) return game.appid == 17300 end)
local root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local names = {}
for line in (os.getenv("MODELS") or ""):gmatch("[^,]+") do names[#names + 1] = line end
local pending = #names
for _, name in ipairs(names) do
	model_loader.LoadModel(root .. name .. ".cgf", function(entries)
		local out = {}
		for _, e in ipairs(entries) do
			local p = e.mesh
			local a = p:GetAABB()
			if p:GetLODLevel() == 0 then out[#out + 1] = string.format("w%.1f h%.1f..%.1f v%d", math.max(a.max_x-a.min_x, a.max_z-a.min_z), a.min_y, a.max_y, p.mesh.vertex_buffer and p.mesh.vertex_buffer:GetVertexCount() or -1) end
		end
		print(name:match("[^/]+$"), table.concat(out, " | "))
		pending = pending - 1
		if pending == 0 then os.exit(0) end
	end, nil, function(err) print(name, "FAILED", err) pending = pending - 1 if pending == 0 then os.exit(0) end end)
end
