-- decodes the cgf models of a Crysis level one after another on the main thread under the profiler
local vfs = import("goluwa/vfs.lua")
local system = import("goluwa/system.lua")
-- GOLUWA_PVARS="r_codec_threads=0" luajit glw --3d --background lua test/harnesses/cgf/decode_bench.lua    (r_codec_threads=0 decodes inline, LEVEL=Multiplayer/PS/Beach LIMIT=2000)
local game = import("goluwa/cry_engine/game.lua")
local level = import("goluwa/cry_engine/level.lua")
local cgf = import("goluwa/render3d/model_decoders/cgf.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local level_dir = assert(game.ResolveLevelDirectory(os.getenv("LEVEL") or "Multiplayer/PS/Beach"))
local data = level.Load(level_dir)
local seen, paths = {}, {}

local function add(path)
	if path and not seen[path] then
		seen[path] = true
		paths[#paths + 1] = path
	end
end

for _, entry in ipairs(data.entries) do add(entry.model_path) end
for _, prototype in pairs(data.vegetation_prototypes or {}) do add(prototype.model_path) end

table.sort(paths)
local limit = tonumber(os.getenv("LIMIT") or 2000)
local jobs = {}

for i = 1, math.min(limit, #paths) do
	local full = vfs.FindMixedCasePath(paths[i]) or paths[i]

	if vfs.IsFile(full) then jobs[#jobs + 1] = {paths[i], full} end
end

local function noop() end
local totals = {gather = 0, pack = 0, finish = 0}
local per_model = {}
local bytes = 0
PROF.Start("cgf_decode", {trace_recorder = false, shutdown = false})
local start = system.GetTime()

for _, job in ipairs(jobs) do
	local path, full = job[1], job[2]
	local t0 = system.GetTime()
	local input = cgf.Decoder.Gather(path, full)
	local t1 = system.GetTime()
	local meta, blob = thread_pool.Run(cgf.Decoder.job, input, #input.data):Block()
	local t2 = system.GetTime()
	cgf.Decoder.Finish(path, full, input, meta, blob, noop, noop, noop)
	local t3 = system.GetTime()
	totals.gather = totals.gather + t1 - t0
	totals.pack = totals.pack + t2 - t1
	totals.finish = totals.finish + t3 - t2
	bytes = bytes + #input.data
	if t3 - t0 > 1 then print(string.format("[CGF] slow %.1fs (pack %.1f finish %.1f) %s", t3 - t0, t2 - t1, t3 - t2, path)) end
	per_model[#per_model + 1] = {path, t3 - t0, t1 - t0, t2 - t1, t3 - t2, #input.data}
end

local total = system.GetTime() - start
PROF.Stop()
print(string.format("[CGF] %d models, %.1f MB, total %.2fs (%.1f ms/model)", #jobs, bytes / 1e6, total, total / #jobs * 1000))
print(string.format("[CGF] gather %.2fs  pack %.2fs  finish %.2fs", totals.gather, totals.pack, totals.finish))
table.sort(per_model, function(a, b) return a[2] > b[2] end)

for i = 1, 15 do
	local m = per_model[i]
	if m then print(string.format("[CGF] %.0f ms (gather %.0f pack %.0f finish %.0f) %.0f KB %s", m[2] * 1000, m[3] * 1000, m[4] * 1000, m[5] * 1000, m[6] / 1024, m[1])) end
end

PROF.Summary("storage/logs/jit_profile_cgf_decode.glwp", {top_n = 30})
os.exit(0)
