-- an empty scene: nothing is loaded, the engine just runs for SECONDS seconds and exits. the passes that draw are printed at the end
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local start = system.GetTime()
local draws = {}
local wrapped = false
event.AddListener("Update", "empty_scene", function()
	if not wrapped and render3d.pipelines_i and render3d.pipelines_i[1] then
		wrapped = true
		for _, pipeline in ipairs(render3d.pipelines_i) do
			draws[pipeline.name] = 0
			local original = pipeline.Draw
			pipeline.Draw = function(self, ...)
				draws[self.name] = draws[self.name] + 1
				return original(self, ...)
			end
		end
	end
	if system.GetTime() - start < tonumber(os.getenv("SECONDS") or 13) then return end
	for _, name in ipairs({"ddgi_trace", "ddgi_shade", "reflections_trace", "gbuffer"}) do
		print("PIPE " .. name .. " draws=" .. tostring(draws[name]))
	end
	os.exit(0)
end)
