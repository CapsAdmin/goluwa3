local commands = import("goluwa/cli/commands.lua")
local timer = import("goluwa/timer.lua")
local fs = import("goluwa/filesystem/fs.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local game = import("lua/crysis_loader/game.lua")
local level = import("lua/crysis_loader/level.lua")
local SYNC_SCRIPT = "addons/crysis_loader/crysis_scripts/goluwa_sync.lua"
local last_text
local SUN_SNAP_DEGREES = 0.2

commands.Add("crysis_sync=boolean[true]", function(on)
	timer.RemoveTimer("crysis_sync")

	if not on then return end

	local installed = assert(game.GetGame(17300))
	local scripts_dir = installed.game_dir .. "Game/Scripts/"
	local data_path = scripts_dir .. "goluwa_sync_data.lua"
	assert(fs.create_directory_recursive(scripts_dir))
	local script_path = scripts_dir .. "goluwa_sync.lua"
	local script_header = string.format(
		"goluwa_sync_data_path = %q\ngoluwa_sync_script_path = %q\n",
		data_path,
		script_path
	)
	local last_script
	local autoexec_path = installed.game_dir .. "Game/autoexec.cfg"
	local autoexec = fs.read_file(autoexec_path) or ""
	local autoexec_line = "#Script.ReloadScript(\"Scripts/goluwa_sync.lua\")"

	if not autoexec:find(autoexec_line, 1, true) then
		assert(fs.write_file(autoexec_path, autoexec .. autoexec_line .. "\n"))
	end

	print("in Crysis run: #Script.ReloadScript(\"Scripts/goluwa_sync.lua\")")

	timer.Repeat(
		"crysis_sync",
		0.5,
		0,
		function()
			local script = script_header .. assert(fs.read_file(SYNC_SCRIPT))

			if script ~= last_script then
				last_script = script
				assert(fs.write_file(script_path, script))
			end

			local camera = render3d.GetMainCamera()
			local pos = camera:GetPosition()
			local dir = camera:GetRotation():GetForward()
			local sun = weather.GetSunDirection()
			local time, sun_error
			local orbit = level.sun_orbit

			if orbit then
				time, sun_error = level.GetSunHours(orbit, sun)

				if math.abs(sun_error) > SUN_SNAP_DEGREES then
					weather.SetSunDirection(level.GetSunDirection(orbit, time))
					sun_error = 0
				end
			end

			local text = string.format(
				"goluwa_sync_data = {pos = {x = %.4f, y = %.4f, z = %.4f}, dir = {x = %.6f, y = %.6f, z = %.6f}, fov = %.4f, aspect = %.5f, time = %s, sun_error = %s, stamp = %d}\n",
				pos.x,
				-pos.z,
				pos.y,
				dir.x,
				-dir.z,
				dir.y,
				math.deg(camera:GetFOV()),
				camera.Viewport.w / camera.Viewport.h,
				time and string.format("%.5f", time) or "nil",
				sun_error and string.format("%.3f", sun_error) or "nil",
				os.time()
			)

			if text:gsub("stamp = %d+", "") ~= (last_text or ""):gsub("stamp = %d+", "") then
				last_text = text
				fs.write_file(data_path, text)
			end
		end
	)
end)

do
	local command_seq = os.time() % 8000000

	local function send(kind, code)
		local scripts_dir = assert(game.GetGame(17300)).game_dir .. "Game/Scripts/"
		local result_path = scripts_dir .. "goluwa_sync_result.txt"
		command_seq = command_seq + 1
		local seq = command_seq
		assert(fs.create_directory_recursive(scripts_dir))
		assert(
			fs.write_file(
				scripts_dir .. "goluwa_sync_cmd.lua",
				string.format("goluwa_sync_command = {seq = %d, kind = %q, code = %q}\n", seq, kind, code)
			)
		)
		local waited = 0

		timer.Repeat(
			"crysis_result",
			0.1,
			0,
			function()
				waited = waited + 0.1
				local text = fs.read_file(result_path)

				if text then
					local result_seq, ok, result = text:match("^(%d+)\n([^\n]*)\n(.*)$")

					if tonumber(result_seq) == seq then
						timer.RemoveTimer("crysis_result")
						print(ok == "true" and result or "error: " .. result)
						return
					end
				end

				if waited > 3 then
					timer.RemoveTimer("crysis_result")
					print("no answer from Crysis (is the sync script running?)")
				end
			end
		)
	end

	commands.Add("crylua=string_rest", function(code)
		send("lua", code)
	end)

	commands.Add("crycmd=string_rest", function(code)
		send("cmd", code)
	end)
end
