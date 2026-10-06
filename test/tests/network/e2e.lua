local T = import("test/environment.lua")
local process = import("goluwa/bindings/process.lua")
local threads = import("goluwa/bindings/threads.lua")
process.setenv("GOLUWA_PORT", "27391")

local function spawn(args)
	local command_args = {"60", "luajit", "glw"}

	for _, arg in ipairs(args) do
		table.insert(command_args, arg)
	end

	return assert(
		process.spawn{command = "timeout", args = command_args, stdout = "pipe", stderr = "pipe"}
	)
end

local function read_all(proc)
	local out = {}

	while true do
		local chunk = proc:read(4096)

		if not chunk or chunk == "" then break end

		out[#out + 1] = chunk
	end

	return table.concat(out)
end

local function run_scenario(conditions)
	process.setenv("GOLUWA_NET_LATENCY", tostring(conditions.latency))
	process.setenv("GOLUWA_NET_JITTER", tostring(conditions.jitter))
	process.setenv("GOLUWA_NET_LOSS", tostring(conditions.loss))
	process.setenv("E2E_DESYNC", "1")
	process.setenv("DUR", "11")
	local server = spawn{"--server", "lua", "test/network_e2e/server.lua"}
	threads.sleep(3000)
	local bot = spawn{"--cli", "--physics", "lua", "test/network_e2e/bot.lua"}
	threads.sleep(1000)
	process.setenv("DUR", "9")
	local observer = spawn{"--cli", "--physics", "lua", "test/network_e2e/observer.lua"}
	local observer_code = observer:wait()
	local observer_output = read_all(observer)
	local bot_code = bot:wait()
	local bot_output = read_all(bot)
	server:kill()
	T(observer_code)["=="](0)
	T(observer_output:find("OBSERVER_RESULT passed=true", 1, true) ~= nil)["=="](true)
	T(bot_code)["=="](0)
	local bx, by, bz, corrections, max_error = bot_output:match(
		"BOT_RESULT x=([%-%d%.]+) y=([%-%d%.]+) z=([%-%d%.]+) corrections=(%d+) max_error=([%d%.]+)"
	)
	T(bx ~= nil)["=="](true)
	T(tonumber(corrections))[">"](0)
	T(tonumber(max_error))[">"](1.5)
	T(math.sqrt(bx * bx + bz * bz))[">"](3)
	local _, crate_distance, holding = observer_output:match("OBSERVER_CRATE lifted=(%a+) distance=([%d%.]+) max_y=[%d%.]+ holding=(%a+)")
	T(holding)["=="]("true")
	T(tonumber(crate_distance))[">"](3)
	T(tonumber(crate_distance))["<"](5)
	local batches, last = observer_output:match("OBSERVER_RELAY batches=(%d+) last=(%d+)")
	T(tonumber(batches))[">"](50)
	T(tonumber(last))[">"](300)
	T(bot_output:find("BOT_RELAYS_RECEIVED 0", 1, true) ~= nil)["=="](true)
	local ax, ay, az = observer_output:match("OBSERVER_AVATAR x=([%-%d%.]+) y=([%-%d%.]+) z=([%-%d%.]+)")
	T(ax ~= nil)["=="](true)
	local distance = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
	T(distance)["<"](conditions.tolerance)
end

T.Test("network e2e: replication, prediction and reconciliation", function()
	run_scenario{latency = 0, jitter = 0, loss = 0, tolerance = 0.25}
end)

T.Test("network e2e: prediction survives latency, jitter and packet loss", function()
	run_scenario{latency = 60, jitter = 25, loss = 3, tolerance = 0.4}
end)
