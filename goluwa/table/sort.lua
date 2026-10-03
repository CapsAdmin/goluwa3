local math_floor = _G.math.floor

local function set2(t, i, j, ival, jval)
	t[i] = ival
	t[j] = jval
end

local function default_comp(a, b)
	return a < b
end

local auxsort

function auxsort(t--[[#: any]], l, u, sort_comp)
	while l < u do
		do
			local a = t[l]
			local b = t[u]

			if sort_comp(b, a) then set2(t, l, u, b, a) end
		end

		if u - l == 1 then break end

		local i = math_floor((l + u) / 2)

		do
			local a = t[i]
			local b = t[l]

			if sort_comp(a, b) then
				set2(t, i, l, b, a)
			else
				b = nil
				b = t[u]

				if sort_comp(b, a) then set2(t, i, u, b, a) end
			end
		end

		if u - l == 2 then break end

		local P = t[i]
		local P2 = P
		local b = t[u - 1]
		set2(t, i, u - 1, b, P2)
		i = l
		local j = u - 1

		while true do
			i = i + 1
			local a = t[i]

			while sort_comp(a, P) do
				i = i + 1
				a = t[i]
			end

			j = j - 1
			local b = t[j]

			while sort_comp(P, b) do
				j = j - 1
				b = t[j]
			end

			if j < i then break end

			set2(t, i, j, b, a)
		end

		t[u - 1], t[i] = t[i], t[u - 1]

		if (i - l) < (u - i) then
			j = l
			i = i - 1
			l = i + 2
		else
			j = i + 1
			i = u
			u = j - 2
		end

		auxsort(t, j, i, sort_comp)
	end
end

return function(t, comp)
	auxsort(t, 1, #t, comp or default_comp)
end
