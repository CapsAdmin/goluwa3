local pvars = import("goluwa/cli/pvars.lua")
local pvar_node = {}
local node_types = {
	boolean = "boolean",
	number = "number",
	string = "string",
}

function pvar_node.IsSupported(info)
	return node_types[info.type] ~= nil
end

-- a property editor node for a pvar, on_change gets the value the user set
function pvar_node.Build(info, on_change)
	local node = {
		Key = info.key,
		Text = info.friendly,
		Description = info.help and (info.key .. ": " .. info.help) or info.key,
		Search = info.key,
		Type = node_types[info.type],
		Value = pvars.Get(info.key),
		Default = info.default,
		OnChange = function(_, value)
			on_change(value)
		end,
	}

	if info.enums then
		node.Type = "enum"
		node.Options = {}

		for i, value in ipairs(info.enums) do
			node.Options[i] = {Text = tostring(value), Value = value}
		end
	elseif info.type == "number" then
		node.Min = info.min
		node.Max = info.max
		node.ShowSlider = info.min ~= nil and info.max ~= nil

		if info.integer then
			node.NumberType = "int"
			node.Precision = 0
		else
			node.Precision = 3
		end
	end

	return node
end

return pvar_node
