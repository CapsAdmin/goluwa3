local diff = require("helpers.diff")
local attest = {}

function attest.equal(a, b, LEVEL)
	if a ~= b then
		if type(a) == "string" then a = string.format("%q", a) end

		if type(b) == "string" then b = string.format("%q", b) end

		error("\n" .. tostring(a) .. " ~= " .. tostring(b), LEVEL)
	end

	return true
end

function attest.not_equal(a, b, LEVEL)
	if a == b then
		if type(a) == "string" then a = string.format("%q", a) end

		if type(b) == "string" then b = string.format("%q", b) end

		error("\n" .. tostring(a) .. " == " .. tostring(b), LEVEL)
	end

	return true
end

function attest.almost_equal(a, b, epsilon, LEVEL)
	epsilon = epsilon or 0.0001

	if type(a) ~= "number" or type(b) ~= "number" then
		error("AlmostEqual requires numbers, got " .. type(a) .. " and " .. type(b), LEVEL)
	end

	if math.abs(a - b) >= epsilon then
		error(
			string.format(
				"\n%s not almost equal to %s (epsilon: %s, diff: %s)",
				tostring(a),
				tostring(b),
				tostring(epsilon),
				tostring(math.abs(a - b))
			),
			2
		)
	end

	return true
end

-- Alias for AlmostEqual
attest.close = attest.almost_equal

function attest.in_range(value, min, max, LEVEL)
	if value < min or value > max then
		error(
			string.format("\n%s not in range [%s, %s]", tostring(value), tostring(min), tostring(max)),
			2
		)
	end

	return true
end

function attest.greater(a, b, LEVEL)
	if not (a > b) then
		error(string.format("\n%s not > %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.greater_or_equal(a, b, LEVEL)
	if not (a >= b) then
		error(string.format("\n%s not >= %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.less(a, b, LEVEL)
	if not (a < b) then
		error(string.format("\n%s not < %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.less_or_equal(a, b, LEVEL)
	if not (a <= b) then
		error(string.format("\n%s not <= %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.match(str, pattern, LEVEL)
	if type(str) ~= "string" then
		error("Match requires a string, got " .. type(str), LEVEL)
	end

	if not str:match(pattern) then
		error(string.format("\n%q does not match pattern %q", str, pattern), LEVEL)
	end

	return true
end

function attest.contains(str, substr, LEVEL)
	if type(str) ~= "string" then
		error("Contains requires a string, got " .. type(str), LEVEL)
	end

	if not str:find(substr, 1, true) then
		error(string.format("\n%q does not contain %q", str, substr), LEVEL)
	end

	return true
end

function attest.truthy(value, LEVEL)
	if not value then error("\nvalue is not truthy: " .. tostring(value), LEVEL) end

	return true
end

function attest.falsy(value, LEVEL)
	if value then error("\nvalue is not falsy: " .. tostring(value), LEVEL) end

	return true
end

function attest.fails(func, expected_pattern, LEVEL)
	if type(func) ~= "function" then
		error("Fails requires a function, got " .. type(func), LEVEL)
	end

	local ok, err = pcall(func)

	if ok then error("\nexpected function to fail, but it succeeded", LEVEL) end

	if expected_pattern and not tostring(err):match(expected_pattern) then
		error(
			string.format("\nerror %q does not match expected pattern %q", tostring(err), expected_pattern),
			2
		)
	end

	return true
end

-- Alias for Fails
attest.throws = attest.fails

function attest.diff(input, expect)
	print(diff.diff(input, expect))
end

function attest.ok(b, LEVEL)
	if not b then error("not ok!", LEVEL) end
end

function attest.AssertHelper(val)
	return setmetatable(
		{},
		{
			__index = function(_, op)
				return function(expected)
					local LEVEL = 4

					if op == "==" then
						attest.equal(val, expected, LEVEL)
					elseif op == "~=" then
						attest.not_equal(val, expected, LEVEL)
					elseif op == ">" then
						attest.greater(val, expected, LEVEL)
					elseif op == ">=" then
						attest.greater_or_equal(val, expected, LEVEL)
					elseif op == "<" then
						attest.less(val, expected, LEVEL)
					elseif op == "<=" then
						attest.less_or_equal(val, expected, LEVEL)
					elseif op == "~" or op == "close" then
						attest.almost_equal(val, expected, LEVEL)
					elseif op == "match" then
						attest.match(val, expected, LEVEL)
					elseif op == "contains" then
						attest.contains(val, expected, LEVEL)
					else
						error("Unknown operator: " .. tostring(op), LEVEL - 1)
					end
				end
			end,
		}
	)
end

--setmetatable(attest, function() end)
return attest
