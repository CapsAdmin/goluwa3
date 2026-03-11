local jinja2 = library()
local json = require("codecs.json")
local openers = {
	{open = "{%", close = "%}", type = "statement"},
	{open = "{{", close = "}}", type = "expression"},
	{open = "{#", close = "#}", type = "comment"},
}

function jinja2.tokenize(str)
	local tokens = {}
	local pos = 1
	local len = #str

	while pos <= len do
		-- find earliest opening delimiter
		local best_pos, best_info

		for _, info in ipairs(openers) do
			local s = str:find(info.open, pos, true)

			if s and (not best_pos or s < best_pos) then
				best_pos = s
				best_info = info
			end
		end

		if not best_pos then
			tokens[#tokens + 1] = {type = "text", value = str:sub(pos)}

			break
		end

		-- text before delimiter
		if best_pos > pos then
			tokens[#tokens + 1] = {type = "text", value = str:sub(pos, best_pos - 1)}
		end

		-- check for trim marker after opening delimiter (e.g. {%- or {{-)
		local trim_left = str:sub(best_pos + 2, best_pos + 2) == "-"
		local content_start = best_pos + 2 + (trim_left and 1 or 0)
		-- find closing delimiter
		local close_pos = str:find(best_info.close, content_start, true)

		if not close_pos then
			-- unclosed delimiter, treat rest as text
			tokens[#tokens + 1] = {type = "text", value = str:sub(best_pos)}

			break
		end

		-- check for trim marker before closing delimiter (e.g. -%} or -}})
		local trim_right = str:sub(close_pos - 1, close_pos - 1) == "-"
		local content_end = close_pos - 1 - (trim_right and 1 or 0)
		local content = str:sub(content_start, content_end)

		-- trim_left: strip trailing whitespace from previous text token
		if trim_left and #tokens > 0 and tokens[#tokens].type == "text" then
			tokens[#tokens].value = tokens[#tokens].value:gsub("%s+$", "")

			if tokens[#tokens].value == "" then table.remove(tokens) end
		end

		-- add token (skip comments)
		if best_info.type ~= "comment" then
			tokens[#tokens + 1] = {type = best_info.type, value = content}
		end

		pos = close_pos + #best_info.close

		-- trim_right: skip leading whitespace after closing delimiter
		if trim_right then
			local _, ws_end = str:find("^%s+", pos)

			if ws_end then pos = ws_end + 1 end
		end
	end

	return tokens
end

----------------------------------------------------------------
-- Expression lexer
----------------------------------------------------------------
local KEYWORDS = {
	["and"] = true,
	["or"] = true,
	["not"] = true,
	["is"] = true,
	["in"] = true,
	["if"] = true,
	["else"] = true,
	["true"] = true,
	["false"] = true,
	["True"] = true,
	["False"] = true,
	["none"] = true,
	["None"] = true,
}

local function lex_expression(str)
	local tokens = {}
	local pos = 1
	local len = #str

	while pos <= len do
		-- skip whitespace
		local _, ws_end = str:find("^%s+", pos)

		if ws_end then
			pos = ws_end + 1

			if pos > len then break end
		end

		local c = str:sub(pos, pos)

		-- string literal
		if c == "'" or c == "\"" then
			local quote = c
			local start = pos
			pos = pos + 1
			local parts = {}

			while pos <= len do
				local ch = str:sub(pos, pos)

				if ch == "\\" then
					pos = pos + 1

					if pos <= len then
						local esc = str:sub(pos, pos)

						if esc == "n" then
							parts[#parts + 1] = "\n"
						elseif esc == "t" then
							parts[#parts + 1] = "\t"
						elseif esc == "\\" then
							parts[#parts + 1] = "\\"
						elseif esc == quote then
							parts[#parts + 1] = quote
						else
							parts[#parts + 1] = "\\" .. esc
						end

						pos = pos + 1
					end
				elseif ch == quote then
					pos = pos + 1

					break
				else
					parts[#parts + 1] = ch
					pos = pos + 1
				end
			end

			tokens[#tokens + 1] = {type = "string", value = table.concat(parts)}
		elseif c:match("[%d]") then
			-- number
			local s, e = str:find("^[%d%.]+", pos)
			tokens[#tokens + 1] = {type = "number", value = str:sub(s, e)}
			pos = e + 1
		elseif c:match("[%a_]") then
			-- identifier or keyword
			local s, e = str:find("^[%a_][%w_]*", pos)
			local word = str:sub(s, e)

			if KEYWORDS[word] then
				tokens[#tokens + 1] = {type = "keyword", value = word}
			else
				tokens[#tokens + 1] = {type = "ident", value = word}
			end

			pos = e + 1
		elseif c == "(" then
			tokens[#tokens + 1] = {type = "lparen"}
			pos = pos + 1
		elseif c == ")" then
			tokens[#tokens + 1] = {type = "rparen"}
			pos = pos + 1
		elseif c == "[" then
			-- check for [::-1]
			if str:sub(pos, pos + 3) == "[::-" then
				local e2 = str:find("]", pos + 4, true)

				if e2 then
					local step = str:sub(pos + 3, e2 - 1)
					tokens[#tokens + 1] = {type = "slice", value = step}
					pos = e2 + 1
				else
					tokens[#tokens + 1] = {type = "lbracket"}
					pos = pos + 1
				end
			else
				tokens[#tokens + 1] = {type = "lbracket"}
				pos = pos + 1
			end
		elseif c == "]" then
			tokens[#tokens + 1] = {type = "rbracket"}
			pos = pos + 1
		elseif c == "," then
			tokens[#tokens + 1] = {type = "comma"}
			pos = pos + 1
		elseif c == "." then
			tokens[#tokens + 1] = {type = "dot"}
			pos = pos + 1
		elseif c == "~" then
			tokens[#tokens + 1] = {type = "op", value = "~"}
			pos = pos + 1
		elseif c == "+" then
			tokens[#tokens + 1] = {type = "op", value = "+"}
			pos = pos + 1
		elseif c == "-" then
			tokens[#tokens + 1] = {type = "op", value = "-"}
			pos = pos + 1
		elseif c == "*" then
			tokens[#tokens + 1] = {type = "op", value = "*"}
			pos = pos + 1
		elseif c == "/" then
			tokens[#tokens + 1] = {type = "op", value = "/"}
			pos = pos + 1
		elseif c == "%" then
			tokens[#tokens + 1] = {type = "op", value = "%"}
			pos = pos + 1
		elseif c == "|" then
			tokens[#tokens + 1] = {type = "pipe"}
			pos = pos + 1
		elseif c == "=" and str:sub(pos + 1, pos + 1) == "=" then
			tokens[#tokens + 1] = {type = "op", value = "=="}
			pos = pos + 2
		elseif c == "!" and str:sub(pos + 1, pos + 1) == "=" then
			tokens[#tokens + 1] = {type = "op", value = "!="}
			pos = pos + 2
		elseif c == "=" then
			tokens[#tokens + 1] = {type = "assign"}
			pos = pos + 1
		elseif c == ">" and str:sub(pos + 1, pos + 1) == "=" then
			tokens[#tokens + 1] = {type = "op", value = ">="}
			pos = pos + 2
		elseif c == "<" and str:sub(pos + 1, pos + 1) == "=" then
			tokens[#tokens + 1] = {type = "op", value = "<="}
			pos = pos + 2
		elseif c == ">" then
			tokens[#tokens + 1] = {type = "op", value = ">"}
			pos = pos + 1
		elseif c == "<" then
			tokens[#tokens + 1] = {type = "op", value = "<"}
			pos = pos + 1
		else
			error(
				"jinja2: unexpected character in expression: " .. c .. " near '" .. str:sub(pos, pos + 20) .. "'"
			)
		end
	end

	return tokens
end

jinja2.lex_expression = lex_expression

----------------------------------------------------------------
-- Expression transpiler (token stream -> Lua source)
----------------------------------------------------------------
-- Escape a string for embedding in Lua source as a double-quoted literal
local function lua_quote(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub("\"", "\\\"")
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	s = s:gsub("%z", "\\0")
	return "\"" .. s .. "\""
end

local function transpile_expression(expr_str)
	local toks = lex_expression(expr_str)
	local pos = 1
	local out = {}

	local function peek(offset)
		return toks[pos + (offset or 0)]
	end

	local function advance()
		local t = toks[pos]
		pos = pos + 1
		return t
	end

	local function emit(s)
		out[#out + 1] = s
	end

	-- forward declarations
	local parse_expr, parse_ternary, parse_or, parse_and, parse_not, parse_comparison, parse_addition, parse_concat, parse_unary, parse_postfix, parse_primary

	-- expr = ternary
	function parse_expr()
		return parse_ternary()
	end

	-- ternary: or_expr [ 'if' or_expr 'else' or_expr ]
	-- This is parsed specially: A if COND else B
	-- But we parse left-to-right: first parse A (which is or_expr),
	-- then if we see 'if' keyword, parse condition and else branch
	function parse_ternary()
		local start = #out + 1
		parse_or()

		if peek() and peek().type == "keyword" and peek().value == "if" then
			advance() -- consume 'if'
			local value_part = table.concat(out, "", start)

			-- remove the value part from output
			for i = #out, start, -1 do
				out[i] = nil
			end

			-- parse condition
			local cond_start = #out + 1
			parse_or()
			local cond_part = table.concat(out, "", cond_start)

			for i = #out, cond_start, -1 do
				out[i] = nil
			end

			-- expect 'else'
			if peek() and peek().type == "keyword" and peek().value == "else" then
				advance()
				local else_start = #out + 1
				parse_ternary() -- recursive for chaining
				local else_part = table.concat(out, "", else_start)

				for i = #out, else_start, -1 do
					out[i] = nil
				end

				emit("__ternary(" .. cond_part .. ", " .. value_part .. ", " .. else_part .. ")")
			else
				-- no else branch, use nil
				emit("__ternary(" .. cond_part .. ", " .. value_part .. ", nil)")
			end
		end
	end

	function parse_or()
		parse_and()

		while peek() and peek().type == "keyword" and peek().value == "or" do
			advance()
			emit(" or ")
			parse_and()
		end
	end

	function parse_and()
		parse_not()

		while peek() and peek().type == "keyword" and peek().value == "and" do
			advance()
			emit(" and ")
			parse_not()
		end
	end

	function parse_not()
		if peek() and peek().type == "keyword" and peek().value == "not" then
			advance()

			-- check for not(...)
			if peek() and peek().type == "lparen" then
				emit("not ")
				parse_not()
			else
				emit("not ")
				parse_not()
			end
		else
			parse_comparison()
		end
	end

	-- is-test names to Lua runtime calls
	local is_tests = {
		string = "(__type(%s) == 'string')",
		iterable = "(__is_iterable(%s))",
		mapping = "(__is_mapping(%s))",
		sequence = "(__is_sequence(%s))",
		none = "(%s == nil)",
		undefined = "(%s == nil)",
		defined = "(%s ~= nil)",
		["false"] = "(%s == false)",
		["true"] = "(%s == true)",
		number = "(__type(%s) == 'number')",
	}

	function parse_comparison()
		local start = #out + 1
		parse_addition()

		while true do
			local t = peek()

			if not t then break end

			if
				t.type == "op" and
				(
					t.value == "==" or
					t.value == "!=" or
					t.value == "<" or
					t.value == ">" or
					t.value == "<=" or
					t.value == ">="
				)
			then
				advance()

				if t.value == "!=" then
					emit(" ~= ")
				else
					emit(" " .. t.value .. " ")
				end

				parse_addition()
				-- after a binary comparison, consolidate everything as new left operand
				local consolidated = table.concat(out, "", start)

				for i = #out, start, -1 do
					out[i] = nil
				end

				emit(consolidated)
			elseif t.type == "keyword" and t.value == "is" then
				advance()
				-- check for 'is not'
				local negated = false

				if peek() and peek().type == "keyword" and peek().value == "not" then
					advance()
					negated = true
				end

				-- get the test name
				local test_tok = advance()
				local test_name

				if test_tok.type == "ident" or test_tok.type == "keyword" then
					test_name = test_tok.value
				else
					error("jinja2: expected test name after 'is', got " .. test_tok.type)
				end

				-- extract the full subject from output
				local subject = table.concat(out, "", start)

				for i = #out, start, -1 do
					out[i] = nil
				end

				local pattern = is_tests[test_name]

				if not pattern then error("jinja2: unknown is-test: " .. test_name) end

				local result = pattern:format(subject)

				if negated then
					emit("(not " .. result .. ")")
				else
					emit(result)
				end
			elseif t.type == "keyword" and t.value == "in" then
				advance()
				-- 'x in y' -> __contains(y, x)
				local subject = table.concat(out, "", start)

				for i = #out, start, -1 do
					out[i] = nil
				end

				local container_start = #out + 1
				parse_addition()
				local container = table.concat(out, "", container_start)

				for i = #out, container_start, -1 do
					out[i] = nil
				end

				emit("__contains(" .. container .. ", " .. subject .. ")")
			elseif t.type == "keyword" and t.value == "not" then
				-- 'not in' check
				if toks[pos + 1] and toks[pos + 1].type == "keyword" and toks[pos + 1].value == "in" then
					advance() -- not
					advance() -- in
					local subject = table.concat(out, "", start)

					for i = #out, start, -1 do
						out[i] = nil
					end

					local container_start = #out + 1
					parse_addition()
					local container = table.concat(out, "", container_start)

					for i = #out, container_start, -1 do
						out[i] = nil
					end

					emit("(not __contains(" .. container .. ", " .. subject .. "))")
				else
					break
				end
			else
				break
			end

			-- update start for chaining
			start = #out
		end
	end

	function parse_addition()
		local start = #out + 1
		parse_concat()

		while peek() and peek().type == "op" and (peek().value == "+" or peek().value == "-") do
			local op = advance()
			local left = table.concat(out, "", start)

			for i = #out, start, -1 do
				out[i] = nil
			end

			parse_concat()
			local right = table.concat(out, "", start)

			for i = #out, start, -1 do
				out[i] = nil
			end

			if op.value == "+" then
				emit("__add(" .. left .. ", " .. right .. ")")
			else
				emit("(" .. left .. " - " .. right .. ")")
			end
		end
	end

	function parse_concat()
		local start = #out + 1
		parse_unary()

		while peek() and peek().type == "op" and peek().value == "~" do
			advance()
			local left = table.concat(out, "", start)

			for i = #out, start, -1 do
				out[i] = nil
			end

			parse_unary()
			local right = table.concat(out, "", start)

			for i = #out, start, -1 do
				out[i] = nil
			end

			emit("__concat(" .. left .. ", " .. right .. ")")
		end
	end

	function parse_unary()
		if peek() and peek().type == "op" and peek().value == "-" then
			advance()
			emit("-")
			parse_unary()
		else
			parse_postfix()
		end
	end

	function parse_postfix()
		local start = #out + 1
		parse_primary()

		while true do
			local t = peek()

			if not t then break end

			-- Consolidate all fragments since start into one entry
			if #out > start then
				local consolidated = table.concat(out, "", start)

				for i = #out, start, -1 do
					out[i] = nil
				end

				out[start] = consolidated
			end

			if t.type == "dot" then
				advance()
				local name = advance()

				if not name then error("jinja2: expected identifier after '.'") end

				-- check if it's a method call: .name(args)
				if peek() and peek().type == "lparen" then
					-- method call - parse args inline using recursive parser
					local method_name = name.value
					advance() -- consume '('
					local arg_strs = {}

					if peek() and peek().type ~= "rparen" then
						-- parse first arg
						local arg_start = #out + 1
						parse_expr()
						arg_strs[#arg_strs + 1] = table.concat(out, "", arg_start)

						for i = #out, arg_start, -1 do
							out[i] = nil
						end

						while peek() and peek().type == "comma" do
							advance() -- consume ','
							arg_start = #out + 1
							parse_expr()
							arg_strs[#arg_strs + 1] = table.concat(out, "", arg_start)

							for i = #out, arg_start, -1 do
								out[i] = nil
							end
						end
					end

					if peek() and peek().type == "rparen" then advance() end

					-- Get the object we're calling method on - it's the last emitted thing
					local obj = table.remove(out)
					local lua_args = table.concat(arg_strs, ", ")

					-- Map jinja2 methods to runtime helpers
					if method_name == "startswith" then
						emit("__startswith(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "endswith" then
						emit("__endswith(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "split" then
						emit("__split(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "rstrip" then
						emit("__rstrip(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "lstrip" then
						emit("__lstrip(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "upper" then
						emit("__upper(" .. obj .. ")")
					elseif method_name == "lower" then
						emit("__lower(" .. obj .. ")")
					elseif method_name == "strip" then
						emit("__trim(" .. obj .. ")")
					elseif method_name == "replace" then
						emit("__replace(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "join" then
						emit("__join(" .. obj .. ", " .. lua_args .. ")")
					elseif method_name == "items" then
						emit("__items(" .. obj .. ")")
					elseif method_name == "keys" then
						emit("__keys(" .. obj .. ")")
					elseif method_name == "values" then
						emit("__values(" .. obj .. ")")
					elseif method_name == "append" then
						emit("__append(" .. obj .. ", " .. lua_args .. ")")
					else
						-- generic method call - assume it's a function in context or a table method
						emit(obj .. "." .. method_name .. "(" .. lua_args .. ")")
					end
				else
					-- field access
					-- Use bracket syntax for reserved words in Lua
					if
						name.value == "function" or
						name.value == "end" or
						name.value == "local" or
						name.value == "return" or
						name.value == "then" or
						name.value == "do" or
						name.value == "repeat" or
						name.value == "until"
					then
						emit("[\"" .. name.value .. "\"]")
					else
						emit("." .. name.value)
					end
				end
			elseif t.type == "lbracket" then
				advance()
				-- parse index expression
				local idx_start = #out + 1
				-- Check for negative number
				local negate = false

				if peek() and peek().type == "op" and peek().value == "-" then
					negate = true
					advance()
				end

				parse_expr()
				-- Check: if the index is a plain number literal, adjust 0-based to 1-based
				local idx_str = table.concat(out, "", idx_start)

				for i = #out, idx_start, -1 do
					out[i] = nil
				end

				if negate then
					-- negative index like [-1]
					local num = tonumber(idx_str)

					if num then
						-- python [-1] = last element. Use __neg_index
						local obj = table.remove(out)
						emit("__neg_index(" .. obj .. ", " .. tostring(num) .. ")")
					else
						emit("[(-" .. idx_str .. ")]")
					end
				else
					local num = tonumber(idx_str)

					if num and num == math.floor(num) then
						-- 0-based integer index -> 1-based
						emit("[" .. tostring(num + 1) .. "]")
					else
						emit("[" .. idx_str .. "]")
					end
				end

				-- consume ']'
				if peek() and peek().type == "rbracket" then advance() end
			elseif t.type == "slice" then
				advance()
				-- [::-1] -> reverse
				local obj = table.remove(out)
				emit("__reversed(" .. obj .. ")")
			elseif t.type == "pipe" then
				advance()
				-- filter: expr | filtername or expr | filtername(args)
				local filter_tok = advance()

				if not filter_tok then error("jinja2: expected filter name after '|'") end

				local filter_name = filter_tok.value
				-- check for filter args
				local filter_args = ""

				if peek() and peek().type == "lparen" then
					advance() -- consume '('
					local fa_start = #out + 1
					local depth = 1

					while peek() do
						if peek().type == "lparen" then
							depth = depth + 1
						elseif peek().type == "rparen" then
							depth = depth - 1

							if depth == 0 then
								advance()

								break
							end
						end

						-- parse the arg expressions
						local a = advance()

						if a.type == "string" then
							emit(lua_quote(a.value))
						elseif a.type == "number" then
							emit(a.value)
						elseif a.type == "ident" then
							emit(a.value)
						elseif a.type == "comma" then
							emit(", ")
						else
							emit(a.value or "")
						end
					end

					filter_args = table.concat(out, "", fa_start)

					for i = #out, fa_start, -1 do
						out[i] = nil
					end
				end

				local obj = table.remove(out)

				if filter_name == "trim" then
					emit("__trim(" .. obj .. ")")
				elseif filter_name == "tojson" then
					emit("__tojson(" .. obj .. ")")
				elseif filter_name == "safe" then
					emit(obj) -- no-op
				elseif filter_name == "string" then
					emit("__tostring(" .. obj .. ")")
				elseif filter_name == "length" then
					emit("__length(" .. obj .. ")")
				elseif filter_name == "int" then
					emit("__int(" .. obj .. ")")
				elseif filter_name == "float" then
					emit("tonumber(" .. obj .. ")")
				elseif filter_name == "default" or filter_name == "d" then
					if filter_args ~= "" then
						emit("__default(" .. obj .. ", " .. filter_args .. ")")
					else
						emit("__default(" .. obj .. ", '')")
					end
				elseif filter_name == "first" then
					emit("__first(" .. obj .. ")")
				elseif filter_name == "last" then
					emit("__last(" .. obj .. ")")
				elseif filter_name == "list" then
					emit("__list(" .. obj .. ")")
				elseif filter_name == "sort" then
					emit("__sort(" .. obj .. ")")
				elseif filter_name == "reverse" then
					emit("__reversed(" .. obj .. ")")
				elseif filter_name == "upper" then
					emit("__upper(" .. obj .. ")")
				elseif filter_name == "lower" then
					emit("__lower(" .. obj .. ")")
				elseif filter_name == "replace" then
					emit("__replace(" .. obj .. ", " .. filter_args .. ")")
				elseif filter_name == "join" then
					if filter_args ~= "" then
						emit("__join(" .. obj .. ", " .. filter_args .. ")")
					else
						emit("__join(" .. obj .. ", '')")
					end
				elseif filter_name == "map" then
					emit("__map(" .. obj .. ", " .. filter_args .. ")")
				elseif filter_name == "select" then
					emit("__select(" .. obj .. ", " .. filter_args .. ")")
				elseif filter_name == "reject" then
					emit("__reject(" .. obj .. ", " .. filter_args .. ")")
				elseif filter_name == "items" then
					emit("__items(" .. obj .. ")")
				else
					-- unknown filter - call as function
					if filter_args ~= "" then
						emit(filter_name .. "(" .. obj .. ", " .. filter_args .. ")")
					else
						emit(filter_name .. "(" .. obj .. ")")
					end
				end
			else
				break
			end
		end

		-- Final consolidation
		if #out > start then
			local consolidated = table.concat(out, "", start)

			for i = #out, start, -1 do
				out[i] = nil
			end

			out[start] = consolidated
		end
	end

	function parse_primary()
		local t = peek()

		if not t then return end

		if t.type == "string" then
			advance()
			emit(lua_quote(t.value))
		elseif t.type == "number" then
			advance()
			emit(t.value)
		elseif t.type == "keyword" and (t.value == "true" or t.value == "True") then
			advance()
			emit("true")
		elseif t.type == "keyword" and (t.value == "false" or t.value == "False") then
			advance()
			emit("false")
		elseif t.type == "keyword" and (t.value == "none" or t.value == "None") then
			advance()
			emit("nil")
		elseif t.type == "ident" then
			advance()
			local name = t.value

			if name == "namespace" then
				-- namespace(k=v) -> plain table
				if peek() and peek().type == "lparen" then
					advance() -- consume '('
					local fields = {}
					local depth = 1

					while peek() do
						if peek().type == "rparen" then
							depth = depth - 1

							if depth == 0 then
								advance()

								break
							end
						elseif peek().type == "lparen" then
							depth = depth + 1
						end

						if depth == 1 and peek().type == "ident" then
							local field_name = advance().value

							if peek() and peek().type == "assign" then
								advance() -- consume '='
								-- parse value expression
								local val_start = #out + 1
								parse_expr()
								local val_str = table.concat(out, "", val_start)

								for i = #out, val_start, -1 do
									out[i] = nil
								end

								fields[#fields + 1] = field_name .. " = " .. val_str

								if peek() and peek().type == "comma" then advance() end
							else
								fields[#fields + 1] = field_name
							end
						elseif depth == 1 and peek().type == "comma" then
							advance()
						else
							-- expression argument
							local val_start = #out + 1
							parse_expr()
							local val_str = table.concat(out, "", val_start)

							for i = #out, val_start, -1 do
								out[i] = nil
							end

							fields[#fields + 1] = val_str

							if peek() and peek().type == "comma" then advance() end
						end
					end

					emit("{" .. table.concat(fields, ", ") .. "}")
				else
					emit(name)
				end
			elseif name == "raise_exception" then
				emit("error")

				if peek() and peek().type == "lparen" then
					advance()
					emit("(")
					local depth = 1

					while peek() do
						if peek().type == "lparen" then
							depth = depth + 1
						elseif peek().type == "rparen" then
							depth = depth - 1

							if depth == 0 then
								advance()
								emit(")")

								break
							end
						end

						-- parse as sub-expression
						parse_expr()

						if peek() and peek().type == "comma" and depth == 1 then
							advance()
							emit(", ")
						end
					end
				end
			elseif name == "range" then
				emit("__range")

				if peek() and peek().type == "lparen" then
					emit("(")
					advance()
					local depth = 1

					while peek() do
						if peek().type == "lparen" then
							depth = depth + 1
						elseif peek().type == "rparen" then
							depth = depth - 1

							if depth == 0 then
								advance()
								emit(")")

								break
							end
						end

						parse_expr()

						if peek() and peek().type == "comma" and depth == 1 then
							advance()
							emit(", ")
						end
					end
				end
			else
				-- regular identifier - could be function call
				emit(name)

				if peek() and peek().type == "lparen" then
					advance()
					emit("(")
					local depth = 1

					while peek() do
						if peek().type == "lparen" then
							depth = depth + 1
						elseif peek().type == "rparen" then
							depth = depth - 1

							if depth == 0 then
								advance()
								emit(")")

								break
							end
						end

						if depth == 1 and peek().type == "comma" then
							advance()
							emit(", ")
						else
							parse_expr()
						end
					end
				end
			end
		elseif t.type == "lparen" then
			advance()
			emit("(")
			parse_expr()
			emit(")")

			if peek() and peek().type == "rparen" then advance() end
		else
			-- unexpected token, just emit it
			advance()

			if t.value then emit(t.value) end
		end
	end

	parse_expr()

	-- consume any remaining tokens (shouldn't normally happen)
	while pos <= #toks do
		local t = advance()

		if t.type == "string" then
			emit(lua_quote(t.value))
		elseif t.value then
			emit(t.value)
		end
	end

	return table.concat(out)
end

jinja2.transpile_expression = transpile_expression

----------------------------------------------------------------
-- Statement transpiler
----------------------------------------------------------------
local function parse_set_statement(content)
	-- "set x = expr" or "set x.y = expr"
	local var_part, expr_part = content:match("^set%s+(.-)%s*=%s*(.+)$")

	if not var_part then return nil end

	local lua_expr = transpile_expression(expr_part)

	-- check if it's a dotted assignment (e.g., ns.field = ...)
	if var_part:find("%.") then
		return var_part .. " = " .. lua_expr
	else
		return "local " .. var_part .. " = " .. lua_expr
	end
end

local function parse_for_statement(content)
	-- "for x in expr" or "for k, v in expr"
	-- Also handle "for x in expr|filter"
	local vars, expr = content:match("^for%s+(.-)%s+in%s+(.+)$")

	if not vars then return nil end

	local lua_expr = transpile_expression(expr)
	-- Check if multiple vars (e.g., "k, v")
	local var_list = {}

	for v in vars:gmatch("[%w_]+") do
		var_list[#var_list + 1] = v
	end

	if #var_list == 1 then
		return var_list[1], lua_expr
	else
		return table.concat(var_list, ", "), lua_expr
	end
end

local function parse_macro_statement(content)
	-- "macro name(arg1, arg2, arg3=default)"
	local name, args_str = content:match("^macro%s+([%w_]+)%s*%((.*)%)$")

	if not name then
		name = content:match("^macro%s+([%w_]+)%s*%(%)$")

		if name then return name, {} end

		return nil
	end

	local args = {}

	-- Parse args, handling defaults
	for arg in args_str:gmatch("[^,]+") do
		arg = arg:match("^%s*(.-)%s*$") -- trim
		local arg_name, default = arg:match("^([%w_]+)%s*=%s*(.+)$")

		if arg_name then
			args[#args + 1] = {name = arg_name, default = transpile_expression(default)}
		else
			args[#args + 1] = {name = arg}
		end
	end

	return name, args
end

local function transpile_statement(content, lines)
	content = content:match("^%s*(.-)%s*$") -- trim
	-- set statement
	if content:match("^set%s+") then
		local lua = parse_set_statement(content)

		if lua then
			lines[#lines + 1] = lua
			return
		end
	end

	-- if
	if content:match("^if%s+") then
		local cond = content:match("^if%s+(.+)$")
		lines[#lines + 1] = "if " .. transpile_expression(cond) .. " then"
		return
	end

	-- elif
	if content:match("^elif%s+") then
		local cond = content:match("^elif%s+(.+)$")
		lines[#lines + 1] = "elseif " .. transpile_expression(cond) .. " then"
		return
	end

	-- else
	if content == "else" then
		lines[#lines + 1] = "else"
		return
	end

	-- endif
	if content == "endif" then
		lines[#lines + 1] = "end"
		return
	end

	-- for
	if content:match("^for%s+") then
		local vars, lua_expr = parse_for_statement(content)

		if vars then
			-- Use a unique list var
			local list_var = "__list_" .. #lines
			lines[#lines + 1] = "do local " .. list_var .. " = __iter_list(" .. lua_expr .. ")"
			lines[#lines + 1] = "for __i, " .. vars .. " in __ipairs(" .. list_var .. ") do"
			lines[#lines + 1] = "local loop = {index0 = __i - 1, index = __i, first = __i == 1, last = __i == #" .. list_var .. ", previtem = " .. list_var .. "[__i - 1], nextitem = " .. list_var .. "[__i + 1], length = #" .. list_var .. "}"
			return
		end
	end

	-- endfor
	if content == "endfor" then
		lines[#lines + 1] = "end end" -- close for + do
		return
	end

	-- macro
	if content:match("^macro%s+") then
		local name, args = parse_macro_statement(content)

		if name then
			local arg_names = {}

			for _, a in ipairs(args) do
				arg_names[#arg_names + 1] = a.name
			end

			lines[#lines + 1] = "local function " .. name .. "(" .. table.concat(arg_names, ", ") .. ")"

			-- Apply defaults
			for _, a in ipairs(args) do
				if a.default then
					lines[#lines + 1] = "if " .. a.name .. " == nil then " .. a.name .. " = " .. a.default .. " end"
				end
			end

			-- Macro output buffer
			lines[#lines + 1] = "local __macro_out = {}"
			lines[#lines + 1] = "local __parent_emit = __emit"
			lines[#lines + 1] = "__emit = function(s) __macro_out[#__macro_out + 1] = __tostring(s) end"
			return
		end
	end

	-- endmacro
	if content == "endmacro" then
		lines[#lines + 1] = "__emit = __parent_emit"
		lines[#lines + 1] = "return __table_concat(__macro_out)"
		lines[#lines + 1] = "end"
		return
	end

	-- raw / endraw
	if content == "raw" then
		-- raw blocks handled at template level, not here
		return
	end

	if content == "endraw" then return end

	-- fallback: try to execute as expression
	lines[#lines + 1] = "-- UNKNOWN STATEMENT: " .. content
end

----------------------------------------------------------------
-- Compiler: tokens -> Lua source
----------------------------------------------------------------
function jinja2.compile(template_str)
	local tokens = jinja2.tokenize(template_str)
	local lines = {}
	-- preamble
	lines[#lines + 1] = "local __out = {}"
	lines[#lines + 1] = "local function __emit(s) if s ~= nil then __out[#__out + 1] = __tostring(s) end end"

	for _, tok in ipairs(tokens) do
		if tok.type == "text" then
			if tok.value ~= "" then
				lines[#lines + 1] = "__emit(" .. lua_quote(tok.value) .. ")"
			end
		elseif tok.type == "expression" then
			local lua_expr = transpile_expression(tok.value)
			lines[#lines + 1] = "__emit(" .. lua_expr .. ")"
		elseif tok.type == "statement" then
			transpile_statement(tok.value, lines)
		end
	end

	lines[#lines + 1] = "return __table_concat(__out)"
	return table.concat(lines, "\n")
end

----------------------------------------------------------------
-- Runtime helpers
----------------------------------------------------------------
local runtime = {}

function runtime.__tostring(v)
	if v == nil then return "" end

	if type(v) == "boolean" then return v and "True" or "False" end

	return tostring(v)
end

function runtime.__type(v)
	return type(v)
end

function runtime.__is_iterable(v)
	return type(v) == "table"
end

function runtime.__is_mapping(v)
	if type(v) ~= "table" then return false end

	-- A mapping has non-consecutive-integer keys
	-- Check: if it has a key that's not in 1..#v, it's a mapping
	local n = #v

	for k in pairs(v) do
		if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
			return true
		end
	end

	-- empty table: treat as mapping if metatable marks it, otherwise false
	if n == 0 and next(v) == nil then return false end

	return false
end

function runtime.__is_sequence(v)
	if type(v) ~= "table" then return false end

	return not runtime.__is_mapping(v)
end

function runtime.__contains(container, item)
	if type(container) == "string" then
		return container:find(item, 1, true) ~= nil
	elseif type(container) == "table" then
		-- check as key first
		if container[item] ~= nil then return true end

		-- check as value in array
		for _, v in ipairs(container) do
			if v == item then return true end
		end
	end

	return false
end

function runtime.__trim(s)
	if s == nil then return "" end

	return tostring(s):match("^%s*(.-)%s*$")
end

function runtime.__tojson(v)
	return json.encode(v)
end

function runtime.__length(v)
	if type(v) == "string" then return #v end

	if type(v) == "table" then return #v end

	return 0
end

function runtime.__int(v)
	return math.floor(tonumber(v) or 0)
end

function runtime.__reversed(list)
	local result = {}

	for i = #list, 1, -1 do
		result[#result + 1] = list[i]
	end

	return result
end

function runtime.__neg_index(list, idx)
	-- python-style: list[-1] = last element
	return list[#list - idx + 1]
end

function runtime.__startswith(s, prefix)
	return s:sub(1, #prefix) == prefix
end

function runtime.__endswith(s, suffix)
	return s:sub(-#suffix) == suffix
end

function runtime.__split(s, sep)
	local parts = {}

	if sep then
		local start = 1

		while true do
			local i, j = s:find(sep, start, true)

			if not i then
				parts[#parts + 1] = s:sub(start)

				break
			end

			parts[#parts + 1] = s:sub(start, i - 1)
			start = j + 1
		end
	else
		for part in s:gmatch("%S+") do
			parts[#parts + 1] = part
		end
	end

	return parts
end

function runtime.__rstrip(s, chars)
	if chars then
		local pattern = "[" .. chars:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "]+$"
		return s:gsub(pattern, "")
	end

	return s:gsub("%s+$", "")
end

function runtime.__lstrip(s, chars)
	if chars then
		local pattern = "^[" .. chars:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "]+"
		return s:gsub(pattern, "")
	end

	return s:gsub("^%s+", "")
end

function runtime.__upper(s)
	return tostring(s):upper()
end

function runtime.__lower(s)
	return tostring(s):lower()
end

function runtime.__replace(s, old, new)
	return (tostring(s):gsub(old:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"), new))
end

function runtime.__join(list, sep)
	local parts = {}

	for _, v in ipairs(list) do
		parts[#parts + 1] = tostring(v)
	end

	return table.concat(parts, sep or "")
end

function runtime.__default(v, default)
	if v == nil then return default end

	return v
end

function runtime.__first(list)
	return list[1]
end

function runtime.__last(list)
	return list[#list]
end

function runtime.__range(...)
	local args = {...}
	local start, stop, step

	if #args == 1 then
		start, stop, step = 0, args[1], 1
	elseif #args == 2 then
		start, stop, step = args[1], args[2], 1
	else
		start, stop, step = args[1], args[2], args[3]
	end

	local result = {}

	for i = start, stop - 1, step do
		result[#result + 1] = i
	end

	return result
end

function runtime.__items(t)
	local result = {}

	for k, v in pairs(t) do
		result[#result + 1] = {k, v}
	end

	return result
end

function runtime.__keys(t)
	local result = {}

	for k in pairs(t) do
		result[#result + 1] = k
	end

	return result
end

function runtime.__values(t)
	local result = {}

	for _, v in pairs(t) do
		result[#result + 1] = v
	end

	return result
end

function runtime.__append(list, item)
	list[#list + 1] = item
	return list
end

function runtime.__ternary(cond, val_true, val_false)
	if cond then return val_true else return val_false end
end

-- __add: + operator that works as concat for strings, addition for numbers
function runtime.__add(a, b)
	if type(a) == "string" or type(b) == "string" then
		return tostring(a) .. tostring(b)
	end

	return (tonumber(a) or 0) + (tonumber(b) or 0)
end

-- __concat: ~ operator - always string concat with tostring
function runtime.__concat(a, b)
	return runtime.__tostring(a) .. runtime.__tostring(b)
end

function runtime.__iter_list(t)
	if type(t) ~= "table" then return {} end

	-- Check if it's array-like
	if #t > 0 or next(t) == nil then return t end

	-- Mapping: return keys as array
	local keys = {}

	for k in pairs(t) do
		keys[#keys + 1] = k
	end

	return keys
end

runtime.__ipairs = ipairs
runtime.__table_concat = table.concat
jinja2.runtime = runtime

----------------------------------------------------------------
-- Render: compile + execute
----------------------------------------------------------------
function jinja2.render(template_str, context)
	local lua_source = jinja2.compile(template_str)
	-- Build execution environment
	local env = {}

	-- Copy runtime helpers
	for k, v in pairs(runtime) do
		env[k] = v
	end

	-- Copy context variables
	if context then for k, v in pairs(context) do
		env[k] = v
	end end

	-- Provide standard Lua functions
	env.tostring = tostring
	env.tonumber = tonumber
	env.type = type
	env.pairs = pairs
	env.ipairs = ipairs
	env.next = next
	env.error = error
	env.math = math
	env.string = string
	env.table = table
	local fn, err = loadstring(lua_source, "jinja2_template")

	if not fn then
		error("jinja2 compile error: " .. err .. "\n\nGenerated Lua:\n" .. lua_source)
	end

	setfenv(fn, env)
	local ok, result = pcall(fn)

	if not ok then
		error(
			"jinja2 render error: " .. tostring(result) .. "\n\nGenerated Lua:\n" .. lua_source
		)
	end

	return result
end

return jinja2
