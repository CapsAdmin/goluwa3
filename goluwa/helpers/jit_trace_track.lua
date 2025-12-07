local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local assert = _G.assert
local table = _G.table
local jit_attach = _G.jit.attach
local string = _G.string
local table_insert = table.insert
local callstack = require("helpers.callstack")
local trace_errors_reverse = {}

for code, fmt in pairs(vmdef.traceerr) do
	trace_errors_reverse[fmt] = code
end

local function format_error(err--[[#: number]], arg--[[#: number | nil]])
	local fmt = vmdef.traceerr[err]

	if not fmt then return "unknown error: " .. err end

	if not arg then return fmt end

	if fmt:sub(1, #"NYI: bytecode") == "NYI: bytecode" then
		local oidx = 6 * arg
		arg = vmdef.bcnames:sub(oidx + 1, oidx + 6)
		fmt = "NYI bytecode %s"
	end

	return string.format(fmt, arg)
end

local function create_warn_log(interval)
	local i = 0
	local last_time = 0
	return function()
		i = i + 1

		if last_time < os.clock() then
			last_time = os.clock() + interval
			return i, interval
		end

		return false
	end
end

--[[#local type Trace = {
	pc_lines = List<|{func = Function, depth = number, pc = number}|>,
	lines = List<|{line = string, depth = number}|>,
	id = number,
	exit_id = number,
	parent_id = number,
	parent = nil | self,
	DEAD = nil | true,
	stopped = nil | true,
	aborted = nil | {code = number, reason = number},
	children = nil | Map<|number, self|>,
	trace_info = ReturnType<|jutil.traceinfo|>[1] ~ nil,
	callstack = nil | string,
}]]

local function format_func_info(fi--[[#: ReturnType<|jutil.funcinfo|>[1] ]], func--[[#: Function]])
	if fi.loc and fi.currentline ~= 0 then
		local source = fi.source

		if source:sub(1, 1) == "@" then source = source:sub(2) end

		if source:sub(1, 2) == "./" then source = source:sub(3) end

		return source .. ":" .. fi.currentline
	elseif fi.ffid then
		return vmdef.ffnames[fi.ffid]
	elseif fi.addr then
		return string.format("C:%x, %s", fi.addr, tostring(func))
	else
		return "(?)"
	end
end

local TraceTrack = {}
local META = {}
META.__index = META

function TraceTrack.New()
	if not jit_attach or not jutil.funcinfo or not jutil.traceinfo then
		return nil
	end

	local self = setmetatable({}, META)
	self._started = false
	self._should_warn_mcode = create_warn_log(2)
	self._should_warn_abort = create_warn_log(8)
	self._traces = {}
	self._aborted = {}
	self._successfully_compiled = {}
	self._trace_count = 0
	self._on_trace_event = nil
	self._on_record_event = nil
	return self
end

function META:_get_trace_key(func, pc)
	local info = jutil.funcinfo(func, pc)
	return format_func_info(info, func)
end

function META:_on_start(
	id--[[#: number]],
	func--[[#: Function]],
	pc--[[#: number]],
	parent_id--[[#: nil | number]],
	exit_id--[[#: nil | number]]
)
	-- Don't clear aborted[id] here - aborted traces should persist until snapshot
	-- The trace ID being reused doesn't mean the old abort should be forgotten
	-- (filtering by source location happens in the snapshot function)
	-- TODO, both should be nil here
	local tr = {
		pc_lines = {{func = func, pc = pc, depth = 0}},
		id = id,
		exit_id = exit_id,
		parent_id = parent_id,
	}
	local parent = parent_id and self._traces[parent_id]

	if parent then
		tr.parent = parent
		parent.children = parent.children or {}
		parent.children[id] = tr
	else
		tr.parent_id = parent_id
	end

	self._traces[id] = tr
	self._trace_count = self._trace_count + 1
end

function META:_on_stop(id--[[#: number]], func--[[#: Function]])
	local trace = assert(self._traces[id])
	assert(trace.aborted == nil)
	trace.trace_info = assert(jutil.traceinfo(id), "invalid trace id: " .. id)
	trace.callstack = callstack.traceback("")
	-- Track by source location so we can filter out aborted traces that eventually succeeded
	local first_pc = trace.pc_lines[1]

	if first_pc then
		local key = self:_get_trace_key(first_pc.func, first_pc.pc)
		self._successfully_compiled[key] = true
	end
end

function META:_on_abort(
	id--[[#: number]],
	func--[[#: Function]],
	pc--[[#: number]],
	code--[[#: number]],
	reason--[[#: number]]
)
	local trace = assert(self._traces[id])
	assert(trace.stopped == nil)
	trace.trace_info = assert(jutil.traceinfo(id), "invalid trace id: " .. id)
	trace.aborted = {
		code = code,
		reason = reason,
	}
	table_insert(trace.pc_lines, {func = func, pc = pc, depth = 0})
	trace.callstack = callstack.traceback("")
	-- Key by source location so aborted traces persist even when trace IDs are reused
	local first_pc = trace.pc_lines[1]
	local key = first_pc and self:_get_trace_key(first_pc.func, first_pc.pc) or id
	self._aborted[key] = trace

	if trace.parent and trace.parent.children then
		trace.parent.children[id] = nil
	end

	trace.DEAD = true
	self._traces[id] = nil
	self._trace_count = self._trace_count - 1

	-- mcode allocation issues should be logged right away
	if code == 27 then
		local x, interval = self._should_warn_mcode()

		if x then
			io.write(
				format_error(code, reason),
				x == 0 and "" or " [" .. x .. " times the last " .. interval .. " seconds]",
				"\n"
			)
		end
	end
end

function META:_on_flush()
	if self._trace_count > 0 then
		local x, interval = self._should_warn_abort()

		if x then
			io.write(
				"flushing ",
				self._trace_count,
				" traces, ",
				(x == 0 and "" or "[" .. x .. " times the last " .. interval .. " seconds]"),
				"\n"
			)
		end
	end

	self._traces = {}
	self._aborted = {}
	self._successfully_compiled = {}
	self._trace_count = 0
end

function META:_on_record(tr--[[#: number]], func--[[#: Function]], pc--[[#: number]], depth--[[#: number]])
	assert(self._traces[tr])
	table_insert(self._traces[tr].pc_lines, {func = func, pc = pc, depth = depth})
end

function META:Start()
	if self._started then return end

	self._started = true
	local self_ref = self
	self._on_trace_event = function(what, tr, func, pc, otr, oex)
		if what == "start" then
			self_ref:_on_start(tr, func, pc, otr, oex)
		elseif what == "stop" then
			self_ref:_on_stop(tr, func)
		elseif what == "abort" then
			self_ref:_on_abort(tr, func, pc, otr, oex)
		elseif what == "flush" then
			self_ref:_on_flush()
		else
			error("unknown trace event " .. what)
		end
	end
	self._on_trace_event_safe = function(what, tr, func, pc, otr, oex)
		local ok, err = pcall(self._on_trace_event, what, tr, func, pc, otr, oex)

		if not ok then
			io.write("error in trace event: " .. tostring(err) .. "\n")
		end
	end
	jit_attach(self._on_trace_event_safe, "trace")
	self._on_record_event = function(tr, func, pc, depth)
		self_ref:_on_record(tr, func, pc, depth)
	end
	self._on_record_event_safe = function(tr, func, pc, depth)
		local ok, err = pcall(self._on_record_event, tr, func, pc, depth)

		if not ok then
			io.write("error in record event: " .. tostring(err) .. "\n")
		end
	end
	jit_attach(self._on_record_event_safe, "record")
end

function META:Stop()
	if not self._started then return end

	self._started = false
	jit_attach(self._on_trace_event)
	jit_attach(self._on_record_event)
end

function META:GetReport()
	-- Create snapshots to avoid mutating shared state
	local traces_snapshot = {}
	local aborted_snapshot = {}

	-- Deep copy traces
	for id, trace in pairs(self._traces) do
		if trace.trace_info then
			traces_snapshot[id] = {
				pc_lines = trace.pc_lines,
				id = trace.id,
				exit_id = trace.exit_id,
				parent_id = trace.parent_id,
				trace_info = trace.trace_info,
				aborted = trace.aborted,
				stopped = trace.stopped,
				DEAD = trace.DEAD,
				callstack = trace.callstack,
			}
		end
	end

	-- Deep copy aborted
	for id, trace in pairs(self._aborted) do
		-- Skip if it was eventually successfully traced at the same source location
		local first_pc = trace.pc_lines[1]
		local key = first_pc and self:_get_trace_key(first_pc.func, first_pc.pc)

		if not key or not self._successfully_compiled[key] then
			aborted_snapshot[id] = {
				pc_lines = trace.pc_lines,
				id = trace.id,
				exit_id = trace.exit_id,
				parent_id = trace.parent_id,
				trace_info = trace.trace_info,
				aborted = trace.aborted,
				stopped = trace.stopped,
				DEAD = trace.DEAD,
				callstack = trace.callstack,
			}
		end
	end

	-- Rebuild parent/children relationships on snapshots
	for id, trace in pairs(traces_snapshot) do
		local parent = trace.parent_id and traces_snapshot[trace.parent_id]

		if parent then
			trace.parent = parent
			parent.children = parent.children or {}
			parent.children[id] = trace
		end
	end

	-- Convert children maps to sorted arrays
	for id, trace in pairs(traces_snapshot) do
		if trace.children then
			local new = {}

			for k, v in pairs(trace.children) do
				table.insert(new, v)
			end

			table.sort(new, function(a, b)
				return a.exit_id < b.exit_id
			end)

			trace.children = new
		end
	end

	local cache = {}

	local function get_code(loc--[[#: string]])
		if cache[loc] ~= nil then return cache[loc] end

		local start, stop = loc:find(":")

		if not start then
			cache[loc] = false
			return nil
		end

		local path = loc:sub(1, start - 1)
		local line = tonumber(loc:sub(stop + 1))
		local f = io.open(path, "r")

		if not f then
			cache[loc] = false
			return nil
		end

		local i = 1

		for line_str in f:lines() do
			if i == line then
				f:close()
				cache[loc] = line_str:match("^%s*(.-)%s*$") or line_str
				return cache[loc]
			end

			i = i + 1
		end

		f:close()
		cache[loc] = false
		return nil
	end

	local function unpack_lines(trace--[[#: Trace]])
		local lines = {}
		local done = {}
		local lines_i = 1
		-- Also build a callstack-style representation
		local current_at_depth = {} -- Track the most recent line at each depth level
		for i, pc_line in ipairs(trace.pc_lines) do
			local info = jutil.funcinfo(pc_line.func, pc_line.pc)
			local line = format_func_info(info, pc_line.func)
			local depth = pc_line.depth

			if not done[line] then
				done[line] = true
				lines[lines_i] = {
					line = line,
					--code = get_code(line),
					depth = pc_line.depth,
					is_path = info.loc ~= nil,
				}
				lines_i = lines_i + 1
			end

			-- Track current position at this depth for callstack reconstruction
			current_at_depth[depth] = {
				line = line,
				depth = depth,
				is_path = info.loc ~= nil,
			}

			-- Clear deeper levels when we return to a shallower depth
			for d = depth + 1, #current_at_depth do
				current_at_depth[d] = nil
			end
		end

		trace.lines = lines
		-- Build final callstack (deepest first, like a traceback)
		local callstack_lines = {}
		local max_depth = 0

		for d in pairs(current_at_depth) do
			if d > max_depth then max_depth = d end
		end

		for d = max_depth, 0, -1 do
			if current_at_depth[d] then
				table.insert(callstack_lines, current_at_depth[d])
			end
		end

		trace.callstack_lines = callstack_lines
	end

	-- Unpack lines for all snapshot traces
	for id, trace in pairs(traces_snapshot) do
		unpack_lines(trace)
	end

	for id, trace in pairs(aborted_snapshot) do
		unpack_lines(trace)
	end

	local traces_sorted = {}
	local aborted_sorted = {}

	for _, trace in pairs(traces_snapshot) do
		table_insert(traces_sorted, trace)
	end

	for _, trace in pairs(aborted_snapshot) do
		table_insert(aborted_sorted, trace)
	end

	table.sort(traces_sorted, function(a, b)
		return a.id < b.id
	end)

	table.sort(aborted_sorted, function(a, b)
		return a.id < b.id
	end)

	return traces_sorted, aborted_sorted
end

do
	local function tostring_trace_lines_end(trace--[[#: Trace]], line_prefix--[[#: nil | string]])
		if not trace.lines then return "HUH" end

		line_prefix = line_prefix or ""
		local lines = {}
		local start_depth = assert(trace.lines[#trace.lines]).depth

		for i = #trace.lines, 1, -1 do
			local line = trace.lines[i]
			table.insert(lines, 1, line_prefix .. line.line)

			if line.depth ~= start_depth then break end
		end

		return table.concat(lines, "\n")
	end

	local function tostring_trace(trace--[[#: Trace]], traces--[[#: Map<|number, Trace|>]])
		local str = ""
		local link = trace.trace_info.linktype

		if link == "root" then
			local link_node = traces[trace.trace_info.link]

			if link_node then
				link = "link > [" .. link_node.id .. "]"
			else
				link = "link > [" .. trace.trace_info.link .. "?]"
			end
		end

		if trace.aborted then
			str = str .. "ABORTED: " .. format_error(trace.aborted.code, trace.aborted.reason)
		else
			str = str .. link
		end

		return str
	end

	local function tostring_trace_lines_full(trace--[[#: Trace]], tab--[[#: nil | string]], line_prefix--[[#: nil | string]])
		line_prefix = line_prefix or ""
		tab = tab or ""
		local lines = {}

		for i, line in ipairs(trace.lines) do
			lines[i] = line_prefix .. (i == 1 and "" or tab) .. (" "):rep(line.depth) .. line.line
		end

		local max_len = 0

		for i, line in ipairs(lines) do
			if #line > max_len then max_len = #line end
		end

		for i, line in ipairs(lines) do
			if trace.lines[i].code then
				lines[i] = lines[i] .. (" "):rep(max_len - #line + 2) .. " -- " .. trace.lines[i].code
			end
		end

		return table.concat(lines, "\n")
	end

	-- Format pc_lines as a callstack, showing function entry points
	-- This is useful when callstack.traceback doesn't capture the full context
	local function tostring_trace_callstack(trace--[[#: Trace]], line_prefix--[[#: nil | string]])
		line_prefix = line_prefix or ""
		local callstack_lines = trace.callstack_lines

		if not callstack_lines or #callstack_lines == 0 then return "" end

		-- Format output similar to a traceback (deepest first)
		local lines = {}

		for i, entry in ipairs(callstack_lines) do
			local indent = (" "):rep(i - 1)
			lines[i] = line_prefix .. indent .. entry.line
		end

		return table.concat(lines, "\n")
	end

	local function format_traces(traces, filter)
		local tracebacks = {}
		local found = {}

		for _, trace in ipairs(traces) do
			if filter(trace) then
				table.insert(tracebacks, trace.callstack)
				table.insert(found, trace)
			end
		end

		local prefix, suffix = string.strip_common_prefix_suffix(tracebacks)

		for _, trace in ipairs(found) do
			local traceback = trace.callstack:sub(prefix + 1, #trace.callstack - suffix)
			local formatted = table.concat(callstack.format(traceback), "\n")

			-- If the formatted callstack is empty or too short (e.g., all tracebacks were identical
			-- and got stripped away, or only module-level), fall back to pc_lines callstack
			if #formatted < 10 or not formatted:find("\n") then
				local pc_callstack = tostring_trace_callstack(trace)

				if pc_callstack and #pc_callstack > 0 then
					formatted = pc_callstack
				end
			end

			-- If we still have nothing useful but have callstack_lines, use them directly
			if (#formatted < 5 or formatted == "") and trace.callstack_lines and #trace.callstack_lines > 0 then
				local lines = {}
				for i, entry in ipairs(trace.callstack_lines) do
					lines[i] = entry.line
				end
				formatted = table.concat(lines, "\n")
			end

			trace.callstack = formatted
		end
	end

	function META:GetReportProblematicTraces()
		local traces, aborted = self:GetReport()

		format_traces(traces, function(trace)
			return trace.callstack and trace.trace_info.linktype == "stitch"
		end)

		format_traces(aborted, function(trace)
			return trace.callstack
		end)

		-- Group by category -> location -> reason -> path -> count
		-- Categories: "stitch", "aborted", "other"
		local by_category = {
			stitch = {},
			aborted = {},
			other = {},
		}

		local function add_issue(category, trace, reason)
			if not trace.lines or #trace.lines == 0 then return end

			local start_line = trace.lines[1].line
			local path = ""

			if trace.callstack then
				local lines = trace.callstack

				if lines and #lines > 0 then path = lines end
			end

			local by_location = by_category[category]
			by_location[start_line] = by_location[start_line] or {}
			by_location[start_line][reason] = by_location[start_line][reason] or {}
			by_location[start_line][reason][path] = (by_location[start_line][reason][path] or 0) + 1
		end

		for _, trace in ipairs(traces) do
			local linktype = trace.trace_info.linktype
			local nexit = trace.trace_info.nexit or 0
			local reason
			local category = "other"

			if linktype == "stitch" then
				reason = ""
				category = "stitch"
			elseif linktype == "interpreter" and nexit > 100 then
				reason = "HOT_INTERP(exits:" .. nexit .. ")"
			elseif linktype == "none" then
				reason = "NO_LINK"
			elseif linktype == "return" and nexit > 100 then
				reason = "HOT_RETURN(exits:" .. nexit .. ")"
			elseif linktype == "loop" and nexit > 1000 then
				reason = "UNSTABLE_LOOP(exits:" .. nexit .. ")"
			end

			if reason then add_issue(category, trace, reason) end
		end

		local R = function(s)
			return assert(trace_errors_reverse[s])
		end
		-- Abort codes to filter out completely (normal retry behavior)
		local filter_codes = {
			[R("retry recording")] = true, -- retry recording
			[R("leaving loop in root trace")] = true, -- leaving loop in root trace
			[R("inner loop in root trace")] = true, -- inner loop in root trace
			[R("down-recursion, restarting")] = true, -- down-recursion, restarting
		}
		-- Abort codes to aggregate as summary counts (resource limits)
		local aggregate_codes = {
			[R("too many snapshots")] = true, -- too many snapshots
			[R("loop unroll limit reached")] = true, -- loop unroll limit reached
			[R("failed to allocate mcode memory")] = true, -- failed to allocate mcode memory
			[R("blacklisted")] = true, -- blacklisted function, just report aggregate because it's caused by other abort reasons
		}
		local aggregate_counts = {}

		for _, trace in ipairs(aborted) do
			local code = trace.aborted.code

			if filter_codes[code] then

			-- Skip entirely
			elseif aggregate_codes[code] then
				-- Just count
				aggregate_counts[code] = (aggregate_counts[code] or 0) + 1
			else
				local reason = format_error(code, trace.aborted.reason)
				add_issue("aborted", trace, reason)
			end
		end

		local function build_output_for_locations(by_location)
			-- Sort locations by total issue count
			local sorted_locations = {}

			for loc, reasons in pairs(by_location) do
				local total = 0

				for _, paths in pairs(reasons) do
					for _, count in pairs(paths) do
						total = total + count
					end
				end

				table.insert(sorted_locations, {location = loc, reasons = reasons, total = total})
			end

			table.sort(sorted_locations, function(a, b)
				return a.total > b.total
			end)

			local out = {}

			for _, loc_entry in ipairs(sorted_locations) do
				table.insert(out, loc_entry.location .. " (" .. loc_entry.total .. " issues):\n")
				-- Sort reasons by count within this location
				local sorted_reasons = {}

				for reason, paths in pairs(loc_entry.reasons) do
					local reason_total = 0

					for _, count in pairs(paths) do
						reason_total = reason_total + count
					end

					table.insert(sorted_reasons, {reason = reason, paths = paths, total = reason_total})
				end

				table.sort(sorted_reasons, function(a, b)
					return a.total > b.total
				end)

				for _, reason_entry in ipairs(sorted_reasons) do
					if reason_entry.reason ~= "" then
						table.insert(out, "  " .. reason_entry.reason .. ":\n")
					end

					-- Sort paths by count
					local sorted_paths = {}

					for path, count in pairs(reason_entry.paths) do
						table.insert(sorted_paths, {path = path, count = count})
					end

					table.sort(sorted_paths, function(a, b)
						return a.count > b.count
					end)

					for _, path_entry in ipairs(sorted_paths) do
						local count_str = path_entry.count > 1 and (" (x" .. path_entry.count .. ")") or ""

						if path_entry.path ~= "" then
							-- Indent each line of the path
							local indented = path_entry.path:gsub("([^\n]+)", "      %1")
							table.insert(out, indented .. count_str .. "\n")
						else
							table.insert(out, "    (no additional path)" .. count_str .. "\n")
						end
					end
				end

				table.insert(out, "\n")
			end

			return table.concat(out)
		end

		local out = {}

		-- Show resource limit summary first
		if next(aggregate_counts) then
			table.insert(out, "=== RESOURCE LIMITS ===\n\n")

			if aggregate_counts[R("too many snapshots")] then
				table.insert(
					out,
					"  too many snapshots: " .. aggregate_counts[R("too many snapshots")] .. " traces (consider increasing maxsnap)\n"
				)
			end

			if aggregate_counts[R("loop unroll limit reached")] then
				table.insert(
					out,
					"  loop unroll limit reached: " .. aggregate_counts[R("loop unroll limit reached")] .. " traces (consider increasing maxunroll)\n"
				)
			end

			if aggregate_counts[R("failed to allocate mcode memory")] then
				table.insert(
					out,
					"  failed to allocate mcode memory: " .. aggregate_counts[R("failed to allocate mcode memory")] .. " traces (consider increasing maxmcode)\n"
				)
			end

			if aggregate_counts[R("blacklisted")] then
				table.insert(
					out,
					"  blacklisted function: " .. aggregate_counts[R("blacklisted")] .. " traces\n"
				)
			end

			table.insert(out, "\n")
		end

		if next(by_category.aborted) then
			table.insert(out, "=== ABORTED ===\n\n")
			table.insert(out, build_output_for_locations(by_category.aborted))
		end

		if next(by_category.stitch) then
			table.insert(out, "=== STITCH ===\n\n")
			table.insert(out, build_output_for_locations(by_category.stitch))
		end

		if next(by_category.other) then
			table.insert(out, "=== OTHER ===\n\n")
			table.insert(out, build_output_for_locations(by_category.other))
		end

		return table.concat(out)
	end
end

return TraceTrack
