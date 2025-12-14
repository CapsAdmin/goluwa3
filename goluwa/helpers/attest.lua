local diff = require("helpers.diff")
local attest = {}
local LEVEL = 3

function attest.equal(a, b)
	if a ~= b then
		if type(a) == "string" then a = string.format("%q", a) end

		if type(b) == "string" then b = string.format("%q", b) end

		error("\n" .. tostring(a) .. " ~= " .. tostring(b), LEVEL)
	end

	return true
end

function attest.not_equal(a, b)
	if a == b then
		if type(a) == "string" then a = string.format("%q", a) end

		if type(b) == "string" then b = string.format("%q", b) end

		error("\n" .. tostring(a) .. " == " .. tostring(b), LEVEL)
	end

	return true
end

function attest.almost_equal(a, b, epsilon)
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

function attest.in_range(value, min, max)
	if value < min or value > max then
		error(
			string.format("\n%s not in range [%s, %s]", tostring(value), tostring(min), tostring(max)),
			2
		)
	end

	return true
end

function attest.greater(a, b)
	if not (a > b) then
		error(string.format("\n%s not > %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.greater_or_equal(a, b)
	if not (a >= b) then
		error(string.format("\n%s not >= %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.less(a, b)
	if not (a < b) then
		error(string.format("\n%s not < %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.less_or_equal(a, b)
	if not (a <= b) then
		error(string.format("\n%s not <= %s", tostring(a), tostring(b)), LEVEL)
	end

	return true
end

function attest.match(str, pattern)
	if type(str) ~= "string" then
		error("Match requires a string, got " .. type(str), LEVEL)
	end

	if not str:match(pattern) then
		error(string.format("\n%q does not match pattern %q", str, pattern), LEVEL)
	end

	return true
end

function attest.truthy(value)
	if not value then error("\nvalue is not truthy: " .. tostring(value), LEVEL) end

	return true
end

function attest.falsy(value)
	if value then error("\nvalue is not falsy: " .. tostring(value), LEVEL) end

	return true
end

function attest.fails(func, expected_pattern)
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

function attest.ok(b)
	if not b then error("not ok!", LEVEL) end
end

function attest.AssertHelper(val)
	return setmetatable(
		{},
		{
			__index = function(_, op)
				return function(expected)
					if op == "==" then
						attest.equal(val, expected)
					elseif op == "~=" then
						attest.not_equal(val, expected)
					elseif op == ">" then
						attest.greater(val, expected)
					elseif op == ">=" then
						attest.greater_or_equal(val, expected)
					elseif op == "<" then
						attest.less(val, expected)
					elseif op == "<=" then
						attest.less_or_equal(val, expected)
					elseif op == "~" or op == "close" then
						attest.almost_equal(val, expected)
					elseif op == "match" then
						attest.match(val, expected)
					else
						error("Unknown operator: " .. tostring(op), LEVEL)
					end
				end
			end,
		}
	)
end

--setmetatable(attest, function() end)
return attest
