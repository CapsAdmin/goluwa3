-- luajit glw --cli lua test/harnesses/wind/cry_colors.lua, needs crysis 1. vertex color statistics of the parts of crysis vegetation, to see what the channels hold
local steam = import("goluwa/steam/steam.lua")
local cgf = import("goluwa/render3d/model_decoders/cgf.lua")
local info = list.find(steam.GetGames(), function(game) return game.appid == 17300 end)
local root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local sqrt = math.sqrt

local function corr(xs, ys)
	local n = #xs
	local mx, my = 0, 0
	for i = 1, n do mx, my = mx + xs[i], my + ys[i] end
	mx, my = mx / n, my / n
	local sxy, sxx, syy = 0, 0, 0
	for i = 1, n do
		local dx, dy = xs[i] - mx, ys[i] - my
		sxy, sxx, syy = sxy + dx * dy, sxx + dx * dx, syy + dy * dy
	end
	if sxx == 0 or syy == 0 then return 0 end
	return sxy / sqrt(sxx * syy)
end

for _, model in ipairs{
	os.getenv("MODEL") or "Trees/Palm_Tree/Palm_Tree_large_a.cgf",
	"Trees/Jungle_Tree_Large/Jungle_Tree_Large_small_bright_green.cgf",
	"Trees/Twisted_Tree/twisted_tree_a.cgf",
	"Bushes/palm_bush/palmbush_med_a.cgf",
} do
	local parsed = cgf.Open(root .. model)
	local entries = cgf.ExtractStaticMeshData(parsed)
	parsed.file:Close()
	print("==", model)
	local top = 0
	for _, e in ipairs(entries) do
		if e.lod_level == 0 then for _, v in ipairs(e.vertices) do top = math.max(top, v.pos.y) end end
	end
	print(("   height %.2f"):format(top))
	for _, e in ipairs(entries) do
		if e.lod_level == 0 then
			local ch = {r = {}, g = {}, b = {}, a = {}}
			local ys, rs = {}, {}
			for i, v in ipairs(e.vertices) do
				local c = v.vertex_color or {r = -1, g = -1, b = -1, a = -1}
				for k in pairs(ch) do ch[k][i] = c[k] end
				ys[i] = v.pos.y
				rs[i] = sqrt(v.pos.x ^ 2 + v.pos.z ^ 2)
			end
			print(("   %s/%s sub %s  %d verts  y %.1f..%.1f"):format(tostring(e.material_name), e.name, tostring(e.subset_material_id), #e.vertices, math.min(unpack(ys)), math.max(unpack(ys))))
			for _, k in ipairs{"r", "g", "b", "a"} do
				local t = ch[k]
				local mn, mx, sum = 1e9, -1e9, 0
				for i = 1, #t do mn, mx, sum = math.min(mn, t[i]), math.max(mx, t[i]), sum + t[i] end
				print(("     %s  min %.2f  max %.2f  mean %.2f   corr height %+.2f  corr reach %+.2f"):format(k, mn, mx, sum / #t, corr(t, ys), corr(t, rs)))
			end
		end
	end
end
os.exit(0)
