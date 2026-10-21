local perf = {}
local tabs = {}
perf.POLL_INTERVAL = 0.1

function perf.RegisterTab(name, order, view)
	tabs[name] = {name = name, order = order, view = view}
end

function perf.GetTabs()
	local list = {}

	for _, tab in pairs(tabs) do
		list[#list + 1] = tab
	end

	table.sort(list, function(a, b)
		return a.order < b.order
	end)

	return list
end

function perf.PrintRows(rows)
	for _, row in ipairs(rows) do
		logn(
			row.label,
			row.value and ("  " .. row.value) or "",
			row.detail and ("  " .. row.detail) or ""
		)
	end
end

return perf
