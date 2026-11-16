local Vec2 = import("goluwa/structs/vec2.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local perf = import("lua/perf.lua")
local react = import("goluwa/render2d/ui/react.lua")
local timing_pie = import("lua/timing_pie.lua")

local function pass_label(group, name)
	local label = gpu_timing.GetLabel(name):lower()
	local word = group.scopes[1]:match("^[^_]+")

	if #group.scopes == 1 then return label end

	for _, scope in ipairs(group.scopes) do
		if scope:match("^[^_]+") ~= word then return label end
	end

	return label:sub(#word + 2)
end

local source = {
	title = "gpu",
	list_title = "systems",
	item_noun = "passes",
}

function source.GetGroups()
	local groups = {}

	for i, group in ipairs(gpu_timing.GetGroups()) do
		local items = {}

		for j, name in ipairs(group.scopes) do
			items[j] = {
				id = name,
				label = pass_label(group, name),
				ms = gpu_timing.GetMilliseconds(name),
			}
		end

		groups[i] = {id = group.id, label = group.label:lower(), items = items}
	end

	return groups
end

function source.GetFrame()
	return gpu_timing.GetMilliseconds("gpu_frame")
end

function source.GetFootnote(total, frame)
	return string.format(
		"compute queue %.2f ms, overlap %.2f ms",
		gpu_timing.GetMilliseconds("gpu_compute"),
		math.max(total - frame, 0)
	)
end

local GpuPie = timing_pie.Create("gpu_pie", source)
perf.RegisterTab(
	"GPU",
	1,
	react.Component(||->GpuPie{Size = Vec2(timing_pie.WIDTH, timing_pie.HEIGHT)})
)
