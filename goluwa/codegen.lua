local codegen = {}
local callstack = import("goluwa/debug/callstack.lua")

function codegen.join(list, sep, transform)
	return {kind = "join", list = list, sep = sep or ", ", transform = transform}
end

function codegen.each(list, sep, transform)
	-- transform(element, default_line) -> line to emit
	return {kind = "each", list = list, sep = sep or ", ", transform = transform}
end

local function get_text(spec, element)
	return spec.transform and spec.transform(element) or element
end

local function join_text(spec)
	if not spec._text then
		local str = ""
		local count = #spec.list

		for i, element in ipairs(spec.list) do
			str = str .. get_text(spec, element)

			if i ~= count then str = str .. spec.sep end
		end

		spec._text = str
	end

	return spec._text
end

local function substitute_inline(line, env, forced)
	local out = ""
	local rest = line

	while true do
		local s, e = rest:find("{{", 1, true)

		if not s then
			out = out .. rest

			break
		end

		local close = rest:find("}}", e, true)

		if not close then error("codegen: unclosed token in line: " .. line, 3) end

		local name = rest:sub(s + 2, close - 1)
		local text

		if forced and name == forced.name then
			text = forced.text
		else
			local value = env[name]

			if not value then
				error("codegen: no env value for token \"{{" .. name .. "}}\" in line: " .. line, 3)
			end

			if type(value) == "table" and value.kind == "each" then
				error("codegen: a line can only contain one each token: " .. line, 3)
			end

			text = type(value) == "table" and value.kind == "join" and join_text(value) or value
		end

		out = out .. rest:sub(1, s - 1) .. text
		rest = rest:sub(close + 2)
	end

	return out
end

local function render_line(line, env)
	local each_name, each_value

	for name, value in pairs(env) do
		if
			type(value) == "table" and
			value.kind == "each" and
			line:find("{{" .. name .. "}}", 1, true)
		then
			each_name = name
			each_value = value

			break
		end
	end

	if not each_name then return substitute_inline(line, env, nil) end

	local count = #each_value.list
	local str = ""

	for i, element in ipairs(each_value.list) do
		local default = substitute_inline(line, env, {name = each_name, text = element})
		local out = each_value.transform and each_value.transform(element, default) or default
		str = str .. out

		if i ~= count then str = str .. each_value.sep end

		str = str .. "\n"
	end

	return str
end

function codegen.render(template, env)
	local lines = {}

	for _, line in ipairs(template:split("\n")) do
		lines[#lines + 1] = render_line(line, env)
	end

	return table.concat(lines, "\n")
end

local chunks = {}

function codegen.compile(source, label)
	local chunk = chunks[source]

	if not chunk then
		local name = "@" .. (callstack.get_line(2) or "codegen") .. " - " .. (label or "codegen")
		chunk = assert(loadstring(source, name))
		chunks[source] = chunk
	end

	return chunk
end

function codegen.run(template, label, env, ...)
	return codegen.compile(codegen.render(template, env or {}), label)(...)
end

return codegen
