local event = require("event")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local window = require("window")
local timer = require("timer")
local gui = require("gui.gui")
local lsx = {}

do
	local Element = {__name = "lsx.RegisterElement"}
	Element.__index = Element

	function lsx.Fragment(props)
		return setmetatable({
			type = "fragment",
			children = props,
		}, Element)
	end

	function lsx.RegisterElement(surfaceType)
		return function(props)
			props = props or {}
			local actualProps = {}
			local children = {}

			for k, v in pairs(props) do
				if type(k) == "number" then
					children[k] = v
				else
					actualProps[k] = v
				end
			end

			-- Compact children array
			local compacted = {}

			for _, child in ipairs(children) do
				if child ~= nil then compacted[#compacted + 1] = child end
			end

			return setmetatable(
				{
					type = "element",
					surfaceType = surfaceType,
					props = actualProps or {},
					children = compacted or {},
				},
				Element
			)
		end
	end
end

do
	local Component = {__name = "lsx.Component"}
	Component.__index = Component

	function lsx.Component(fn)
		return function(props)
			props = props or {}
			local actualProps = {}
			local children = {}

			for k, v in pairs(props) do
				if type(k) == "number" then
					children[k] = v
				else
					actualProps[k] = v
				end
			end

			actualProps.children = children
			return setmetatable(
				{
					type = "component",
					build = fn,
					props = props or {},
					children = children or {},
				},
				Component
			)
		end
	end
end

lsx.Panel = lsx.RegisterElement("base")
lsx.hook_index = 0

local function increment_hook_index()
	local idx = lsx.hook_index
	lsx.hook_index = lsx.hook_index + 1
	return idx
end

do -- hooks
	lsx.component_states = setmetatable({}, {__mode = "k"})
	lsx.pending_effects = {}

	function lsx.UseState(initial)
		local comp = lsx.current_component

		if not comp then error("can only be called inside a component", 2) end

		local idx = increment_hook_index()
		local states = lsx.component_states[comp]

		if not states then
			states = {}
			lsx.component_states[comp] = states
		end

		if states[idx] == nil then
			if type(initial) == "function" then
				states[idx] = initial()
			else
				states[idx] = initial
			end
		end

		local function setState(newValue)
			local oldValue = states[idx]

			if type(newValue) == "function" then
				states[idx] = newValue(oldValue)
			else
				states[idx] = newValue
			end

			if comp.instance then
				event.AddListener("Update", {}, function()
					if comp and comp.instance and comp.instance:IsValid() then
						local parent = comp.instance:GetParent()
						lsx.Build(comp, parent, comp.instance)
						lsx.RunPendingEffects()
					end

					return event.destroy_tag
				end)
			end
		end

		return states[idx], setState
	end

	function lsx.UseEffect(effect, deps)
		local comp = lsx.current_component

		if not comp then error("can only be called inside a component", 2) end

		local idx = increment_hook_index()
		local states = lsx.component_states[comp]

		if not states then
			states = {}
			lsx.component_states[comp] = states
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
				lsx.pending_effects[#lsx.pending_effects + 1] = {cleanup = prevRecord.cleanup}
			end

			lsx.pending_effects[#lsx.pending_effects + 1] = {
				effect = effect,
				record = function(cleanup)
					states[idx] = {deps = deps, cleanup = cleanup}
				end,
			}
		end
	end

	function lsx.UseMemo(compute, deps)
		local comp = lsx.current_component

		if not comp then error("can only be called inside a component", 2) end

		local idx = increment_hook_index()
		local states = lsx.component_states[comp]

		if not states then
			states = {}
			lsx.component_states[comp] = states
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

	function lsx.UseCallback(fn, deps)
		return lsx.UseMemo(function()
			return fn
		end, deps)
	end

	function lsx.UseRef(initial)
		local comp = lsx.current_component

		if not comp then error("can only be called inside a component", 2) end

		local idx = increment_hook_index()
		local states = lsx.component_states[comp]

		if not states then
			states = {}
			lsx.component_states[comp] = states
		end

		if states[idx] == nil then states[idx] = {current = initial, isRef = true} end

		return states[idx]
	end
end

function lsx.RunPendingEffects()
	local effects = lsx.pending_effects
	lsx.pending_effects = {}

	for _, item in ipairs(effects) do
		if item.cleanup then item.cleanup() end

		if item.effect then
			local cleanup = item.effect()

			if item.record then item.record(cleanup) end
		end
	end
end

function lsx.Build(node, parent, existing)
	if node == nil then
		if existing then existing:Remove() end

		return nil
	end

	if type(node) == "string" or type(node) == "number" then
		error("TODO")
		return nil
	end

	if node.type == "fragment" then
		-- fragments don't support reconciliation easily yet, recreate
		if existing then existing:Remove() end

		local surfaces = {}

		for _, child in ipairs(node.children) do
			local s = lsx.Build(child, parent)

			if s then surfaces[#surfaces + 1] = s end
		end

		return surfaces
	end

	if node.type == "component" then
		lsx.current_component = node
		lsx.hook_index = 0
		local rendered = node.build(node.props)
		lsx.current_component = nil
		local surface = lsx.Build(rendered, parent, existing)
		node.instance = surface
		return surface
	end

	if node.type == "element" then
		-- create or update actual surface
		local surface = existing

		if not surface or surface.surfaceType ~= node.surfaceType then
			if surface then surface:Remove() end

			surface = gui.Create(node.surfaceType, parent)
			surface.surfaceType = node.surfaceType
		end

		for key, value in pairs(node.props) do
			local setterName = "Set" .. key:sub(1, 1):upper() .. key:sub(2)
			local method = surface[setterName]

			if method then
				method(surface, value)
			elseif key:sub(1, 2) == "On" or key:sub(1, 2) == "on" then
				local eventName = "On" .. key:sub(3, 3):upper() .. key:sub(4)
				surface[eventName] = value
			elseif key == "ref" then
				if type(value) == "table" and value.isRef then
					value.current = surface
				elseif type(value) == "function" then
					value(surface)
				end
			end
		end

		local existingChildren = surface:GetChildren()
		local childrenToReconcile = {}

		for i, v in ipairs(existingChildren) do
			childrenToReconcile[i] = v
		end

		for i, child in ipairs(node.children) do
			lsx.Build(child, surface, childrenToReconcile[i])
		end

		for i = #node.children + 1, #childrenToReconcile do
			childrenToReconcile[i]:Remove()
		end

		return surface
	end

	return nil
end

function lsx.Mount(node, parent)
	parent = parent or gui.Root
	local surface = lsx.Build(node, parent)
	lsx.RunPendingEffects()
	return surface
end

function lsx.Inspect(node, indent)
	indent = indent or 0
	local pad = string.rep("  ", indent)

	if node == nil then
		return pad .. "nil"
	elseif type(node) == "string" then
		return pad .. "\"" .. node .. "\""
	elseif type(node) == "number" then
		return pad .. tostring(node)
	elseif node.type == "fragment" then
		local lines = {pad .. "Fragment {"}

		for _, child in ipairs(node.children) do
			lines[#lines + 1] = lsx.inspect(child, indent + 1)
		end

		lines[#lines + 1] = pad .. "}"
		return table.concat(lines, "\n")
	elseif node.type == "component" then
		return pad .. "Component()"
	elseif node.type == "element" then
		local props_str = {}

		for k, v in pairs(node.props) do
			if type(v) ~= "function" then
				props_str[#props_str + 1] = k .. "=" .. tostring(v)
			end
		end

		local lines = {pad .. node.surfaceType .. " { " .. table.concat(props_str, ", ")}

		for _, child in ipairs(node.children) do
			lines[#lines + 1] = lsx.inspect(child, indent + 1)
		end

		lines[#lines + 1] = pad .. "}"
		return table.concat(lines, "\n")
	end

	return pad .. tostring(node)
end

return lsx
