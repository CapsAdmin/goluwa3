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
local Fragment = prototype.CreateTemplate("lsx_fragment")
Fragment:Register()

function lsx.Fragment(props)
	return Fragment:CreateObject({props = props or {}})
end

local Element = prototype.CreateTemplate("lsx_element")
Element:Register()

function lsx.RegisterElement(surfaceType)
	return function(props)
		return Element:CreateObject({
			surfaceType = surfaceType,
			props = props or {},
		})
	end
end

local Component = prototype.CreateTemplate("lsx_component")
Component:Register()

function lsx.Component(fn)
	return function(props)
		return Component:CreateObject({
			build = fn,
			props = props or {},
		})
	end
end

lsx.Panel = lsx.RegisterElement("base")
lsx.Text = lsx.RegisterElement("text")

function lsx.Value(fn)
	return {__lsx_value = fn}
end

function lsx.Pauser(fn)
	return {__lsx_pauser = fn}
end

lsx.hook_index = 0

local function increment_hook_index()
	local idx = lsx.hook_index
	lsx.hook_index = lsx.hook_index + 1
	return idx
end

do -- hooks
	lsx.component_states = setmetatable({}, {__mode = "k"})
	lsx.pending_effects = {}
	lsx.pending_renders = {}

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
				table.insert(lsx.pending_renders, comp)
			end
		end

		return states[idx], setState
	end

	event.AddListener("Update", "lsx_render", function()
		for _, comp in ipairs(lsx.pending_renders) do
			comp.render_scheduled = false

			if comp and comp.instance and comp.instance:IsValid() then
				local parent = comp.instance:GetParent()
				lsx.Build(comp, parent, comp.instance)

				if gui.Root and gui.Root.CalcLayout then gui.Root:CalcLayout() end

				lsx.RunPendingEffects()
			end
		end

		table.clear(lsx.pending_renders)
	end)

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

	function lsx.UseAnimation(ref)
		return lsx.UseCallback(
			function(config)
				if ref.current then ref.current:Animate(config) end
			end,
			{ref}
		)
	end

	function lsx.UseMouse()
		local pos, set_pos = lsx.UseState(function()
			local mpos = window.GetMousePosition()
			return Vec2(mpos.x, mpos.y)
		end)

		lsx.UseEffect(
			function()
				return event.AddListener("Update", "lsx_use_mouse", function()
					local mpos = window.GetMousePosition()

					set_pos(function(old)
						if old.x == mpos.x and old.y == mpos.y then return old end

						return Vec2(mpos.x, mpos.y)
					end)
				end)
			end,
			{}
		)

		return pos
	end

	function lsx.UseHover(ref)
		local is_hovered, set_hovered = lsx.UseState(false)
		local mouse = lsx.UseMouse()

		lsx.UseEffect(
			function()
				if not ref.current then return end

				set_hovered(ref.current:IsHovered(mouse))
			end,
			{mouse.x, mouse.y}
		)

		return is_hovered
	end

	function lsx.UseHoverExclusively(ref)
		local is_hovered, set_hovered = lsx.UseState(false)
		local mouse = lsx.UseMouse()

		lsx.UseEffect(
			function()
				if not ref.current then return end

				set_hovered(ref.current:IsHoveredExclusively(mouse))
			end,
			{mouse.x, mouse.y}
		)

		return is_hovered
	end

	function lsx.UseAnimate(ref, config, deps)
		lsx.UseEffect(
			function()
				if not ref.current then return end

				ref.current:Animate(config)
			end,
			deps
		)
	end

	function lsx.UsePress(ref, button)
		button = button or "button_1"
		local is_pressed, set_pressed = lsx.UseState(false)

		lsx.UseEffect(
			function()
				if not ref.current then return end

				return ref.current:AddLocalListener("MouseInput", function(self, btn, press)
					if btn ~= button then return end

					set_pressed(press)
				end)
			end,
			{ref.current}
		)

		return is_pressed
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

local function safe_remove(obj)
	if not obj then return end

	if type(obj) == "table" and not obj.Remove then
		for _, v in ipairs(obj) do
			safe_remove(v)
		end

		return
	end

	if obj.UnParent then obj:UnParent() end

	prototype.SafeRemove(obj)
end

function lsx.Build(node, parent, existing)
	if node == nil or node == false then
		if existing then safe_remove(existing) end

		return nil
	end

	if type(node) == "string" or type(node) == "number" then
		error("TODO")
		return nil
	end

	if node.Type == "lsx_fragment" then
		-- fragments don't support reconciliation easily yet, recreate
		if existing then
			if type(existing) == "table" and existing.Type ~= "lsx_fragment" then
				safe_remove(existing)
				existing = nil
			end
		end

		local surfaces = {}

		for i, child in ipairs(node.props) do
			local s = lsx.Build(child, parent, existing and existing[i])

			if s then table.insert(surfaces, s) end
		end

		if existing and #existing > #node.props then
			for i = #node.props + 1, #existing do
				safe_remove(existing[i])
			end
		end

		return surfaces
	end

	if node.Type == "lsx_component" then
		node.render_scheduled = false
		lsx.current_component = node
		lsx.hook_index = 0
		local rendered = node.build(node.props)
		lsx.current_component = nil
		local surface = lsx.Build(rendered, parent, existing)
		node.instance = surface

		if existing and surface ~= existing then safe_remove(existing) end

		if surface and type(surface) == "table" and surface.Remove then
			if node.props.ref then
				local value = node.props.ref

				if type(value) == "table" and value.isRef then
					value.current = surface
				elseif type(value) == "function" then
					value(surface)
				end
			end

			if node.props.Layout then surface:SetLayout(node.props.Layout) end
		end

		return surface
	end

	if node.Type == "lsx_element" then
		-- create or update actual surface
		local surface = existing

		if
			not surface or
			surface.surfaceType ~= node.surfaceType or
			type(surface) ~= "table" or
			not surface.Remove
		then
			if surface then safe_remove(surface) end

			surface = gui.Create(node.surfaceType, parent)
			surface.surfaceType = node.surfaceType
		end

		for key, value in pairs(node.props) do
			if type(key) ~= "number" and key ~= "Layout" then
				local setterName = "Set" .. key:sub(1, 1):upper() .. key:sub(2)
				local method = surface[setterName]

				if method then
					local getterName = "Get" .. key:sub(1, 1):upper() .. key:sub(2)
					local getter = surface[getterName]
					local currentVal = getter and getter(surface)

					if currentVal ~= value then
						if not surface.IsAnimating or not surface:IsAnimating(key) then
							method(surface, value)
						end
					end
				elseif key:sub(1, 2) == "On" or key:sub(1, 2) == "on" then
					local eventName = "On" .. key:sub(3, 3):upper() .. key:sub(4)

					if surface[eventName] ~= value then surface[eventName] = value end
				elseif key == "ref" then
					if type(value) == "table" and value.isRef then
						value.current = surface
					elseif type(value) == "function" then
						value(surface)
					end
				end
			end
		end

		local existingChildren = surface:GetChildren()
		local childrenToReconcile = {}

		for i = 1, #existingChildren do
			childrenToReconcile[i] = existingChildren[i]
		end

		for i, child in ipairs(node.props) do
			lsx.Build(child, surface, childrenToReconcile[i])
		end

		-- always set layout last because it depends on children and props like Size
		if node.props.Layout then
			surface:SetLayout(node.props.Layout)
			surface:InvalidateLayout()
		end

		local finalChildren = surface:GetChildren()

		if #finalChildren > #node.props then
			for i = #finalChildren, #node.props + 1, -1 do
				safe_remove(finalChildren[i])
			end
		end

		return surface
	end

	return nil
end

function lsx.Mount(node, parent)
	parent = parent or gui.Root
	local surface = lsx.Build(node, parent)

	if gui.Root and gui.Root.CalcLayout then gui.Root:CalcLayout() end

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
	elseif node.Type == "lsx_fragment" then
		local lines = {pad .. "Fragment {"}

		for _, child in ipairs(node.props) do
			lines[#lines + 1] = lsx.Inspect(child, indent + 1)
		end

		lines[#lines + 1] = pad .. "}"
		return table.concat(lines, "\n")
	elseif node.Type == "lsx_component" then
		return pad .. "Component()"
	elseif node.Type == "lsx_element" then
		local props_str = {}

		for k, v in pairs(node.props) do
			if type(k) ~= "number" and type(v) ~= "function" then
				props_str[#props_str + 1] = k .. "=" .. tostring(v)
			end
		end

		local lines = {pad .. node.surfaceType .. " { " .. table.concat(props_str, ", ")}

		for _, child in ipairs(node.props) do
			lines[#lines + 1] = lsx.Inspect(child, indent + 1)
		end

		lines[#lines + 1] = pad .. "}"
		return table.concat(lines, "\n")
	end

	return pad .. tostring(node)
end

return lsx
