local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local network = import("goluwa/network/network.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
local scene_sync = import("goluwa/network/scene_sync.lua")
local LINE_HEIGHT = 15
local PANEL_WIDTH = 420
local WHITE = Color(0.88, 0.9, 0.94, 1)
local HEAD = Color(1, 0.85, 0.4, 1)
local DIM = Color(0.6, 0.64, 0.7, 1)
local WARN = Color(1, 0.5, 0.4, 1)
local visible = false
local last_time = 0
local last = {bytes_in = 0, bytes_out = 0, received = 0, sent = 0}
local rates = {in_kb = 0, out_kb = 0, in_pps = 0, out_pps = 0}
local rows = {}

local function line(label, color)
	rows[#rows + 1] = {label, color or WHITE}
end

local SNAPSHOT_COLORS = {downloading = HEAD, spawning = HEAD}

local function format_bytes(bytes)
	if bytes >= 1048576 then return string.format("%.2f MB", bytes / 1048576) end

	if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end

	return string.format("%d B", bytes)
end

local function add_scene_lines(now)
	local stats = scene_sync.stats
	line("scene sync", HEAD)

	if stats.state == "none" then
		line("no scene received", DIM)
		return
	end

	if stats.state == "ready" then
		line(
			string.format(
				"snapshot %d records  %s  %.2f s",
				stats.records,
				format_bytes(stats.snapshot_bytes),
				stats.snapshot_time
			)
		)
	else
		line(
			string.format(
				"snapshot %s  %s / %s  (%.0f%%)",
				stats.state,
				format_bytes(stats.received),
				format_bytes(stats.size),
				stats.size > 0 and stats.received / stats.size * 100 or 0
			),
			SNAPSHOT_COLORS[stats.state]
		)
	end

	line(string.format("checksum %08x", stats.checksum), DIM)
	line(
		string.format(
			"property changes %d  %s  applies %d  removes %d",
			stats.deltas,
			format_bytes(stats.delta_bytes),
			stats.applies,
			stats.removes
		)
	)

	if stats.last_delta ~= "" then line("last " .. stats.last_delta, DIM) end

	line(string.format("pushed %d  %s", stats.pushes, format_bytes(stats.push_bytes)))
	local adopted = 0
	local spawned = 0

	for _, component in pairs(NetworkComponent.GetAllNetworked()) do
		if component.adopted then adopted = adopted + 1 else spawned = spawned + 1 end
	end

	line(string.format("networked: %d spawned  %d bound to scene", spawned, adopted))

	for i = #stats.log, 1, -1 do
		local entry = stats.log[i]
		line(string.format("%5.1fs  %s", now - entry.time, entry.text), DIM)
	end
end

event.AddListener("Draw2D", "net_stats", function()
	if not visible then return end

	local peer = network.socket
	local now = system.GetTime()
	rows = {}
	line("network", HEAD)

	if not (peer:IsValid() and peer:IsConnected()) then
		line("not connected", WARN)
	else
		local stats = peer:GetStats()

		if now - last_time >= 1 then
			local dt = now - last_time
			rates.in_kb = (stats.bytes_in - last.bytes_in) / dt / 1024
			rates.out_kb = (stats.bytes_out - last.bytes_out) / dt / 1024
			rates.in_pps = (stats.received - last.received) / dt
			rates.out_pps = (stats.sent - last.sent) / dt
			last.bytes_in = stats.bytes_in
			last.bytes_out = stats.bytes_out
			last.received = stats.received
			last.sent = stats.sent
			last_time = now
		end

		line(string.format("ping %.0f ms", peer:GetPing()))
		line(string.format("in  %.1f KB/s  %.0f msg/s", rates.in_kb, rates.in_pps))
		line(string.format("out %.1f KB/s  %.0f msg/s", rates.out_kb, rates.out_pps))
		line(
			string.format("retransmitted %d", stats.retransmitted),
			stats.retransmitted > 0 and WARN or WHITE
		)
		local entities = 0

		for _ in pairs(NetworkComponent.GetAllNetworked()) do
			entities = entities + 1
		end

		line(string.format("networked entities %d", entities))
		local rig = _G.PLAYER_RIG

		if rig and rig:IsValid() then
			local controller = rig.player_controller
			line(
				string.format("commands %d  synced %s", controller.number, tostring(controller.synced == true))
			)
			line(
				string.format(
					"corrections %d  last %.3f m",
					controller.corrections,
					controller.last_correction or 0
				),
				(controller.last_correction or 0) > 0.5 and WARN or WHITE
			)
			line(string.format("view correction %.3f m", controller.correction_offset:GetLength()))
		end

		add_scene_lines(now)
	end

	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRoundedRect(8, 8, PANEL_WIDTH, #rows * LINE_HEIGHT + 24, 6)

	for i, row in ipairs(rows) do
		render2d.DrawText{
			text = row[1],
			x = 18,
			y = 9 + i * LINE_HEIGHT,
			foreground_color = row[2],
		}
	end
end)

commands.Add("net_stats", function()
	visible = not visible
	print("[net stats] " .. (visible and "Enabled" or "Disabled"))
end)
