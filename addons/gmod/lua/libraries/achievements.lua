local achievements = gine.env.achievements

local function noop()
	return nil
end

for key, value in pairs(achievements) do
	if type(value) == "function" then achievements[key] = noop end
end

setmetatable(achievements, {
	__index = function(tbl, key)
		rawset(tbl, key, noop)
		return noop
	end,
})