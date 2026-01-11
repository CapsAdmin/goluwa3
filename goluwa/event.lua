local event = library()
event.active = event.active or {}
event.destroy_tag = event.destroy_tag or {}

local function sort(a, b)
	return a.priority > b.priority
end

local function sort_events(key)
	local entries = key and {[key] = event.active[key]} or event.active

	for key, tbl in pairs(entries) do
		local new = {}

		for _, v in pairs(tbl) do
			list.insert(new, v)
		end

		list.sort(new, sort)
		event.active[key] = new
	end
end

function event.AddListener(event_type, id, callback, config)
	if type(event_type) == "table" then config = event_type end

	if not callback and type(id) == "function" then
		callback = id
		id = nil
	end

	config = config or {}
	config.event_type = config.event_type or event_type
	config.id = config.id or id
	config.callback = config.callback or callback
	config.priority = config.priority or 0

	-- useful for initialize events
	if config.id == nil then
		config.id = {}
		config.remove_after_one_call = true
	end

	config.print_str = config.event_type .. "->" .. tostring(config.id)
	event.RemoveListener(config.event_type, config.id)
	event.active[config.event_type] = event.active[config.event_type] or {}
	list.insert(event.active[config.event_type], config)
	sort_events(config.event_type)

	if event_type ~= "EventAdded" then event.Call("EventAdded", config) end
end

function event.IsListenerActive(event_type, id)
	if event.active[event_type] then
		for _, data in pairs(event.active[event_type]) do
			if data.id == id then return true end
		end
	end

	return false
end

event.fix_indices = event.fix_indices or {}

function event.RemoveListener(event_type, id)
	if type(event_type) == "table" then
		local config = event_type
		id = id or config.id
		event_type = config.event_type
	end

	if id ~= nil and event.active[event_type] then
		for index, val in pairs(event.active[event_type]) do
			if id == val.id then
				event.active[event_type][index] = nil
				event.fix_indices[event_type] = true

				if event_type ~= "EventRemoved" then event.Call("EventRemoved", val) end

				break
			end
		end
	else

	--logn(("Tried to remove non existing event '%s:%s'"):format(event, tostring(unique)))
	end
end

function event.Call(event_type, a_, b_, c_, d_, e_)
	if event.active[event_type] then
		local a, b, c, d, e

		for index = 1, #event.active[event_type] do
			local data = event.active[event_type][index]

			if data then
				if data.self_arg then
					if data.self_arg:IsValid() then
						if data.self_arg_with_callback then
							a, b, c, d, e = data.callback(a_, b_, c_, d_, e_)
						else
							a, b, c, d, e = data.callback(data.self_arg, a_, b_, c_, d_, e_)
						end
					else
						event.RemoveListener(event_type, data.id)
						llog("[%q][%q] removed because self is invalid", event_type, data.unique)
					end
				else
					a, b, c, d, e = data.callback(a_, b_, c_, d_, e_)
				end

				if a == event.destroy_tag or data.remove_after_one_call then
					event.RemoveListener(event_type, data.id)
				end

				if a ~= nil and a ~= event.destroy_tag then return a, b, c, d, e end
			end
		end
	end

	if event.fix_indices[event_type] then
		list.fix_indices(event.active[event_type])
		event.fix_indices[event_type] = nil
		sort_events(event_type)
	end
end

function event.CreateRealm(config)
	if type(config) == "string" then config = {id = config} end

	return setmetatable(
		{},
		{
			__index = function(_, key, val)
				for i, data in ipairs(event.active[key]) do
					if data.id == config.id then return config.callback end
				end
			end,
			__newindex = function(_, key, val)
				if type(val) == "function" then
					config = table.copy(config)
					config.event_type = key
					config.callback = val
					event.AddListener(config)
				elseif val == nil then
					config = table.copy(config)
					config.event_type = key
					event.RemoveListener(config)
				end
			end,
		}
	)
end

return event
