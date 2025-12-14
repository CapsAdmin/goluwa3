local attest = {}

function attest.equal(a, b)
	if a ~= b then
		if type(a) == "string" then a = string.format("%q", a) end

		if type(b) == "string" then b = string.format("%q", b) end

		error("\n" .. tostring(a) .. " ~= " .. tostring(b), 2)
	end

	return true
end

function attest.not_equal(a, b)
	if a == b then
		if type(a) == "string" then a = string.format("%q", a) end

		if type(b) == "string" then b = string.format("%q", b) end

		error("\n" .. tostring(a) .. " == " .. tostring(b), 2)
	end

	return true
end

function attest.almost_equal(a, b, epsilon)
	epsilon = epsilon or 0.0001

	if type(a) ~= "number" or type(b) ~= "number" then
		error("almost_equal requires numbers, got " .. type(a) .. " and " .. type(b), 2)
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

-- Alias for almost_equal
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
		error(string.format("\n%s not > %s", tostring(a), tostring(b)), 2)
	end

	return true
end

function attest.greater_or_equal(a, b)
	if not (a >= b) then
		error(string.format("\n%s not >= %s", tostring(a), tostring(b)), 2)
	end

	return true
end

function attest.less(a, b)
	if not (a < b) then
		error(string.format("\n%s not < %s", tostring(a), tostring(b)), 2)
	end

	return true
end

function attest.less_or_equal(a, b)
	if not (a <= b) then
		error(string.format("\n%s not <= %s", tostring(a), tostring(b)), 2)
	end

	return true
end

function attest.match(str, pattern)
	if type(str) ~= "string" then
		error("match requires a string, got " .. type(str), 2)
	end

	if not str:match(pattern) then
		error(string.format("\n%q does not match pattern %q", str, pattern), 2)
	end

	return true
end

function attest.truthy(value)
	if not value then error("\nvalue is not truthy: " .. tostring(value), 2) end

	return true
end

function attest.falsy(value)
	if value then error("\nvalue is not falsy: " .. tostring(value), 2) end

	return true
end

function attest.fails(func, expected_pattern)
	if type(func) ~= "function" then
		error("fails requires a function, got " .. type(func), 2)
	end

	local ok, err = pcall(func)

	if ok then error("\nexpected function to fail, but it succeeded", 2) end

	if expected_pattern and not tostring(err):match(expected_pattern) then
		error(
			string.format("\nerror %q does not match expected pattern %q", tostring(err), expected_pattern),
			2
		)
	end

	return true
end

-- Alias for fails
attest.throws = attest.fails

function attest.diff(input, expect)
	print(diff.diff(input, expect))
end

function attest.ok(b)
	if not b then error("not ok!", 2) end
end

function attest.binary_op(a, op, b)
	if op == "==" then
		return attest.equal(a, b)
	elseif op == "~=" then
		return attest.not_equal(a, b)
	elseif op == "<" then
		return attest.less(a, b)
	elseif op == "<=" then
		return attest.less_or_equal(a, b)
	elseif op == ">" then
		return attest.greater(a, b)
	elseif op == ">=" then
		return attest.greater_or_equal(a, b)
	elseif op == "almost_equal" then
		return attest.almost_equal(a, b)
	elseif op == "in_range" then
		return attest.in_range(a, b[1], b[2])
	else
		error("unknown binary operator: " .. tostring(op), 2)
	end
end

--setmetatable(attest, function() end)
return attest
