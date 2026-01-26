--[[HOTRELOAD
	os.execute("luajit glw test gui")
]]
local event = require("event")
local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local window = require("window")
local timer = require("timer")
local META = prototype.CreateTemplate("lsx_realm")
local Fragment = prototype.CreateTemplate("lsx_fragment"):Register()
local Element = prototype.CreateTemplate("lsx_element"):Register()
local Component = prototype.CreateTemplate("lsx_component"):Register()

function META:Fragment(props)
	return Fragment:CreateObject({props = props or {}})
end

function META:Value(fn)
	return {__lsx_value = fn}
end

function META:Pauser(fn)
	return {__lsx_pauser = fn}
end

function META:RegisterElement(ctor)
	return function(self, props)
		if props == nil then props = self end

		return Element:CreateObject({
			ctor = ctor,
			props = props or {},
		})
	end
end

function META:UseState(initial)
	local comp = self.current_component

	if not comp then error("can only be called inside a component", 2) end

	local idx = self.hook_index
	self.hook_index = self.hook_index + 1
	local states = self.component_states[comp]

	if not states then
		states = {}
		self.component_states[comp] = states
	end

	if states[idx] == nil then
		if type(initial) == "function" then
			states[idx] = initial()
		else
			states[idx] = initial
		end
	end

	local function set_state(newValue)
		local oldValue = states[idx]
		local nextValue

		if type(newValue) == "function" then
			nextValue = newValue(oldValue)
		else
			nextValue = newValue
		end

		if nextValue == oldValue then return end

		states[idx] = nextValue

		if comp.instance and not comp.render_scheduled then
			comp.render_scheduled = true
			table.insert(self.pending_renders, comp)
		end
	end

	return states[idx], set_state
end

function META:UseEffect(effect, deps)
	local comp = self.current_component

	if not comp then error("can only be called inside a component", 2) end

	local idx = self.hook_index
	self.hook_index = self.hook_index + 1
	local states = self.component_states[comp]

	if not states then
		states = {}
		self.component_states[comp] = states
	end

	local prevRecord = states[idx]
	local shouldRun = not prevRecord

	if deps and prevRecord and prevRecord.deps then
		for i, dep in ipairs(deps) do
			if dep ~= prevRecord.deps[i] then
				shouldRun = true

				break
			end
		end
	elseif not deps then
		shouldRun = true
	end

	if shouldRun then
		if prevRecord and prevRecord.cleanup then
			table.insert(self.pending_effects, {cleanup = prevRecord.cleanup})
		end

		table.insert(
			self.pending_effects,
			{
				effect = effect,
				record = function(cleanup)
					states[idx] = {deps = deps, cleanup = cleanup}
				end,
			}
		)
	end
end

function META:UseMemo(compute, deps)
	local comp = self.current_component

	if not comp then error("can only be called inside a component", 2) end

	local idx = self.hook_index
	self.hook_index = self.hook_index + 1
	local states = self.component_states[comp]

	if not states then
		states = {}
		self.component_states[comp] = states
	end

	local cached = states[idx]

	if cached and cached.deps then
		local valid = true

		for i, dep in ipairs(deps) do
			if dep ~= cached.deps[i] then
				valid = false

				break
			end
		end

		if valid then return cached.value end
	end

	local value = compute()
	states[idx] = {value = value, deps = deps}
	return value
end

function META:UseCallback(fn, deps)
	return self:UseMemo(function()
		return fn
	end, deps)
end

function META:UseRef(initial)
	local comp = self.current_component

	if not comp then error("can only be called inside a component", 2) end

	local idx = self.hook_index
	self.hook_index = self.hook_index + 1
	local states = self.component_states[comp]

	if not states then
		states = {}
		self.component_states[comp] = states
	end

	if states[idx] == nil then states[idx] = {current = initial, isRef = true} end

	return states[idx]
end

function META:UseEvent(ref, what)
	local args, set_args = self:UseState({})

	self:UseEffect(
		function()
			if not ref.current then return end

			return ref.current:AddLocalListener(what, function(_, ...)
				set_args({...})
			end)
		end,
		{ref.current}
	)

	return unpack(args)
end

function META:RunPendingEffects()
	local effects = self.pending_effects
	self.pending_effects = {}

	for _, item in ipairs(effects) do
		if item.cleanup then item.cleanup() end

		if item.effect then
			local cleanup = item.effect()

			if item.record then item.record(cleanup) end
		end
	end
end

function META:Build(node, parent, existing, adapter)
	adapter = adapter or self.DefaultAdapter

	if node == nil or node == false then
		if existing then prototype.SafeRemove(existing) end

		return nil
	end

	if type(node) == "string" or type(node) == "number" then
		error("TODO")
		return nil
	end

	if type(node) == "function" then
		return self:Build(
			Component:CreateObject({
				build = node,
				props = {},
			}),
			parent,
			existing,
			adapter
		)
	end

	if type(node) == "table" and type(node[1]) == "function" and not node.Type then
		local fn = node[1]
		local props = {}

		for k, v in pairs(node) do
			if k ~= 1 then props[k] = v end
		end

		return self:Build(
			Component:CreateObject({
				build = fn,
				props = props,
			}),
			parent,
			existing,
			adapter
		)
	end

	if node.Type == "lsx_fragment" then
		-- fragments don't support reconciliation easily yet, recreate
		if existing then
			if type(existing) == "table" and existing.Type ~= "lsx_fragment" then
				prototype.SafeRemove(existing)
				existing = nil
			end
		end

		local panels = {}

		for i, child in ipairs(node.props) do
			local s = self:Build(child, parent, existing and existing[i], adapter)

			if s then table.insert(panels, s) end
		end

		if existing and #existing > #node.props then
			for i = #node.props + 1, #existing do
				prototype.SafeRemove(existing[i])
			end
		end

		return panels
	end

	if node.Type == "lsx_component" then
		if
			existing and
			type(existing) == "table" and
			existing.lsx_states and
			existing.lsx_states[node.build]
		then
			self.component_states[node] = existing.lsx_states[node.build]
		end

		node.render_scheduled = false
		node.adapter = adapter
		self.current_component = node
		self.hook_index = 0
		local rendered = node.build(node.props)
		self.current_component = nil
		local panel = self:Build(rendered, parent, existing, adapter)
		node.instance = panel

		if panel and type(panel) == "table" and panel.Remove then
			if not panel.lsx_states then panel.lsx_states = {} end

			panel.lsx_states[node.build] = self.component_states[node]
		end

		if existing and panel ~= existing then prototype.SafeRemove(existing) end

		if panel and type(panel) == "table" and panel.Remove then
			if node.props.ref then
				local value = node.props.ref

				if type(value) == "table" and value.isRef then
					value.current = panel
				elseif type(value) == "function" then
					value(panel)
				end
			end

			if node.props.Layout then
				if adapter.SetLayout then
					adapter.SetLayout(panel, node.props.Layout)
				elseif panel.SetLayout then
					panel:SetLayout(node.props.Layout)
				end

				if adapter.InvalidateLayout then
					adapter.InvalidateLayout(panel)
				elseif panel.InvalidateLayout then
					panel:InvalidateLayout()
				end
			end
		end

		return panel
	end

	if node.Type == "lsx_element" then
		-- create or update actual panel
		local panel = existing

		if
			not panel or
			panel.ctor ~= node.ctor or
			type(panel) ~= "table" or
			not panel.Remove
		then
			if panel then prototype.SafeRemove(panel) end

			panel = node.ctor(parent)
			panel.ctor = node.ctor
		end

		for key, value in pairs(node.props) do
			if type(key) ~= "number" and key ~= "Layout" then
				if key == "ref" then
					if type(value) == "table" and value.isRef then
						value.current = panel
					elseif type(value) == "function" then
						value(panel)
					end
				elseif adapter.SetProperty then
					adapter.SetProperty(panel, key, value)
				else
					local setterName = "Set" .. key:sub(1, 1):upper() .. key:sub(2)
					local method = panel[setterName]

					if method then
						local getterName = "Get" .. key:sub(1, 1):upper() .. key:sub(2)
						local getter = panel[getterName]
						local currentVal = getter and getter(panel)

						if currentVal ~= value then
							if not panel.IsAnimating or not panel:IsAnimating(key) then
								method(panel, value)
							end
						end
					elseif key:sub(1, 2) == "On" or key:sub(1, 2) == "on" then
						local eventName = "On" .. key:sub(3, 3):upper() .. key:sub(4)

						if panel[eventName] ~= value then panel[eventName] = value end
					end
				end
			end
		end

		local existingChildren = panel:GetChildren()
		local childrenToReconcile = {}

		for i = 1, #existingChildren do
			childrenToReconcile[i] = existingChildren[i]
		end

		for i, child in ipairs(node.props) do
			self:Build(child, panel, childrenToReconcile[i], adapter)
		end

		-- always set layout last because it depends on children and props like Size
		if node.props.Layout then
			if adapter.SetLayout then
				adapter.SetLayout(panel, node.props.Layout)
			elseif panel.SetLayout then
				panel:SetLayout(node.props.Layout)
			end

			if adapter.InvalidateLayout then
				adapter.InvalidateLayout(panel)
			elseif panel.InvalidateLayout then
				panel:InvalidateLayout()
			end
		end

		local finalChildren = panel:GetChildren()

		if #finalChildren > #node.props then
			for i = #finalChildren, #node.props + 1, -1 do
				prototype.SafeRemove(finalChildren[i])
			end
		end

		return panel
	end

	return nil
end

function META:Mount(node, parent, adapter)
	adapter = adapter or self.DefaultAdapter
	parent = parent or (adapter.GetRoot and adapter.GetRoot())
	local panel = self:Build(node, parent, nil, adapter)

	if adapter and adapter.PostRender then adapter.PostRender(panel) end

	self:RunPendingEffects()
	return panel
end

function META:MountTopLevel(fn, props, parent, adapter)
	local node = {fn}

	if props then
		for k, v in pairs(props) do
			if type(k) == "number" then node[k + 1] = v else node[k] = v end
		end
	end

	return self:Mount(node, parent, adapter)
end

function META.New(adapter)
	local self = META:CreateObject(
		{
			DefaultAdapter = adapter,
			component_states = setmetatable({}, {__mode = "k"}),
			pending_effects = {},
			pending_renders = {},
			hook_index = 0,
		}
	)

	event.AddListener("Update", self, function()
		for _, comp in ipairs(self.pending_renders) do
			local valid = comp.instance and comp.instance:IsValid()
			comp.render_scheduled = false

			if comp and comp.instance and valid then
				local parent = comp.instance:GetParent()
				self:Build(comp, parent, comp.instance, comp.adapter)

				if comp.adapter and comp.adapter.PostRender then
					comp.adapter.PostRender(comp.instance)
				end

				self:RunPendingEffects()
			end
		end

		table.clear(self.pending_renders)
	end)

	return self
end

return META:Register()
