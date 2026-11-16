local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local render = import("goluwa/render/render.lua")
local cpu_timing = import("goluwa/cpu_timing.lua")
local perf = import("lua/perf.lua")
local react = import("goluwa/render2d/ui/react.lua")
local timing_pie = import("lua/timing_pie.lua")
local last_time = table.weak("k")
local groups = {}
local frame_ms = 0
local last_frame
local last_wait = 0

local function describe(record, id)
	if type(id) == "string" then return id end

	local info = debug.getinfo(record.callback, "S")
	return info.short_src:match("[^/]*$") .. ":" .. info.linedefined
end

local function take_ms(record, frames)
	local total = record.cpu_time or 0
	local previous = last_time[record] or total
	last_time[record] = total
	return (total - previous) * 1000 / frames
end

local source = {
	title = "cpu",
	list_title = "events and timers",
	item_noun = "listeners",
	sort = true,
}

local function update()
	local frame = system.GetFrameNumber()

	if frame == last_frame then return end

	local frames = math.max(frame - (last_frame or frame - 1), 1)
	last_frame = frame
	groups = {}

	for event_type, listeners in pairs(event.active) do
		local items = {}

		for _, data in pairs(listeners) do
			if data.cpu_calls then
				items[#items + 1] = {
					id = tostring(data),
					label = describe(data, data.id),
					ms = take_ms(data, frames),
				}
			end
		end

		if #items > 0 then
			groups[#groups + 1] = {id = tostring(event_type), label = tostring(event_type), items = items}
		end
	end

	local items = {}

	for _, data in ipairs(timer.timers) do
		if data.cpu_calls then
			items[#items + 1] = {
				id = tostring(data),
				label = describe(data, data.id or data.key),
				ms = take_ms(data, frames),
			}
		end
	end

	if #items > 0 then groups[#groups + 1] = {id = "timers", label = "timers", items = items} end

	local wait = render.GetWaitTime()
	frame_ms = system.GetInternalFrameTime() * 1000 - (wait - last_wait) * 1000 / frames
	last_wait = wait
end

function source.GetGroups()
	update()
	return groups
end

function source.GetFrame()
	update()
	return frame_ms
end

function source.GetFootnote()
	return "exclusive of nested calls"
end

local CpuPie = timing_pie.Create("cpu_pie", source)
perf.RegisterTab(
	"CPU",
	0.5,
	react.Component(
		||-> do
			react.UseEffect(
				||-> do
					cpu_timing.Enable()
					return cpu_timing.Disable
				end,
				{}
			)

			return CpuPie{Size = Vec2(timing_pie.WIDTH, timing_pie.HEIGHT)}
		end
	)
)
