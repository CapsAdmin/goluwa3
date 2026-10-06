local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local network = import("goluwa/network/network.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
local LINE_HEIGHT = 15
local PANEL_WIDTH = 300
local WHITE = Color(0.88, 0.9, 0.94, 1)
local HEAD = Color(1, 0.85, 0.4, 1)
local WARN = Color(1, 0.5, 0.4, 1)
local visible = false
local last_time = 0
local last = {bytes_in = 0, bytes_out = 0, received = 0, sent = 0}
local rates = {in_kb = 0, out_kb = 0, in_pps = 0, out_pps = 0}
local row_y = 0

local function line(label, color)
	render2d.DrawText{text = label, x = 18, y = row_y, foreground_color = color or WHITE}
	row_y = row_y + LINE_HEIGHT
end

event.AddListener("Draw2D", "net_stats", function()
	if not visible then return end

	local peer = network.socket
	local now = system.GetTime()
	row_y = 24
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRoundedRect(8, 8, PANEL_WIDTH, 190, 6)
	line("network", HEAD)

	if not (peer:IsValid() and peer:IsConnected()) then
		line("not connected", WARN)
		return
	end

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
end)

commands.Add("net_stats", function()
	visible = not visible
	print("[net stats] " .. (visible and "Enabled" or "Disabled"))
end)
