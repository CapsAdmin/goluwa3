local m3 = import("test/harnesses/m3/harness.lua")
local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local system = import("goluwa/system.lua")
local n = 0
m3.Run(function(view, now)
	n = n + 1
	if n == 120 then
		local pipeline = render3d.pipelines.gbuffer_multi_draw
		local record = ffi.new(model_pipeline.GetPBRBatchRecordType())
		local mats = {}
		for _, batch in ipairs(gpu_culling.GetSceneDataset().main_instanced_batches) do
			if batch.material then mats[#mats + 1] = batch.material if #mats >= 80 then break end end
		end
		local function run(count)
			local t = system.GetTime()
			for i = 1, count do
				for j = 1, #mats do
					render3d.SetMaterial(mats[j])
					model_pipeline.WritePBRBatchRecord(pipeline, record)
				end
			end
			return (system.GetTime() - t) / (count * #mats) * 1e6
		end
		run(50)
		print(string.format("RECORD warm %.2f us/record", run(200)))
		print(string.format("RECORD again %.2f us/record", run(200)))
		render3d.SetMaterial(nil)
		PROF.Start("rec", {shutdown = false, trace_recorder = false})
		run(500)
		PROF.Stop()
		PROF.Summary("storage/logs/jit_profile_rec.glwp", {top_n = 25})
		return false
	end
end)
