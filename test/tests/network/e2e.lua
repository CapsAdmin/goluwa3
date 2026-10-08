local T = import("test/environment.lua")
local process = import("goluwa/bindings/process.lua")
local system = import("goluwa/system.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local base_directory = vfs.GetStorageDirectory("storage") .. "logs/network_e2e/"
local working_directory = vfs.GetStorageDirectory("working_directory")
local PROCESS_LIFETIME = 90
local scenarios = {}

local function read_file(path)
	local file = io.open(path, "rb")

	if not file then return nil end

	local data = file:read("*a")
	file:close()
	return data
end

local function pick_port(offset)
	return 20000 + (
			os.time() * 7 + math.floor(system.GetTime() * 1000) + offset * 97
		) % 30000
end

local function create_scenario(name, conditions, port_offset)
	local scenario = {
		name = name,
		conditions = conditions,
		directory = base_directory .. name .. "/",
		port = pick_port(port_offset),
		handles = {},
	}
	fs.create_directory_recursive(scenario.directory)

	for _, file in ipairs{
		"server.ready",
		"bot.synced",
		"bot.result",
		"observer.result",
		"server.log",
		"bot.log",
		"observer.log",
	} do
		os.remove(scenario.directory .. file)
	end

	scenarios[#scenarios + 1] = scenario
	return scenario
end

local function spawn(scenario, name, args)
	local log = scenario.directory .. name .. ".log"
	local command = string.format(
		"E2E_DIR='%s' GOLUWA_PORT=%d GOLUWA_NET_LATENCY=%s GOLUWA_NET_JITTER=%s GOLUWA_NET_LOSS=%s E2E_DESYNC=1 exec timeout -k 2 %d luajit glw %s < /dev/null > '%s' 2>&1",
		scenario.directory,
		scenario.port,
		scenario.conditions.latency,
		scenario.conditions.jitter,
		scenario.conditions.loss,
		PROCESS_LIFETIME,
		table.concat(args, " "),
		log
	)
	local proc = assert(
		process.spawn{
			command = "sh",
			args = {"-c", command},
			cwd = working_directory ~= "" and working_directory or nil,
		}
	)
	local handle = {proc = proc, log = log, name = name, command = command}
	scenario.handles[#scenario.handles + 1] = handle
	return handle
end

local function describe(handle)
	local done, code = handle.proc:try_wait()
	return string.format(
		"%s: %s\nstatus: %s\n--- log ---\n%s",
		handle.name,
		handle.command,
		done and ("exited with code " .. tostring(code)) or "still running",
		(read_file(handle.log) or ""):sub(1, 3000)
	)
end

local function describe_all(scenario)
	local out = {}

	for _, handle in ipairs(scenario.handles) do
		out[#out + 1] = describe(handle)
	end

	return table.concat(out, "\n")
end

local function wait_for_file(scenario, file, timeout, watched)
	local path = scenario.directory .. file
	local description = string.format("%s: %s", scenario.name, file)
	local failure
	local ok = pcall(
		T.WaitUntilReal,
		function()
			if read_file(path) then return true end

			for _, handle in ipairs(watched) do
				if handle.proc:try_wait() then
					failure = handle.name .. " exited early"
					return true
				end
			end
		end,
		timeout,
		description
	)

	if failure or not ok then
		error(
			string.format(
				"waiting for %s: %s\n%s",
				description,
				failure or ("timed out after " .. timeout .. "s"),
				describe_all(scenario)
			),
			0
		)
	end

	return read_file(path)
end

local function handle_named(scenario, name)
	for _, handle in ipairs(scenario.handles) do
		if handle.name == name then return handle end
	end
end

local function cleanup()
	for _, scenario in ipairs(scenarios) do
		for _, handle in ipairs(scenario.handles) do
			if not handle.proc:try_wait() then handle.proc:kill() end
		end
	end

	scenarios = {}
end

local function verify(scenario, observer_output, bot_output)
	local failures = {}

	local function check(ok, message)
		if not ok then failures[#failures + 1] = message end
	end

	check(
		observer_output:find("OBSERVER_RESULT passed=true", 1, true) ~= nil,
		"observer checks failed:\n" .. observer_output
	)
	local bx, by, bz, corrections, max_error = bot_output:match(
		"BOT_RESULT x=([%-%d%.]+) y=([%-%d%.]+) z=([%-%d%.]+) corrections=(%d+) max_error=([%d%.]+)"
	)
	check(bx ~= nil, "no bot result")

	if not bx then return failures end

	check(tonumber(corrections) > 0, "the forced desync was never corrected")
	check(
		tonumber(max_error) > 1.5,
		"the forced desync was corrected by only " .. max_error
	)
	check(math.sqrt(bx * bx + bz * bz) > 1.5, "the bot did not move")
	local _, crate_distance, holding = observer_output:match("OBSERVER_CRATE lifted=(%a+) distance=([%d%.]+) max_y=[%d%.]+ holding=(%a+)")
	check(holding == "true", "the physgun hold was not replicated")
	check(
		tonumber(crate_distance) and
			tonumber(crate_distance) > 2 and
			tonumber(crate_distance) < 6,
		"the held crate was " .. tostring(crate_distance) .. " m from the player"
	)
	local list, saw_physgun, active = observer_output:match("OBSERVER_WEAPONS list=([%w_,]+) physgun=(%a+) active=([%w_]+)")
	check(
		list == "weapon_camera,weapon_physgun,weapon_pistol",
		"the weapon children were not replicated: " .. tostring(list)
	)
	check(saw_physgun == "true", "the physgun was never the replicated active weapon")
	check(
		active == "weapon_pistol",
		"the slot switch did not replicate, active weapon: " .. tostring(active)
	)
	local batches, last = observer_output:match("OBSERVER_RELAY batches=(%d+) last=(%d+)")
	check(
		tonumber(batches) and tonumber(batches) > 30,
		"too few relayed command batches: " .. tostring(batches)
	)
	check(
		tonumber(last) and tonumber(last) > 150,
		"relayed commands stopped early: " .. tostring(last)
	)
	check(
		bot_output:find("BOT_RELAYS_RECEIVED 0", 1, true) ~= nil,
		"the bot received its own commands"
	)
	local ax, ay, az = observer_output:match("OBSERVER_AVATAR x=([%-%d%.]+) y=([%-%d%.]+) z=([%-%d%.]+)")
	check(ax ~= nil, "the observer never saw the avatar")

	if ax then
		local distance = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
		check(
			distance < scenario.conditions.tolerance,
			string.format("the avatar was %.3f m from the bot", distance)
		)
	end

	return failures
end

T.Test("network e2e: replication, prediction, reconciliation and relay under good and bad connections", function()
	local ok, err = xpcall(
		function()
			local active = {
				create_scenario("clean", {latency = 0, jitter = 0, loss = 0, tolerance = 0.25}, 1),
				create_scenario("lossy", {latency = 60, jitter = 25, loss = 3, tolerance = 0.4}, 2),
			}

			for _, scenario in ipairs(active) do
				spawn(
					scenario,
					"server",
					{"--server", "--fps=120", "lua", "test/network_e2e/server.lua"}
				)
			end

			for _, scenario in ipairs(active) do
				wait_for_file(scenario, "server.ready", 30, {handle_named(scenario, "server")})
				spawn(
					scenario,
					"bot",
					{"--cli", "--physics", "--fps=120", "lua", "test/network_e2e/bot.lua"}
				)
			end

			for _, scenario in ipairs(active) do
				wait_for_file(
					scenario,
					"bot.synced",
					30,
					{handle_named(scenario, "bot"), handle_named(scenario, "server")}
				)
				spawn(
					scenario,
					"observer",
					{"--cli", "--physics", "--fps=120", "lua", "test/network_e2e/observer.lua"}
				)
			end

			local failures = {}

			for _, scenario in ipairs(active) do
				local watched = {
					handle_named(scenario, "observer"),
					handle_named(scenario, "bot"),
					handle_named(scenario, "server"),
				}
				local observer_output = wait_for_file(scenario, "observer.result", 60, watched)
				local bot_output = wait_for_file(scenario, "bot.result", 5, watched)

				for _, message in ipairs(verify(scenario, observer_output, bot_output)) do
					failures[#failures + 1] = scenario.name .. ": " .. message
				end
			end

			if failures[1] then error(table.concat(failures, "\n"), 0) end
		end,
		debug.traceback
	)
	cleanup()

	if not ok then error(err .. "\nlogs are in " .. base_directory, 0) end
end)
