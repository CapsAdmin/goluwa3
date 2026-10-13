-- wall time per call and per frame of selected functions
local m3 = import("test/harnesses/m3/harness.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local visual = import("goluwa/entities/components/visual.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local event = import("goluwa/event.lua")
local totals, calls = {}, {}
local measuring = false
local function wrap(tbl, name, label)
	local v = tbl[name]
	if type(v) ~= "function" then print("no function", label) return end
	tbl[name] = function(...)
		if not measuring then return v(...) end
		local t = system.GetTime()
		return (function(...)
			totals[label] = (totals[label] or 0) + system.GetTime() - t
			calls[label] = (calls[label] or 0) + 1
			return ...
		end)(v(...))
	end
end
wrap(gpu_culling, "RunMainViewFrustumCulling", "gpu_culling.RunMainViewFrustumCulling")
wrap(gpu_culling, "RunShadowViewAABBCulling", "gpu_culling.RunShadowViewAABBCulling")
wrap(gpu_culling, "RecordShadowViewAABBCulling", "gpu_culling.RecordShadowViewAABBCulling")
wrap(gpu_culling, "RefreshDynamicSceneVisuals", "gpu_culling.RefreshDynamicSceneVisuals")
wrap(gpu_culling, "PublishSceneAcceleration", "gpu_culling.PublishSceneAcceleration")
wrap(visual.Library, "GetVisibleMainGPUEntries", "visual.GetVisibleMainGPUEntries")
wrap(visual.Library, "GetShadowVisibleVisuals", "visual.GetShadowVisibleVisuals")
wrap(scene_bvh, "EnsureBuilt", "scene_bvh.EnsureBuilt")
wrap(skinning, "Dispatch", "skinning.Dispatch")
wrap(import("goluwa/render3d/scene_lights.lua"), "WriteLightsBlock", "scene_lights.WriteLightsBlock")
wrap(import("goluwa/render3d/scene_lights.lua"), "WriteShadowBlock", "scene_lights.WriteShadowBlock")
local BatchTable = import("goluwa/render3d/batch_table.lua")
wrap(BatchTable, "Update", "BatchTable.Update")
wrap(import("goluwa/render3d/gbuffer_instancing.lua"), "DrawGPUCulled", "gbuffer_instancing.DrawGPUCulled")
wrap(import("goluwa/render3d/model_pipeline.lua"), "WritePBRBatchRecord", "model_pipeline.WritePBRBatchRecord")
wrap(import("goluwa/render3d/model_pipeline.lua"), "WritePBRBatchAnimationRecord", "model_pipeline.WritePBRBatchAnimationRecord")
wrap(import("goluwa/render/vulkan/internal/buffer.lua"), "GetDeviceAddress", "Buffer.GetDeviceAddress")
-- all event listeners per event
local frames = tonumber(os.getenv("M3_FRAMES") or "200")
local start, n
local listener_wrapped = {}
local function wrap_listeners()
	for event_type, list in pairs(event.active) do
		for _, config in ipairs(list) do
			if not config.t_wrapped then
				config.t_wrapped = true
				local cb = config.callback
				local key = "event " .. tostring(event_type) .. "->" .. tostring(config.id)
				config.callback = function(...)
					if not measuring then return cb(...) end
					local t = system.GetTime()
					local a, b, c, d = cb(...)
					totals[key] = (totals[key] or 0) + system.GetTime() - t
					calls[key] = (calls[key] or 0) + 1
					return a, b, c, d
				end
			end
		end
	end
end
m3.Run(function(view, now)
	start = start or now
	if not measuring then
		if now - start < 1 then
			pvars.SetSession("r_feature_culling", os.getenv("M3_CULLING") ~= "0")
			pvars.SetSession("lod_level", -1)
		end
		if now - start > 9 then wrap_listeners() end
		if now - start > 10 then measuring = true n = 0 end
		return
	end
	n = n + 1
	if n >= frames then
		measuring = false
		local keys = {}
		for k in pairs(totals) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return totals[a] > totals[b] end)
		for i = 1, math.min(#keys, 30) do
			local k = keys[i]
			print(string.format("TIMEFN %-62s %7.3f ms/frame %7.1f calls/frame %8.1f us/call", k, totals[k] / n * 1000, calls[k] / n, totals[k] / calls[k] * 1e6))
		end
		return false
	end
end)
