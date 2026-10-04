local vdf = library()

local function check_condition(cond)
	cond = cond:trim()
	local is_not = cond:starts_with("!")

	if is_not then cond = cond:sub(2):trim() end

	local os = cond:match("%$(.+)")

	if not os then return true end

	if os == "WIN32" or os == "WINDOWS" then
		os = "Windows"
	elseif os == "LINUX" then
		os = "Linux"
	elseif os == "OSX" then
		os = "OSX"
	elseif os == "POSIX" then
		os = "Posix,BSD"
	else
		os = "Other"
	end

	local res = os:find(jit.os, nil, true) ~= nil

	if is_not then return not res else return res end
end

local function eval_condition(expr)
	if expr:find("||", nil, true) then
		for part in expr:gmatch("[^|]+") do
			if eval_condition(part:trim()) then return true end
		end

		return false
	end

	if expr:find("&&", nil, true) then
		for part in expr:gmatch("[^&]+") do
			if not eval_condition(part:trim()) then return false end
		end

		return true
	end

	return check_condition(expr)
end

local function insert_key_value(current, key, val, lower_or_modify_keys)
	if lower_or_modify_keys then key = lower_or_modify_keys(key) end

	if key:find("+", nil, true) then
		for _, k in ipairs(key:split("+")) do
			insert_key_value(current, k, val, nil)
		end

		return
	end

	if current[key] == nil then
		current[key] = val
	else
		local existing = current[key]

		if type(existing) == "table" and existing[1] ~= nil then
			table.insert(existing, val)
		else
			current[key] = {existing, val}
		end
	end
end

local function lower_vmt_key(key)
	return (key:lower():gsub("%$", ""))
end

function vdf.Decode(data, key_mode, preprocess)
	local lower_or_modify_keys

	if key_mode == true then
		lower_or_modify_keys = string.lower
	elseif key_mode == "vmt" then
		lower_or_modify_keys = lower_vmt_key
	end

	local pos = 1
	local len = #data

	local function skip_whitespace()
		while pos <= len do
			local b = data:byte(pos)

			if not b then break end

			if b <= 32 then
				pos = pos + 1
			elseif b == 47 and data:byte(pos + 1) == 47 then
				pos = pos + 2

				while pos <= len and data:byte(pos) ~= 10 do
					pos = pos + 1
				end
			else
				break
			end
		end
	end

	local function read_token()
		skip_whitespace()

		if pos > len then return nil end

		local b = data:byte(pos)

		if b == 34 then
			pos = pos + 1
			local start = pos

			while pos <= len do
				if data:byte(pos) == 34 then
					local escaped = false
					local k = pos - 1

					while k >= start and data:byte(k) == 92 do
						escaped = not escaped
						k = k - 1
					end

					if not escaped then
						local s = data:sub(start, pos - 1)
						pos = pos + 1
						return s
					end
				end

				pos = pos + 1
			end

			return data:sub(start)
		end

		if b == 123 or b == 125 or b == 91 or b == 93 then
			pos = pos + 1
			return string.char(b)
		end

		local start = pos

		while pos <= len do
			local b2 = data:byte(pos)

			if not b2 or b2 <= 32 or b2 == 123 or b2 == 125 or b2 == 91 or b2 == 93 or b2 == 34 then
				break
			end

			if b2 == 47 and data:byte(pos + 1) == 47 then break end

			pos = pos + 1
		end

		return data:sub(start, pos - 1)
	end

	local function process_value(val)
		if type(val) ~= "string" then return val end

		if preprocess and val:find("|", nil, true) then
			for k, v in pairs(preprocess) do
				val = val:gsub("|" .. k .. "|", v)
			end
		end

		local lval = val:lower()

		if lval == "false" then
			return false
		elseif lval == "true" then
			return true
		end

		return tonumber(val) or val
	end

	local out = {}
	local current = out
	local stack = {out}
	local peeked = nil

	local function peek()
		if not peeked then peeked = read_token() end

		return peeked
	end

	local function consume()
		local t = peek()
		peeked = nil
		return t
	end

	while true do
		local key = consume()

		if not key then break end

		if key == "}" then
			if #stack > 1 then
				table.remove(stack)
				current = stack[#stack]
			else

			end
		else
			local next_t = peek()
			local condition_met = true

			if next_t == "[" then
				consume()
				local cond = ""

				while pos <= len do
					local c = data:sub(pos, pos)

					if c == "]" then
						pos = pos + 1

						break
					end

					cond = cond .. c
					pos = pos + 1
				end

				condition_met = eval_condition(cond)
				next_t = peek()
			end

			if next_t == "{" then
				consume()

				if condition_met then
					local new_table = {}
					insert_key_value(current, key, new_table, lower_or_modify_keys)
					table.insert(stack, new_table)
					current = new_table
				else
					local depth = 1

					while depth > 0 do
						local t = consume()

						if not t then break end

						if t == "{" then
							depth = depth + 1
						elseif t == "}" then
							depth = depth - 1
						end
					end
				end
			else
				local val = consume()

				if val == nil then break end

				if peek() == "[" then
					consume()
					local cond = ""

					while pos <= len do
						local c = data:sub(pos, pos)

						if c == "]" then
							pos = pos + 1

							break
						end

						cond = cond .. c
						pos = pos + 1
					end

					if not eval_condition(cond) then condition_met = false end
				end

				if condition_met then
					insert_key_value(current, key, process_value(val), lower_or_modify_keys)
				end
			end
		end
	end

	return out
end

vdf.thread_job = [[
	local input = ...
	return import("goluwa/codecs/vdf.lua").Decode(input.data, input.key_mode, input.preprocess)
]]

function vdf.DecodeJob(data, key_mode, preprocess)
	return import("goluwa/thread_pool.lua").Run(
		vdf.thread_job,
		{data = data, key_mode = key_mode, preprocess = preprocess},
		#data
	)
end

return vdf
