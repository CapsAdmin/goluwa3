local easing = {}

function easing.linear(t)
	return t
end

function easing.inQuad(t)
	return t * t
end

function easing.outQuad(t)
	return t * (2 - t)
end

function easing.inOutQuad(t)
	if t < 0.5 then return 2 * t * t else return -1 + (4 - 2 * t) * t end
end

function easing.inCubic(t)
	return t * t * t
end

function easing.outCubic(t)
	t = t - 1
	return t * t * t + 1
end

function easing.inOutCubic(t)
	if t < 0.5 then
		return 4 * t * t * t
	else
		return (t - 1) * (2 * t - 2) * (2 * t - 2) + 1
	end
end

function easing.inQuart(t)
	return t * t * t * t
end

function easing.outQuart(t)
	t = t - 1
	return 1 - t * t * t * t
end

function easing.inOutQuart(t)
	if t < 0.5 then
		t = t * t
		return 8 * t * t
	else
		t = t - 1
		return 1 - 8 * t * t * t * t
	end
end

function easing.inQuint(t)
	return t * t * t * t * t
end

function easing.outQuint(t)
	t = t - 1
	return t * t * t * t * t + 1
end

function easing.inOutQuint(t)
	if t < 0.5 then
		return 16 * t * t * t * t * t
	else
		t = t - 1
		return 16 * t * t * t * t * t + 1
	end
end

function easing.inSine(t)
	return 1 - math.cos(t * math.pi / 2)
end

function easing.outSine(t)
	return math.sin(t * math.pi / 2)
end

function easing.inOutSine(t)
	return 0.5 * (1 - math.cos(math.pi * t))
end

function easing.inExpo(t)
	if t == 0 then return 0 end

	return 2 ^ (10 * (t - 1))
end

function easing.outExpo(t)
	if t == 1 then return 1 end

	return 1 - 2 ^ (-10 * t)
end

function easing.inOutExpo(t)
	if t == 0 then return 0 end

	if t == 1 then return 1 end

	if t < 0.5 then
		return 0.5 * 2 ^ (20 * t - 10)
	else
		return 1 - 0.5 * 2 ^ (-20 * t + 10)
	end
end

function easing.inCirc(t)
	return 1 - math.sqrt(1 - t * t)
end

function easing.outCirc(t)
	t = t - 1
	return math.sqrt(1 - t * t)
end

function easing.inOutCirc(t)
	t = t * 2

	if t < 1 then
		return -0.5 * (math.sqrt(1 - t * t) - 1)
	else
		t = t - 2
		return 0.5 * (math.sqrt(1 - t * t) + 1)
	end
end

function easing.inBack(t, s)
	s = s or 1.70158
	return t * t * ((s + 1) * t - s)
end

function easing.outBack(t, s)
	s = s or 1.70158
	t = t - 1
	return t * t * ((s + 1) * t + s) + 1
end

function easing.inOutBack(t, s)
	s = (s or 1.70158) * 1.525
	t = t * 2

	if t < 1 then
		return 0.5 * (t * t * ((s + 1) * t - s))
	else
		t = t - 2
		return 0.5 * (t * t * ((s + 1) * t + s) + 2)
	end
end

function easing.outBounce(t)
	if t < 1 / 2.75 then
		return 7.5625 * t * t
	elseif t < 2 / 2.75 then
		t = t - 1.5 / 2.75
		return 7.5625 * t * t + 0.75
	elseif t < 2.5 / 2.75 then
		t = t - 2.25 / 2.75
		return 7.5625 * t * t + 0.9375
	else
		t = t - 2.625 / 2.75
		return 7.5625 * t * t + 0.984375
	end
end

function easing.inBounce(t)
	return 1 - easing.outBounce(1 - t)
end

function easing.inOutBounce(t)
	if t < 0.5 then
		return easing.inBounce(t * 2) * 0.5
	else
		return easing.outBounce(t * 2 - 1) * 0.5 + 0.5
	end
end

function easing.inElastic(t, p)
	if t == 0 then return 0 end

	if t == 1 then return 1 end

	p = p or 0.3
	local s = p / 4
	t = t - 1
	return -(2 ^ (10 * t) * math.sin((t - s) * (2 * math.pi) / p))
end

function easing.outElastic(t, p)
	if t == 0 then return 0 end

	if t == 1 then return 1 end

	p = p or 0.3
	local s = p / 4
	return 2 ^ (-10 * t) * math.sin((t - s) * (2 * math.pi) / p) + 1
end

function easing.inOutElastic(t, p)
	if t == 0 then return 0 end

	if t == 1 then return 1 end

	p = p or (0.3 * 1.5)
	local s = p / 4
	t = t * 2

	if t < 1 then
		t = t - 1
		return -0.5 * (2 ^ (10 * t) * math.sin((t - s) * (2 * math.pi) / p))
	else
		t = t - 1
		return 2 ^ (-10 * t) * math.sin((t - s) * (2 * math.pi) / p) * 0.5 + 1
	end
end

return easing
