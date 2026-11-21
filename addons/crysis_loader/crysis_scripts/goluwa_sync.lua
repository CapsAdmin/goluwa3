goluwa_sync_cmd_path = goluwa_sync_data_path:gsub("goluwa_sync_data%.lua$", "goluwa_sync_cmd.lua")
goluwa_sync_result_path = goluwa_sync_data_path:gsub("goluwa_sync_data%.lua$", "goluwa_sync_result.txt")
goluwa_sync_active = false
goluwa_sync_period = 200
goluwa_sync_cvars = {
	sys_AI = {0, 1},
	cl_hud = {0, 1},
	r_PostProcessEffects = {0, 1},
	e_clouds = {0, 1},
	e_shadows_clouds = {0, 1},
	r_HDRLevel = {0, 0.6},
	r_PostProcessEffectsFilters = {0, 1},
	r_ColorGrading = {0, 1},
	r_ColorGradingFilters = {0, 1},
	r_ColorGradingLevels = {0, 1},
	r_ColorGradingSelectiveColor = {0, 1},
	e_lod_ratio = {1000, 6},
	ca_lod_ratio = {1000, 6},
	e_view_dist_ratio = {1000, 60},
	e_view_dist_ratio_detail = {1000, 24},
	e_view_dist_ratio_vegetation = {1000, 31},
	e_view_dist_custom_ratio = {1000, 100},
	e_vegetation_sprites_distance_ratio = {1000, 1},
	e_vegetation_sprites_distance_custom_ratio_min = {1000, 1},
	e_cull_veg_activation = {0, 50},
	e_shadows_cast_view_dist_ratio = {1000, 0.8},
	e_detail_materials_view_dist_z = {2048, 128},
	e_max_view_dst = {16000, -1},
}
goluwa_sync_post_params = {
	ColorGrading_PhotoFilterColorDensity_Offset = -1,
}
goluwa_sync_fov_horizontal = false
goluwa_sync_last_stamp = nil
goluwa_sync_generation = goluwa_sync_generation or 0
goluwa_sync_timer = {generation = 0}
goluwa_sync_ticks = 0

function goluwa_sync_tick(timer)
	if not goluwa_sync_active or timer.generation ~= goluwa_sync_generation then
		return
	end

	goluwa_sync_ticks = goluwa_sync_ticks + 1

	if goluwa_sync_ticks <= 5 then
		System.LogAlways("goluwa sync tick " .. goluwa_sync_ticks)
	end

	Script.SetTimer(goluwa_sync_period, goluwa_sync_tick, timer)
	local ok, err = pcall(goluwa_sync_apply)

	if not ok and err ~= goluwa_sync_last_error then
		goluwa_sync_last_error = err
		System.LogAlways("goluwa sync error: " .. tostring(err))
	end
end

function goluwa_sync_dump(value, depth)
	if type(value) ~= "table" or depth > 2 then return tostring(value) end

	local parts = {}

	for k, v in pairs(value) do
		parts[#parts + 1] = tostring(k) .. "=" .. goluwa_sync_dump(v, depth + 1)
	end

	return "{" .. table.concat(parts, ", ") .. "}"
end

function goluwa_sync_run_command()
	local file = io.open(goluwa_sync_cmd_path, "rb")

	if not file then
		goluwa_sync_last_command_seq = goluwa_sync_last_command_seq or 0
		return
	end

	local text = file:read("*a")
	file:close()
	local chunk = loadstring(text)

	if not chunk then return end

	local env = {}
	setfenv(chunk, env)
	chunk()
	local command = env.goluwa_sync_command

	if not command or command.seq == goluwa_sync_last_command_seq then return end

	local stale = goluwa_sync_last_command_seq == nil
	goluwa_sync_last_command_seq = command.seq

	if stale then return end

	local ok, result

	if command.kind == "cmd" then
		ok, result = pcall(System.ExecuteCommand, command.code)
	else
		local fn, err = loadstring("return " .. command.code)

		if not fn then fn, err = loadstring(command.code) end

		if fn then ok, result = pcall(fn) else ok, result = false, err end
	end

	local out = io.open(goluwa_sync_result_path, "wb")

	if out then
		out:write(string.format("%d\n%s\n%s", command.seq, tostring(ok), goluwa_sync_dump(result, 0)))
		out:close()
	end
end

function goluwa_sync_apply()
	pcall(goluwa_sync_run_command)
	local script_file = io.open(goluwa_sync_script_path, "rb")

	if script_file then
		local text = script_file:read("*a")
		script_file:close()

		if goluwa_sync_script_text and text ~= goluwa_sync_script_text then
			goluwa_sync_script_text = text
			local chunk, err = loadstring(text)

			if chunk then
				System.LogAlways("goluwa sync reloading script")
				chunk()
			else
				System.LogAlways("goluwa sync reload error: " .. tostring(err))
			end

			return
		end

		goluwa_sync_script_text = text
	end

	System.SetCVar("e_sleep", 0)
	local file = io.open(goluwa_sync_data_path, "rb")
	local data

	if file then
		local text = file:read("*a")
		file:close()
		local chunk = loadstring(text)

		if chunk then
			local env = {}
			setfenv(chunk, env)
			chunk()
			data = env.goluwa_sync_data
		end
	end

	local actor = g_localActor

	if actor and not goluwa_sync_initialized then
		goluwa_sync_initialized = true
		goluwa_sync_set_inspection_state(true)

		if not goluwa_sync_eye_offset then
			local camera = System.GetViewCameraPos()
			local body = actor:GetWorldPos()
			goluwa_sync_eye_offset = {
				x = camera.x - body.x,
				y = camera.y - body.y,
				z = camera.z - body.z,
			}
			System.LogAlways(
				string.format(
					"goluwa sync eye offset %.3f %.3f %.3f",
					goluwa_sync_eye_offset.x,
					goluwa_sync_eye_offset.y,
					goluwa_sync_eye_offset.z
				)
			)
		end
	end

	if data and actor then
		local offset = goluwa_sync_eye_offset
		actor:SetWorldPos{
			x = data.pos.x - offset.x,
			y = data.pos.y - offset.y,
			z = data.pos.z - offset.z,
		}
		local angles = {
			x = math.asin(data.dir.z),
			y = 0,
			z = math.atan2(-data.dir.x, data.dir.y),
		}
		actor.actor:SetAngles(angles)
		actor:SetWorldAngles(angles)
		local fov = data.fov

		if goluwa_sync_fov_horizontal then
			fov = math.deg(2 * math.atan(math.tan(math.rad(fov) / 2) * data.aspect))
		end

		System.SetCVar("cl_fov", fov)

		if data.time then
			System.SetCVar("e_time_of_day_speed", 0)
			System.SetCVar("e_time_of_day", data.time)
		end

		if data.stamp ~= goluwa_sync_last_stamp then
			goluwa_sync_last_stamp = data.stamp
			local view = System.GetViewCameraDir()
			System.LogAlways(
				string.format(
					"goluwa sync dir: want %.3f %.3f %.3f, camera %.3f %.3f %.3f, angles %.3f %.3f",
					data.dir.x,
					data.dir.y,
					data.dir.z,
					view.x,
					view.y,
					view.z,
					angles.x,
					angles.z
				)
			)
			System.LogAlways(
				string.format(
					"goluwa sync: time %.2f, sun error %.2f deg",
					data.time or -1,
					data.sun_error or -1
				)
			)
		end
	end
end

function goluwa_sync_set_inspection_state(on)
	for name, values in pairs(goluwa_sync_cvars) do
		System.SetCVar(name, on and values[1] or values[2])
	end

	if g_localActor then
		local ok, err = pcall(g_localActor.HolsterItem, g_localActor, on)

		if not ok then
			System.LogAlways("goluwa sync holster error: " .. tostring(err))
		end
	end
end

function sync_goluwa(on)
	goluwa_sync_generation = goluwa_sync_generation + 1

	if on == false or on == 0 then
		goluwa_sync_active = false
		goluwa_sync_eye_offset = nil
		goluwa_sync_set_inspection_state(false)
		System.LogAlways("disabled sync")
		return
	end

	goluwa_sync_initialized = false
	goluwa_sync_active = true
	goluwa_sync_ticks = 0
	goluwa_sync_tick({generation = goluwa_sync_generation})
	System.LogAlways("enabled sync")
end

System.LogAlways("ran sync")
sync_goluwa()
