local list = require("helpers.list")
local get_time = require("bindings.time")
local system = _G.system or {}

function system.GetTime()
	return get_time()
end

do
	system.run = true

	function system.ShutDown(code)
		code = code or 0

		if VERBOSE then logn("shutting down with code ", code) end

		system.run = code
		os.exitcode = code
	end

	local old = os.exit

	function os.exit(code)
		wlog("os.exit() called with code %i", code or 0, 2)
	--system.ShutDown(code)
	end

	function os.realexit(code)
		old(code)
	end
end

local function not_implemented()
	debug.trace()
	logn("this function is not yet implemented!")
end

do -- frame time
	local frame_time = 0.1

	function system.GetFrameTime()
		return frame_time
	end

	-- used internally in main_loop.lua
	function system.SetFrameTime(dt)
		frame_time = dt
	end
end

do -- frame time
	local frame_time = 0.1

	function system.GetInternalFrameTime()
		return frame_time
	end

	-- used internally in main_loop.lua
	function system.SetInternalFrameTime(dt)
		frame_time = dt
	end
end

do -- frame number
	local frame_number = 0

	function system.GetFrameNumber()
		return frame_number
	end

	-- used internally in main_loop.lua
	function system.SetFrameNumber(num)
		frame_number = num
	end
end

do -- elapsed time (avanved from frame time)
	local elapsed_time = 0

	function system.GetElapsedTime()
		return elapsed_time
	end

	-- used internally in main_loop.lua
	function system.SetElapsedTime(num)
		elapsed_time = num
	end
end

do -- server time (synchronized across client and server)
	local server_time = 0

	function system.SetServerTime(time)
		server_time = time
	end

	function system.GetServerTime()
		return server_time
	end
end

do -- arg is made from luajit.exe
	local arg = _G.arg or {}
	_G.arg = nil
	arg[0] = nil
	arg[-1] = nil
	list.remove(arg, 1)

	function system.GetStartupArguments()
		return arg
	end
end

do
	-- this should be used for xpcall
	local suppress = false

	function system.OnError(msg, ...)
		logfile.LogSection("lua error", true)

		if msg then logn(msg) end

		msg = msg or "no error"
		msg = tostring(msg)

		if suppress then
			logn("error in system.OnError: ", msg, ...)
			logn(debug.traceback())
			return
		end

		suppress = true

		if event.Call("LuaError", msg) == false then return end

		if msg:find("stack overflow") then
			logn(msg)
			table.print(debug.getinfo(3))
		elseif msg:find("\n") then
			-- if the message contains a newline it's
			-- probably not a good idea to do anything fancy
			logn(msg)
		else
			logn("STACK TRACE:")
			logn("{")
			local data = {}

			for level = 3, 100 do
				local info = debug.getinfo(level)

				if info then
					info.source = debug.get_pretty_source(level) .. ":" .. (info.currentline or 0)
					local args = {}

					for arg = 1, info.nparams do
						local key, val = debug.getlocal(level, arg)

						if type(val) == "table" then
							val = tostring(val)
						else
							val = serializer.GetLibrary("luadata").ToString(val)

							if val and #val > 200 then val = val:sub(0, 200) .. "...." end
						end

						list.insert(args, ("%s = %s"):format(key, val))
					end

					info.arg_line = list.concat(args, ", ")
					info.name = info.name or "unknown"
					list.insert(data, info)
				else
					break
				end
			end

			local function resize_field(tbl, field)
				local length = 0

				for _, info in pairs(tbl) do
					local str = tostring(info[field])

					if str then
						if #str > length then length = #str end

						info[field] = str
					end
				end

				for _, info in pairs(tbl) do
					local str = info[field]

					if str then
						local diff = length - #str:split("\n")[1]

						if diff > 0 then info[field] = str .. (" "):rep(diff) end
					end
				end
			end

			list.insert(data, {source = "SOURCE:", name = "FUNCTION:", arg_line = " ARGUMENTS "})
			resize_field(data, "source")
			resize_field(data, "name")

			for _, info in list.reverse_ipairs(data) do
				logf("  %s   %s  (%s)\n", info.source, info.name, info.arg_line)
			end

			list.clear(data)
			logn("}")
			logn("LOCALS: ")
			logn("{")

			for _, param in pairs(debug.get_paramsx(4)) do
				--if not param.key:find("(",nil,true) then
				local val

				if type(param.val) == "table" then
					val = tostring(param.val)
				elseif type(param.val) == "string" then
					val = param.val:sub(0, 10)

					if val ~= param.val then
						val = val .. " .. " .. utility.FormatFileSize(#param.val)
					end
				else
					val = serializer.GetLibrary("luadata").ToString(param.val)
				end

				list.insert(data, {key = param.key, value = val})
			--end
			end

			list.insert(data, {key = "KEY:", value = "VALUE:"})
			resize_field(data, "key")
			resize_field(data, "value")

			for _, info in list.reverse_ipairs(data) do
				logf("  %s   %s\n", info.key, info.value)
			end

			logn("}")
			logn("ERROR:")
			logn("{")
			local source, _msg = msg:match("(.+): (.+)")

			if source then
				source = source:trim()
				local info = debug.getinfo(2)

				if info.source:starts_with("@") then info.source = info.source:sub(2) end

				logn("  ", info.source .. ":" .. info.currentline)
				logn("  ", _msg:trim())
			else
				logn(msg)
			end

			logn("}")
			logn("")
		end

		logfile.LogSection("lua error", false)
		suppress = false
	end

	function system.pcall(func, ...)
		return xpcall(func, system.OnError, ...)
	end
end

return system
