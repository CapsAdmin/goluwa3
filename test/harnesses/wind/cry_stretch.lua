-- luajit glw --cli lua test/harnesses/wind/cry_stretch.lua, needs crysis 1. the detail bending of crysis' leaves on the cpu, the engine's old (flutter along the wind, triangle waves, speed as
-- frequency) and new (along the normal, smoothed, speed as amplitude), and how much the edges of the leaf cards stretch
local steam = import("goluwa/steam/steam.lua")
local cgf = import("goluwa/render3d/model_decoders/cgf.lua")
local info = list.find(steam.GetGames(), function(game) return game.appid == 17300 end)
local root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local floor, abs, sqrt, min, max = math.floor, math.abs, math.sqrt, math.min, math.max
local function fract(x) return x - floor(x) end
local function tri(x) return abs(fract(x + 0.5) * 2 - 1) end
local function stri(x) local t = tri(x) return t * t * (3 - 2 * t) end
local DIR_X, DIR_Z = 1, 0

local function old(v, m, w, t)
	local p, c = v.pos, v.vertex_color
	local S = w * m.F
	local bp = c.g
	local vp = (p.x + p.y + p.z) * (m.P + bp)
	local w1 = tri((fract((t + vp) * 1.975) * 2 - 1) * S)
	local w2 = tri((fract((t + vp) * 0.793) * 2 - 1) * S)
	local w3 = tri((fract((t + bp) * 0.375) * 2 - 1) * S)
	local w4 = tri((fract((t + bp) * 0.193) * 2 - 1) * S)
	local e = (w1 + w2) * c.r * m.L
	return p.x + e * DIR_X, p.y + (w3 + w4) * (1 - c.b) * m.B, p.z + e * DIR_Z
end

local function new(v, m, w, t)
	local p, c, n = v.pos, v.vertex_color, v.normal
	local s = 0.3 * w * 6 / (6 + w) * m.F
	local a = s < 0.5 and s * 2 or sqrt(s * 2)
	local dt = t * sqrt(max(w * 4, 4) / 4)
	local bp = c.g
	local vp = (p.x + p.y + p.z) * (m.P + bp)
	local ew = (stri((dt + vp) * 1.975) - 0.5 + stri((dt + vp) * 0.793) - 0.5) * a
	local bw = (stri((dt + bp) * 0.375) - 0.5 + stri((dt + bp) * 0.193) - 0.5) * a
	local leaf = (ew + (n.x * DIR_X + n.z * DIR_Z) * (a + bw) * 0.5) * c.r * m.L
	local push = (a + bw) * 0.5 * (1 - c.b) * m.B
	return p.x + n.x * leaf + DIR_X * push, p.y + bw * (1 - c.b) * m.B, p.z + n.z * leaf + DIR_Z * push
end

local MODELS = {
	{"Trees/Palm_Tree/Palm_Tree_large_a.cgf", {[1] = {F = 0.5, L = 0.2, B = 0.2, P = 100}}},
	{"Trees/Jungle_Tree_Large/Jungle_Tree_Large_small_bright_green.cgf", {[1] = {F = 0.3, L = 0.5, B = 0.2, P = 100}, [4] = {F = 5, L = 0.08, B = 0.2, P = 100}}},
	{"Bushes/palm_bush/palmbush_med_a.cgf", {[0] = {F = 0.3, L = 0.2, B = 0.2, P = 100}}},
}

for _, speed in ipairs{4, 15} do
	local w = speed * 0.25
	for _, model in ipairs(MODELS) do
		local parsed = cgf.Open(root .. model[1])
		local entries = cgf.ExtractStaticMeshData(parsed)
		parsed.file:Close()
		for _, e in ipairs(entries) do
			local m = model[2][e.subset_material_id]
			if e.lod_level == 0 and m then
				local out = {}
				for _, f in ipairs{{"old", old}, {"new", new}} do
					local worst, sum, total, reach = 0, 0, 0, 0
					for k = 1, 24 do
						local t = k * 1.37
						local moved = {}
						for i, v in ipairs(e.vertices) do moved[i] = {f[2](v, m, w, t)} end
						for i = 1, #e.indices, 3 do
							for j = 0, 2 do
								local a, b = e.indices[i + j], e.indices[i + (j + 1) % 3]
								local pa, pb = e.vertices[a].pos, e.vertices[b].pos
								local rest = (pa - pb):GetLength()
								if rest > 0.02 then
									local ma, mb = moved[a], moved[b]
									local d = sqrt((ma[1] - mb[1]) ^ 2 + (ma[2] - mb[2]) ^ 2 + (ma[3] - mb[3]) ^ 2)
									local s = abs(d - rest) / rest
									worst, sum, total = max(worst, s), sum + s * rest, total + rest
								end
							end
						end
						for i, v in ipairs(e.vertices) do
							local d = sqrt((moved[i][1] - v.pos.x) ^ 2 + (moved[i][2] - v.pos.y) ^ 2 + (moved[i][3] - v.pos.z) ^ 2)
							reach = max(reach, d)
						end
					end
					out[#out + 1] = ("%s: stretch max %5.1f%% mean %5.2f%%, moves up to %4.2f m"):format(f[1], worst * 100, sum / total * 100, reach)
				end
				print(("%4.1f m/s  %-28s sub %d   %s   |   %s"):format(speed, model[1]:match("([^/]+)%.cgf$"), e.subset_material_id, out[1], out[2]))
			end
		end
	end
end
os.exit(0)
