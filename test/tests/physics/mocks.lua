local module = {}

function module.CreateMockBody(data)
	data = data or {}
	return {
		GetMass = function()
			return data.Mass or 0
		end,
		GetDensity = function()
			return data.Density or 0
		end,
		GetAutomaticMass = function()
			return data.AutomaticMass == true
		end,
		IsDynamic = function()
			if data.IsDynamic ~= nil then return data.IsDynamic end

			return true
		end,
	}
end

local T = import("test/environment.lua")

T.Test("test", function() end)

return module