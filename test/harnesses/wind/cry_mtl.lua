local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local info = list.find(steam.GetGames(), function(game) return game.appid == 17300 end)
local root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
for _, p in ipairs{"Trees/Palm_Tree/palm_tree_large.mtl", "Trees/Jungle_Tree_Large/jungle_tree_large_big_bright_green.mtl", "Trees/Twisted_Tree/twisted_tree.mtl", "Bushes/palm_bush/palmbush.mtl"} do
	local data = vfs.Read(root .. p)
	print("==", p)
	for line in data:gmatch("[^\n]+") do
		if line:find("Material ") or line:find("bend") or line:find("Bend") or line:find("GenMask") or line:find("StringGenMask") then print("   " .. line:gsub("^%s+", ""):sub(1, 220)) end
	end
end
os.exit(0)
