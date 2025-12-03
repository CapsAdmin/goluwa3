local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local get_mcode_calls = require("helpers.jit_mcode_stats")
local assert = _G.assert
local table_insert = _G.table.insert
local attach = _G.jit and _G.jit.attach
local traceinfo = jutil.traceinfo
local funcinfo = jutil.funcinfo
local ffnames = vmdef.ffnames
local traceerr = vmdef.traceerr
local bcnames = vmdef.bcnames

local function format_error(err--[[#: number]], arg--[[#: number | nil]])
	local fmt = traceerr[err]

	if not fmt then return "unknown error: " .. err end

	if not arg then return fmt end

	if fmt:sub(1, #"NYI: bytecode") == "NYI: bytecode" then
		local oidx = 6 * arg
		arg = bcnames:sub(oidx + 1, oidx + 6)
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
	trace_info = ReturnType<|traceinfo|>[1] ~ nil,
}]]

local function format_func_info(fi--[[#: ReturnType<|funcinfo|>[1] ]], func--[[#: Function]])
	if fi.loc and fi.currentline ~= 0 then
		local source = fi.source

		if source:sub(1, 1) == "@" then source = source:sub(2) end

		if source:sub(1, 2) == "./" then source = source:sub(3) end

		return source .. ":" .. fi.currentline
	elseif fi.ffid then
		return ffnames[fi.ffid]
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
	if not attach or not funcinfo or not traceinfo then return nil end

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
	local info = funcinfo(func, pc)
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
	trace.trace_info = assert(traceinfo(id), "invalid trace id: " .. id)
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
	trace.trace_info = assert(traceinfo(id), "invalid trace id: " .. id)
	trace.aborted = {
		code = code,
		reason = reason,
	}
	table_insert(trace.pc_lines, {func = func, pc = pc, depth = 0})
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
	attach(self._on_trace_event, "trace")
	self._on_record_event = function(tr, func, pc, depth)
		self_ref:_on_record(tr, func, pc, depth)
	end
	attach(self._on_record_event, "record")
end

function META:Stop()
	if not self._started then return end

	self._started = false
	attach(self._on_trace_event)
	attach(self._on_record_event)
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

		for i, pc_line in ipairs(trace.pc_lines) do
			local info = funcinfo(pc_line.func, pc_line.pc)
			local line = format_func_info(info, pc_line.func)

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
		end

		trace.lines = lines
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

	function META:GetReportProblematicTraces()
		local traces, aborted = self:GetReport()
		local map = {}

		for _, trace in ipairs(traces) do
			local linktype = trace.trace_info.linktype
			local nexit = trace.trace_info.nexit or 0
			-- Check for various problematic patterns
			local reason
			local stop_lines_only = false

			if linktype == "stitch" then
				-- Always problematic - should have been stitched
				stop_lines_only = true
			elseif linktype == "interpreter" and nexit > 100 then
				-- Hot exit to interpreter
				reason = "HOT_INTERP(exits:" .. nexit .. ")"
			elseif linktype == "none" then
				-- No continuation
				reason = "NO_LINK"
			elseif linktype == "return" and nexit > 100 then
				-- Frequently returning
				stop_lines_only = true -- limit to 10 lines
				reason = "HOT_RETURN(exits:" .. nexit .. ")"
			elseif linktype == "loop" and nexit > 1000 then
				-- Loop exiting frequently
				reason = "UNSTABLE_LOOP(exits:" .. nexit .. ")"
			end

			if reason then
				local res = tostring_trace(trace, traces) .. " - " .. reason .. ":\n" .. tostring_trace_lines_end(trace, " ")
				map[res] = (map[res] or 0) + 1
			end
		end

		for _, trace in ipairs(aborted) do
			local res = tostring_trace(trace, traces) .. ":\n" .. tostring_trace_lines_end(trace, " ")
			map[res] = (map[res] or 0) + 1
		end

		local sorted--[[#: List<|{line = string, count = number}|>]] = {}

		for k, v in pairs(map) do
			table.insert(sorted, {line = k, count = v})
		end

		table.sort(sorted, function(a, b)
			return a.count < b.count
		end)

		local out = {}

		for i, v in ipairs(sorted) do
			out[i] = v.line .. (v.count > 1 and (" (x" .. v.count .. ")") or "") .. "\n"
		end

		return table.concat(out, "\n")
	end
end

return TraceTrack
