HOTRELOAD = false
local http = require("http")
local llamacpp = require("llamacpp")
local codec = require("codec")
local event = require("event")
local colors = require("helpers.colors")
local fs = require("fs")
local MODEL = "Qwen3.5-35B-A3B-UD-Q4_K_XL_2"
local PROMPT = "find all instances of TODO in lua files"
local SYSTEM = [[
	If you don't know the answer, use the tools to find it out. 
	Always use the tools when possible, even if you think you already know the answer. 
	Never say that you don't know something, instead say that you will find out using the tools.
]]
local tools = {
	glob = {
		description = [[Find files matching a glob pattern (e.g., '**/*.py', 'src/**/*.js'). 
			Returns file paths relative to the search directory, sorted alphabetically. 
			Use this instead of `bash find/ls` for locating files. Results are capped at 200 files.
		]],
		parameters = {
			type = "object",
			properties = {
				pattern = {
					type = "string",
					description = "Glob pattern (e.g., '**/*.py', 'tests/**/test_*.py')",
				},
				path = {
					type = "string",
					description = "Directory to search in (relative to workspace, default '.')",
				},
			},
			required = {"pattern"},
		},
		func = function(args)
			local pattern = args.pattern
			local search_path = args.path or "."
			local full_pattern = search_path .. "/" .. pattern
			full_pattern = full_pattern:gsub("^%./", "")
			local ok, files = pcall(fs.glob, full_pattern)

			if not ok then return "Error: " .. tostring(files) end

			if not files or #files == 0 then
				return "No files found matching the pattern."
			end

			table.sort(files)
			local cap = 200
			local total = #files
			local result_files = {}

			for i = 1, math.min(total, cap) do
				table.insert(result_files, files[i])
			end

			local output = table.concat(result_files, "\n")

			if total > cap then
				output = output .. string.format("\n... (%d more files, refine pattern to narrow results)", total - cap)
			else
				output = string.format("[%d files found]\n", total) .. output
			end

			return output
		end,
	},
	grep = {
		description = "Search file contents for a regex pattern using ripgrep. Returns matching lines with file paths and line numbers. Use this instead of `bash grep/rg` for searching code. Supports full regex syntax. Use glob_filter to restrict to specific file types (e.g., '*.py'). Results are capped at max_results (default 50).",
		parameters = {
			type = "object",
			properties = {
				pattern = {
					type = "string",
					description = "Regex pattern to search for",
				},
				path = {
					type = "string",
					description = "Directory or file to search in (relative to workspace, default '.')",
				},
				glob_filter = {
					type = "string",
					description = "Glob pattern to filter files (e.g., '*.py', '*.js')",
				},
				max_results = {
					type = "integer",
					description = "Maximum number of matching lines to return (default 50)",
				},
				context_lines = {
					type = "integer",
					description = "Number of context lines before and after each match (default 0)",
				},
			},
			required = {"pattern", "glob_filter", "context_lines"},
		},
		func = function(args)
			local pattern = args.pattern
			local path = args.path or "."
			local glob_filter = args.glob_filter
			local max_results = tonumber(args.max_results) or 50
			local context_lines = tonumber(args.context_lines) or 0
			local results, total = fs.grep(
				pattern,
				path,
				{
					glob_filter = glob_filter,
					max_results = max_results,
					context_lines = context_lines,
				}
			)

			if not results or #results == 0 then return "No matches found." end

			local output_lines = {}

			for _, m in ipairs(results) do
				table.insert(output_lines, m.file .. ":" .. m.line .. m.separator .. m.text)
			end

			local output = table.concat(output_lines, "\n")

			if total > max_results then
				output = output .. "\n... (" .. (
						total - max_results
					) .. " more matches, increase max_results to see)"
			end

			return output
		end,
	},
	bash = {
		description = "Execute a bash command in the workspace directory. Use this for running tests, installing packages, git operations, and other shell commands. Do NOT use bash for: reading files (use file_read), searching file contents (use grep), or finding files (use glob). Output is truncated to 30,000 characters.",
		parameters = {
			type = "object",
			properties = {
				command = {
					type = "string",
					description = "The bash command to execute",
				},
			},
			required = {"command"},
		},
		func = function(args)
			local command = args.command
			local cmd_lower = command:lower():trim()
			local process = require("bindings.process")
			local system = require("system")
			local ok, res = pcall(function()
				local p, err = process.spawn(
					{
						command = "bash",
						args = {"-c", command},
						stdout = "pipe",
						stderr = "pipe",
					}
				)

				if not p then error(err) end

				local stdout = {}
				local stderr = {}
				local start_time = system.GetTime()
				local timeout = 120

				while true do
					local out = p:read(4096)

					if out and out ~= "" then table.insert(stdout, out) end

					local err = p:read_err(4096)

					if err and err ~= "" then table.insert(stderr, err) end

					local exited, code = p:try_wait()

					if exited then
						return {
							stdout = table.concat(stdout),
							stderr = table.concat(stderr),
							code = code,
						}
					end

					if system.GetTime() - start_time > timeout then
						p:kill()
						error("command timed out after " .. timeout .. " seconds")
					end

					coroutine.yield()
				end
			end)

			if not ok then return "Error executing command: " .. tostring(res) end

			local output = ""

			if res.stdout then output = output .. res.stdout end

			if res.stderr then
				output = (output ~= "" and output .. "\n" or "") .. res.stderr
			end

			if res.code ~= 0 then
				output = (
						output ~= "" and
						output .. "\n" or
						""
					) .. "[Exit code: " .. tostring(res.code) .. "]"
			end

			if output:trim() == "" then
				return "Command executed successfully (no output)."
			end

			local MAX_CHARS = 30000

			if #output > MAX_CHARS then
				local half = math.floor(MAX_CHARS / 2)
				output = output:sub(1, half) .. "\n\n... [truncated " .. (
						#output - MAX_CHARS
					) .. " chars] ...\n\n" .. output:sub(-half)
			end

			return output
		end,
	},
	read_file = {
		description = "Reads a file from the filesystem. Output is paginated to 200 lines by default. If the result shows '(N lines below)', the file has more content — call again with offset set to the line after the last one shown to continue reading.",
		parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "File path relative to workspace root",
				},
				offset = {
					type = "integer",
					description = "1-indexed line number to start reading from. To paginate after a truncated read, pass the line number after the last one shown in the previous result. (default: 1)",
				},
				limit = {
					type = "integer",
					description = "Maximum number of lines to read per call. (default: 200)",
				},
			},
			required = {"path", "offset", "limit"},
		},
		func = function(args)
			local offset = math.max(tonumber(args.offset) or 1, 1) - 1
			local limit = math.max(tonumber(args.limit) or 200, 1)
			local content = assert(fs.read_file(args.path))
			local lines = content:split("\n")
			local total = #lines
			local start = offset
			local _end = math.min(offset + limit, total)
			local numbered = {}

			for i = start + 1, _end do
				local line = lines[i]

				if #line > 2000 then line = line:sub(1, 2000) .. "... [truncated]" end

				table.insert(numbered, string.format("%6d\t%s", i, line))
			end

			local result = string.format("[File: %s (%d lines total)]\n", args.path, total)

			if start > 0 then
				result = result .. string.format("... (%d lines above)\n", start)
			end

			result = result .. table.concat(numbered, "\n")

			if _end < total then
				result = result .. string.format(
						"\n... (%d lines below) — call read_file with offset=%d to continue",
						total - _end,
						_end + 1
					)
			end

			return result
		end,
	},
	file_edit = {
		description = [[
			Edit a file by replacing old_string with new_string.
			The old_string must appear exactly once in the file; if it appears
			multiple times, provide more surrounding context to make it unique.
			For Lua files, the edit is automatically checked for syntax errors
			and rolled back if invalid. Always read the file first before editing.
		]],
		parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "File path relative to workspace root",
				},
				old_string = {
					type = "string",
					description = "The exact string to find and replace",
				},
				new_string = {
					type = "string",
					description = "The replacement string",
				},
			},
			required = {"path"},
		},
		func = function(args)
			local content = assert(fs.read_file(args.path))
			local count = content:count(args.old_string)

			if count == 0 then error("old_string not found in " .. args.path) end

			if count > 1 then
				error(
					"old_string found " .. count .. " times in " .. args.path .. ". Provide more surrounding context to make it unique."
				)
			end

			local new_content = content:replace(args.old_string, args.new_string)

			-- Syntax check for Lua files
			if args.path:match("%.lua$") then
				local ok, err = loadstring(new_content, "@" .. args.path)

				if not ok then
					error(
						"Edit rolled back — syntax error detected:\n" .. tostring(err) .. "\nFix the syntax and try again."
					)
				end
			end

			assert(fs.write_file(args.path, new_content))
			return "Successfully edited " .. args.path
		end,
	},
	file_write = {
		description = "Write content to a file at the given path. Creates parent directories if needed. This overwrites the entire file. For small changes, prefer file_edit instead.",
		parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "File path relative to workspace root",
				},
				content = {
					type = "string",
					description = "Content to write to the file",
				},
			},
			required = {"path", "content"},
		},
		func = function(args)
			assert(fs.write_file(args.path, args.content))
			return "Successfully wrote to " .. args.path
		end,
	},
	lua = {
		description = [[
			- runs arbitrary luajit code.
		]],
		parameters = {
			type = "object",
			properties = {
				lua_code = {type = "string"},
			},
			required = {"lua_code"},
		},
		func = function(args)
			local output = {}
			local lua_context = {
				print = function(...)
					local args = {...}

					for i, v in ipairs(args) do
						args[i] = tostring(v)
					end

					table.insert(output, table.concat(args, "\t") .. "\n")
				end,
			}
			local header = {}

			for k, v in pairs(lua_context) do
				table.insert(header, string.format("local %s = ctx.%s", k, k))
			end

			header = "local ctx = ...; " .. table.concat(header, ";") .. "; "
			local name = header .. args.lua_code
			local fn, err = loadstring(header .. args.lua_code, name)

			if not fn then
				local fn2, err2 = loadstring(header .. "return " .. args.lua_code, name)

				if fn2 then
					fn = fn2
					err = err2
				end
			end

			if not fn then error("failed to load lua code: " .. tostring(err)) end

			local res = fn(lua_context)
			return {output = table.concat(output), result = res}
		end,
	},
}

local function run_tool(name, args)
	if not tools[name] then return "unknown tool: " .. tostring(name) end

	for k, v in pairs(tools[name].parameters.required) do
		if args[v] == nil then return "missing required argument: " .. k end
	end

	local ok, res = pcall(tools[name].func, args)

	do
		if name == "lua" then
			io.write(colors.yellow("tool-" .. name .. ":" .. args.lua_code .. "\n"))
		else
			io.write(colors.yellow("tool-" .. name .. ":" .. table.tostring(args) .. "\n"))
		end
	end

	if not ok then
		io.write(colors.red("<< " .. tostring(res) .. "\n"))
		return "error: " .. tostring(res)
	end

	res = table.tostring(res)
	io.write(colors.yellow("<< " .. res .. "\n"))
	return res
end

local available_tools = {}

for k, v in pairs(tools) do
	table.insert(
		available_tools,
		{
			type = "function",
			["function"] = {
				name = k,
				description = v.description,
				parameters = v.parameters,
			},
		}
	)
end

http.async(function()
	local active_tools = {}
	local messages = {
		{role = "system", content = SYSTEM},
		{role = "user", content = PROMPT},
	}
	local should_run = true

	while should_run do
		local res = llamacpp.ChatCompletion(
			{
				model = MODEL,
				temperature = 0.6,
				top_p = 0.95,
				top_k = 20,
				min_p = 0.0,
				--
				messages = messages,
				tools = available_tools,
				on_data = function(data)
					for _, choice in ipairs(data.choices) do
						if choice.delta.role then
							io.write(tostring(choice.delta.role) .. ":\n")
							io.flush()
						elseif choice.delta.content then
							io.write(tostring(choice.delta.content))
							io.flush()
						elseif choice.delta.reasoning_content then
							io.write(colors.dim(tostring(choice.delta.reasoning_content)))
							io.flush()
						elseif choice.delta.tool_calls then
							for _, tc in ipairs(choice.delta.tool_calls) do
								local idx = tc.index + 1

								if tc.id then
									active_tools[idx] = {
										id = tc.id,
										name = tc["function"].name,
										type = "function",
										arguments = tc["function"].arguments or "",
									}
									io.write(
										colors.yellow(
											"\n[Tool call: " .. tc["function"].name .. " with arguments: " .. (
													tc["function"].arguments or
													""
												)
										)
									)
								elseif tc["function"] then
									active_tools[idx].arguments = active_tools[idx].arguments .. tc["function"].arguments
									io.write(colors.yellow(tc["function"].arguments))
								else
									error("unknown tool type: " .. tostring(tc.type))
								end
							end
						elseif choice.finish_reason == "stop" then
							should_run = false
							io.write("\n[Finished]\n")
						elseif choice.finish_reason == "tool_calls" then
							io.write(colors.yellow("\n[Waiting for tools to finish...]\n"))
						-- this is done at the end of the loop
						else
							table.print(choice)
							error("unknown delta content")
						end
					end
				end,
			}
		)

		if #active_tools > 0 then
			local tool_calls = {}

			for _, tc in ipairs(active_tools) do
				table.insert(
					tool_calls,
					{
						id = tc.id,
						type = "function",
						["function"] = {name = tc.name, arguments = tc.arguments},
					}
				)
			end

			table.insert(messages, {role = "assistant", content = nil, tool_calls = tool_calls})

			for _, tc in ipairs(active_tools) do
				if tc.type == "function" then
					local args = codec.Decode("json", tc.arguments or "")
					local result = run_tool(tc.name, args)
					print(result)
					table.insert(
						messages,
						{
							role = "tool",
							tool_call_id = tc.id,
							content = result,
						}
					)
				else
					error("unknown tool type: " .. tostring(tc.type))
				end
			end
		end

		table.clear(active_tools)
	end

	io.write("\n")
	io.flush()
end) -- over here!