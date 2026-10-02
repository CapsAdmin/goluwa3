if not RENDER_2D then return end

local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local stats = import("goluwa/physics/stats.lua")
-- Physics timing HUD. K toggles it (or the physics_stats command). Numbers are
-- averaged over WINDOW seconds: section times are per physics step, query and
-- scan numbers per drawn frame, counters per step unless the label says
-- otherwise.
local WINDOW = 0.5
local LINE_HEIGHT = 15
local PANEL_WIDTH = 470
local LABEL_X = 10
local MS_X = 190
local PERCENT_X = 268
local BAR_X = 330
local BAR_WIDTH = 130
local visible = false
local window_start = 0
local frames = 0
local snapshot_frames = 0
local snapshot = nil
local frame_time = 0
local last_draw = 0
local WHITE = Color(0.88, 0.9, 0.94, 1)
local DIM = Color(0.6, 0.64, 0.7, 1)
local HEAD = Color(1, 0.85, 0.4, 1)
local WARN = Color(1, 0.5, 0.4, 1)
local row_y = 0
local panel_height = 560
local panel_x = 0

local function text(x, label, color)
	render2d.DrawText{
		text = label,
		x = panel_x + x,
		y = row_y,
		foreground_color = color or WHITE,
	}
end

local function newline()
	row_y = row_y + LINE_HEIGHT
end

local function heading(label)
	row_y = row_y + 4
	text(LABEL_X, label, HEAD)
	newline()
end

local function timing_row(label, seconds, per, total, indent, color)
	local ms = per > 0 and seconds / per * 1000 or 0
	text(LABEL_X + indent, label, color or (indent > 0 and DIM or WHITE))
	text(MS_X, string.format("%7.3f ms", ms))

	if total and total > 0 then
		local fraction = math.min(seconds / total, 1)
		text(PERCENT_X, string.format("%5.1f%%", fraction * 100), DIM)
		render2d.SetTexture(nil)
		render2d.SetColor(0.35, 0.6, 0.95, 0.85)
		render2d.DrawRect(panel_x + BAR_X, row_y + 3, BAR_WIDTH * fraction, LINE_HEIGHT - 8)
	end

	newline()
end

local function count_row(label, value, per, unit)
	text(LABEL_X, label, WHITE)
	text(MS_X, string.format("%9.1f", per > 0 and value / per or 0))
	text(PERCENT_X, unit, DIM)
	newline()
end

local function draw_snapshot(x, y)
	local s = snapshot
	panel_x = x
	row_y = y
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRoundedRect(x, y, PANEL_WIDTH, panel_height, 6)
	row_y = y + 8

	if not s or s.steps == 0 then
		text(LABEL_X, "physics: no steps in the last window", WARN)
		newline()
	end

	if not s then return end

	local steps = math.max(s.steps, 1)
	local frame_count = math.max(snapshot_frames, 1)
	local step_seconds = s.total_time
	local gauges = s.gauges
	text(
		LABEL_X,
		string.format(
			"physics  %.1f steps/frame  frame %.1f ms",
			s.steps / frame_count,
			frame_time * 1000
		),
		HEAD
	)
	newline()
	text(
		LABEL_X,
		string.format(
			"bodies %d  awake %d  pairs %d  islands %d  substeps %d",
			gauges.bodies or 0,
			gauges.awake_bodies or 0,
			gauges.candidate_pairs or 0,
			gauges.islands or 0,
			gauges.substeps or 0
		),
		DIM
	)
	newline()
	heading("per step")
	timing_row("step total", step_seconds, steps, nil, 0, HEAD)
	text(
		MS_X + 80,
		string.format("max %.2f ms", s.max_step_time * 1000),
		s.max_step_time > 0.016 and WARN or DIM
	)
	newline()
	local accounted = 0

	for _, name in ipairs(stats.SectionNames) do
		local seconds = s.sections[name] or 0
		accounted = accounted + seconds
		timing_row(name, seconds, steps, step_seconds, 0)

		if name == "integrate" then
			timing_row("kinematic", s.sections.kinematic or 0, steps, step_seconds, 12)
		elseif name == "solve_pairs" then
			timing_row("mesh_contacts", s.sections.mesh_contacts or 0, steps, step_seconds, 12)
		end
	end

	timing_row("unaccounted", math.max(step_seconds - accounted, 0), steps, step_seconds, 0, DIM)
	heading("queries (per frame, any caller)")

	for _, name in ipairs(stats.QueryNames) do
		timing_row(name, s.sections[name] or 0, frame_count, nil, name:find("^sweep_") and 12 or 0)
	end

	heading("counts")
	local counts = s.counts
	count_row("solver pair iterations", counts.solver_pairs or 0, steps, "/step")
	count_row("mesh pairs", counts.mesh_pairs or 0, steps, "/step")
	count_row("mesh triangles tested", counts.mesh_triangles or 0, steps, "/step")
	count_row("contact points rebuilt", counts.contact_points or 0, steps, "/step")
	count_row("sweeps (all)", counts.sweeps or 0, frame_count, "/frame")
	count_row("  from ccd", counts.sweeps_ccd or 0, frame_count, "/frame")
	count_row("  from support (body)", counts.sweeps_support_body or 0, frame_count, "/frame")
	count_row("  from support (points)", counts.sweeps_support_points or 0, frame_count, "/frame")
	count_row("  from support (sphere)", counts.sweeps_support_sphere or 0, frame_count, "/frame")
	count_row("ray casts", counts.traces or 0, frame_count, "/frame")
	count_row("collider index queries", counts.collider_index_queries or 0, steps, "/step")
	count_row("  colliders returned", counts.collider_index_returned or 0, math.max(counts.collider_index_queries or 0, 1), "/query")
	count_row("  of colliders total", counts.collider_index_total or 0, math.max(counts.collider_index_queries or 0, 1), "/query")
	count_row("world model scans", counts.world_model_scans or 0, frame_count, "/frame")
	count_row("visuals per scan", counts.world_models_scanned or 0, math.max(counts.world_model_scans or 0, 1), "")
	count_row("model candidates per scan", counts.world_model_candidates or 0, math.max(counts.world_model_scans or 0, 1), "")
	count_row("woken bodies", counts.woken_bodies or 0, steps, "/step")
	count_row("slept bodies", counts.slept_bodies or 0, steps, "/step")
	panel_height = row_y - y + 10
end

local function set_visible(value)
	visible = value

	if visible then
		stats:Enable()
		window_start = system.GetElapsedTime()
		frames = 0
		snapshot_frames = 0
		snapshot = nil
	else
		stats:Disable()
	end

	print("[Physics Stats] " .. (visible and "Enabled" or "Disabled"))
end

event.AddListener("Draw2D", "physics_stats_hud", function()
	if not visible then return end

	frames = frames + 1
	local now = system.GetElapsedTime()
	frame_time = frame_time * 0.9 + (now - last_draw) * 0.1
	last_draw = now

	if now - window_start >= WINDOW then
		snapshot = stats:TakeSnapshot()
		window_start = now
		snapshot_frames = frames
		frames = 0
	end

	draw_snapshot(10, 10)
end)

event.AddListener("KeyInput", "physics_stats_hud_toggle", function(key, press)
	if not press then return end

	if key == "k" then set_visible(not visible) end
end)

commands.Add("physics_stats", function()
	set_visible(not visible)
end)
