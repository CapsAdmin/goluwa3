if not RENDER_2D then return end

local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local stats = import("goluwa/physics/stats.lua")
local StatTable = import("goluwa/render2d/ui/widgets/stat_table.lua")
local perf = import("lua/perf.lua")
local WINDOW = 0.5
local enabled = false
local window_start = 0
local last_rows_time = 0
local frames = 0
local snapshot_frames = 0
local snapshot
local frame_time = 0
local last_draw = 0

local function timing_row(rows, label, seconds, per, total, indent, color)
	local ms = per > 0 and seconds / per * 1000 or 0
	local row = {
		label = string.rep(" ", indent) .. label,
		value = string.format("%.3f ms", ms),
		color = color or (indent > 0 and "dim" or nil),
	}

	if total and total > 0 then
		local fraction = math.min(seconds / total, 1)
		row.detail = string.format("%.1f%%", fraction * 100)
		row.fraction = fraction
	end

	rows[#rows + 1] = row
end

local function count_row(rows, label, value, per, unit)
	rows[#rows + 1] = {label = label, value = string.format("%.1f", per > 0 and value / per or 0), detail = unit}
end

local function build_rows()
	local rows = {}
	local s = snapshot

	if not s then
		rows[1] = {label = "physics: collecting", color = "warn"}
		return rows
	end

	if s.steps == 0 then
		rows[#rows + 1] = {label = "physics: no steps in the last window", color = "warn"}
	end

	local steps = math.max(s.steps, 1)
	local frame_count = math.max(snapshot_frames, 1)
	local step_seconds = s.total_time
	local gauges = s.gauges
	local counts = s.counts
	rows[#rows + 1] = {
		label = string.format("physics  %.1f steps/frame  frame %.1f ms", s.steps / frame_count, frame_time * 1000),
		color = "head",
	}
	rows[#rows + 1] = {
		label = string.format(
			"bodies %d  awake %d  pairs %d  islands %d  substeps %d",
			gauges.bodies or 0,
			gauges.awake_bodies or 0,
			gauges.candidate_pairs or 0,
			gauges.islands or 0,
			gauges.substeps or 0
		),
		color = "dim",
	}
	rows[#rows + 1] = {label = "per step", color = "head"}
	timing_row(rows, "step total", step_seconds, steps, nil, 0, "head")
	rows[#rows].detail = string.format("max %.2f ms", s.max_step_time * 1000)
	local accounted = 0

	for _, name in ipairs(stats.SectionNames) do
		local seconds = s.sections[name] or 0
		accounted = accounted + seconds
		timing_row(rows, name, seconds, steps, step_seconds, 0)

		if name == "integrate" then
			timing_row(rows, "kinematic", s.sections.kinematic or 0, steps, step_seconds, 2)
		elseif name == "solve_pairs" then
			timing_row(rows, "mesh_contacts", s.sections.mesh_contacts or 0, steps, step_seconds, 2)
		end
	end

	timing_row(rows, "unaccounted", math.max(step_seconds - accounted, 0), steps, step_seconds, 0, "dim")
	rows[#rows + 1] = {label = "queries (per frame, any caller)", color = "head"}

	for _, name in ipairs(stats.QueryNames) do
		timing_row(rows, name, s.sections[name] or 0, frame_count, nil, name:find("^sweep_") and 2 or 0)
	end

	rows[#rows + 1] = {label = "counts", color = "head"}
	count_row(rows, "solver pair iterations", counts.solver_pairs or 0, steps, "/step")
	count_row(rows, "mesh pairs", counts.mesh_pairs or 0, steps, "/step")
	count_row(rows, "mesh triangles tested", counts.mesh_triangles or 0, steps, "/step")
	count_row(rows, "contact points rebuilt", counts.contact_points or 0, steps, "/step")
	count_row(rows, "sweeps (all)", counts.sweeps or 0, frame_count, "/frame")
	count_row(rows, "  from ccd", counts.sweeps_ccd or 0, frame_count, "/frame")
	count_row(rows, "  from support (body)", counts.sweeps_support_body or 0, frame_count, "/frame")
	count_row(rows, "  from support (points)", counts.sweeps_support_points or 0, frame_count, "/frame")
	count_row(rows, "  from support (sphere)", counts.sweeps_support_sphere or 0, frame_count, "/frame")
	count_row(rows, "ray casts", counts.traces or 0, frame_count, "/frame")
	count_row(rows, "collider index queries", counts.collider_index_queries or 0, steps, "/step")
	local queries = math.max(counts.collider_index_queries or 0, 1)
	count_row(rows, "  colliders returned", counts.collider_index_returned or 0, queries, "/query")
	count_row(rows, "  of colliders total", counts.collider_index_total or 0, queries, "/query")
	count_row(rows, "world model scans", counts.world_model_scans or 0, frame_count, "/frame")
	local scans = math.max(counts.world_model_scans or 0, 1)
	count_row(rows, "visuals per scan", counts.world_models_scanned or 0, scans, "")
	count_row(rows, "model candidates per scan", counts.world_model_candidates or 0, scans, "")
	count_row(rows, "woken bodies", counts.woken_bodies or 0, steps, "/step")
	count_row(rows, "slept bodies", counts.slept_bodies or 0, steps, "/step")
	return rows
end

local function sample()
	local now = system.GetElapsedTime()
	last_rows_time = now

	if not enabled then
		enabled = true
		stats:Enable()
		window_start = now
		frames = 0
		snapshot_frames = 0
		snapshot = nil
		last_draw = now
	end

	frames = frames + 1
	frame_time = frame_time * 0.9 + (now - last_draw) * 0.1
	last_draw = now

	if now - window_start >= WINDOW then
		snapshot = stats:TakeSnapshot()
		window_start = now
		snapshot_frames = frames
		frames = 0
	end
end

perf.RegisterTab("PHYSICS", 4, function()
	return StatTable{
		Size = Vec2(660, 470),
		Columns = 2,
		OnRows = function()
			sample()
			return build_rows()
		end,
	}
end)

event.AddListener("Update", "physics_stats_idle", function()
	if enabled and system.GetElapsedTime() - last_rows_time > 0.25 then
		enabled = false
		stats:Disable()
	end
end)

commands.Add("physics_stats", function()
	if not snapshot then
		print("[physics stats] open the PERF window on the PHYSICS tab to collect a snapshot")
		return
	end

	perf.PrintRows(build_rows())
end)
