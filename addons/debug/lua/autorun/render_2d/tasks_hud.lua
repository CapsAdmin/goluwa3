local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local MAX_PROGRESS_LINES = 6
local lines = {}

event.AddListener("Draw2D", "tasks_hud", function()
	if not next(tasks.created) then return end

	local running, waiting = 0, 0
	local count = 0

	for task in pairs(tasks.created) do
		if task:IsRunning() then running = running + 1 else waiting = waiting + 1 end
	end

	lines[1] = string.format("tasks: %d running, %d waiting", running, waiting)
	count = 1

	for task in pairs(tasks.created) do
		if count > MAX_PROGRESS_LINES then break end

		for what, progress in pairs(task.progress or {}) do
			if progress.max ~= math.huge and progress.i <= progress.max then
				count = count + 1
				lines[count] = string.format("%s: %s %s", task:GetName(), what, task:GetProgress(what))
			end

			break
		end
	end

	for i = count + 1, #lines do
		lines[i] = nil
	end

	debug_draw.DrawTextBlock(lines, 8, 8, {padding = 6, line_gap = 2, background_alpha = 0.6})
end)
