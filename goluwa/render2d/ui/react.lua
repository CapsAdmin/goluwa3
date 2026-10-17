local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = {}
local Descriptor = {}
Descriptor.__index = Descriptor

local function make_descriptor(type_, props)
	local desc_props = {}
	local children = {}

	if props then
		for key, value in pairs(props) do
			if type(key) == "string" then desc_props[key] = value end
		end

		for i = 1, table.maxn(props) do
			children[i] = props[i]
		end
	end

	if type_.is_component then desc_props.children = children end

	return setmetatable({type = type_, props = desc_props, children = children}, Descriptor)
end

function Descriptor:__call(children)
	self.children = {self.children, children}

	if self.type.is_component then self.props.children = self.children end

	return self
end

function react.Element(template)
	return function(props)
		return make_descriptor(template, props)
	end
end

function react.Component(render)
	return setmetatable(
		{render = render, is_component = true},
		{
			__call = function(self, props)
				return make_descriptor(self, props)
			end,
		}
	)
end

react.ErrorBoundary = react.Component(nil)
react.ErrorBoundary.is_boundary = true

-- skips rendering when the props are shallow equal (children only count as equal when there are none) and nothing inside asked for a render, pass stable callbacks (UseCallback, a context) or it never skips
function react.Memo(component)
	return setmetatable({render = component.render, is_component = true, memo = true}, getmetatable(component))
end

-- Context.Provider{Value = v}{children}, react.UseContext(Context) reads the nearest value and renders again when it changes
function react.CreateContext(default)
	local context = {default = default}
	context.Provider = react.Component(|props| -> props.children)
	context.Provider.context = context
	return context
end

-- Portal{Target = entity}{children} mounts the children under Target (a window under the world panel) and not under the parent they are written in, they go with the portal
react.Portal = react.Component(|props| -> props.children)
react.Portal.is_portal = true

-- hosts an entity made by code outside of react (Create(parent_entity) returns it), it is never updated, change the Key to build another one and it is removed with the node
react.Foreign = setmetatable(
	{is_foreign = true},
	{
		__call = function(self, props)
			return make_descriptor(self, props)
		end,
	}
)
react.Fragment = react.Component(|props| -> props.children)

local function flatten(items, out)
	for i = 1, table.maxn(items) do
		local item = items[i]

		if getmetatable(item) == Descriptor then
			out[#out + 1] = item
		elseif type(item) == "table" then
			flatten(item, out)
		elseif item and item ~= true then
			error("a child must be an element, a list of elements, nil or a boolean, got " .. tostring(item), 0)
		end
	end

	return out
end

-- plain tables are compared by content a few levels down, deeper than that (a list of assets that point at their folders and back) counts as changed
local function equal(a, b, depth)
	if a == b then return true end

	if type(a) ~= "table" or type(b) ~= "table" or getmetatable(a) or getmetatable(b) then
		return false
	end

	depth = depth or 0

	if depth >= 3 then return false end

	for key, value in pairs(a) do
		if not equal(value, b[key], depth + 1) then return false end
	end

	for key in pairs(b) do
		if a[key] == nil then return false end
	end

	return true
end

local function deps_equal(a, b)
	if not a or not b then return false end

	for i = 1, math.max(table.maxn(a), table.maxn(b)) do
		if a[i] ~= b[i] then return false end
	end

	return true
end

local function props_equal(a, b)
	for key, value in pairs(a) do
		if key == "children" then
			if flatten(value, {})[1] ~= nil or flatten(b.children, {})[1] ~= nil then return false end
		elseif value ~= b[key] then
			return false
		end
	end

	for key in pairs(b) do
		if a[key] == nil then return false end
	end

	return true
end

local current_inst
local hook_index = 0
local dirty = {}
local pending_effects = {}
local removed_hosts = {}
local inst_of_entity = setmetatable({}, {__mode = "k"})

-- an entity removed by someone else (a closed window) queues its node, the flush unmounts it so effects clean up
local function on_entity_removed(entity)
	local inst = inst_of_entity[entity]

	if inst and not inst.unmounted then removed_hosts[#removed_hosts + 1] = inst end
end

local function schedule(inst)
	if inst.unmounted or inst.dirty then return end

	inst.dirty = true
	dirty[#dirty + 1] = inst
end

local mount
local update
local unmount
local reconcile
local render_boundary

local function cleanup_hooks(inst)
	for _, hook in ipairs(inst.hooks) do
		if hook.provider then hook.provider.consumers[inst] = nil end

		if hook.cleanup then
			local cleanup = hook.cleanup
			hook.cleanup = nil
			cleanup()
		end

		hook.effect = nil
	end
end

local function on_error(err)
	return {error = err, trace = debug.traceback("", 2)}
end

local function fail(boundary, info)
	if boundary.error ~= nil then return end

	boundary.error = info
	logn("react error boundary caught: ", tostring(info.error), info.trace)
	schedule(boundary)
end

local function finish(boundary, ok, ...)
	if ok then return ... end

	fail(boundary, (...))
end

-- callbacks that run every frame (drawing, updates, mouse moves, hover) are left alone, an error there would tear the subtree down on a single bad frame and the xpcall would sit in hot code
local function is_guarded(key, value)
	return type(value) == "function" and
		key:starts_with("On") and
		not (
			key:find("Draw", 1, true) or
			key:find("Update", 1, true) or
			key:find("Move", 1, true) or
			key:find("Hover", 1, true) or
			key == "OnTransformChanged"
		)
end

local function guard_callback(boundary, callback)
	return function(...)
		return finish(boundary, xpcall(callback, on_error, ...))
	end
end

-- runs fn, and when it throws removes what it mounted halfway and records the error on the boundary, the caller schedules the fallback
local function guard(boundary, fn, a)
	local previous = boundary.created
	local created = {}
	boundary.created = created
	local ok, result = xpcall(fn, on_error, a)
	boundary.created = previous

	if ok then
		if previous then for _, inst in ipairs(created) do
			previous[#previous + 1] = inst
		end end

		return true, result
	end

	for i = #created, 1, -1 do
		local inst = created[i]
		inst.unmounted = true

		if inst.hooks then cleanup_hooks(inst) end

		if inst.entity and inst.entity:IsValid() then inst.entity:Remove() end
	end

	if boundary.error == nil then
		boundary.error = result
		logn("react error boundary caught: ", tostring(result.error), result.trace)
	end

	return false
end

local function collect(insts, out)
	for _, inst in ipairs(insts) do
		if inst.entity then
			out[#out + 1] = inst.entity
		elseif not inst.type.is_portal then
			collect(inst.children, out)
		end
	end

	return out
end

local function sync_order(host)
	local ents = collect(host.children, {})
	local previous = {}

	for i, ent in ipairs(host.ents) do
		previous[ent] = i
	end

	local need_reorder = false
	local seen_new = false
	local last = 0

	for _, ent in ipairs(ents) do
		local index = previous[ent]

		if index then
			if seen_new or index < last then
				need_reorder = true

				break
			end

			last = index
		else
			seen_new = true
		end
	end

	if need_reorder then for _, ent in ipairs(ents) do
		ent:BringToFront()
	end end

	host.ents = ents
end

local function set_ref(ref, entity)
	if ref == nil then return end

	if type(ref) == "function" then ref(entity) else ref.current = entity end
end

local function component_default(entity, component_key, sub_key)
	local cmp = entity.CMP and rawget(entity.CMP, component_key)

	if cmp and cmp[sub_key] ~= nil then return cmp[sub_key] end

	local info = objects.GetPropertyInfo(getmetatable(entity[component_key]), sub_key)
	return info and info.default
end

local function reset_prop(entity, key, old_value, valid_components)
	if key:starts_with("On") then
		entity[key] = nil

		return
	end

	if valid_components[key] then
		local reset = {}

		for sub_key in pairs(old_value) do
			reset[sub_key] = component_default(entity, key, sub_key)
		end

		entity:SetProp(key, reset)

		return
	end

	local info = objects.GetPropertyInfo(getmetatable(entity), key)

	if not info then for _, component in ipairs(entity.component_list) do
		info = objects.GetPropertyInfo(getmetatable(component), key)

		if info then break end
	end end

	entity:SetProp(key, info and info.default)
end

local function update_host(inst, desc)
	local entity = inst.entity
	local old = inst.props
	local new = desc.props
	local valid_components = Panel.GetValidComponents()

	for key, value in pairs(new) do
		if key ~= "Key" and key ~= "Ref" then
			local old_value = old[key]

			if valid_components[key] and type(value) == "table" then
				local changed

				for sub_key, sub_value in pairs(value) do
					if
						type(sub_key) == "string" and
						not equal(sub_value, type(old_value) == "table" and old_value[sub_key] or nil)
					then
						changed = changed or {}
						changed[sub_key] = sub_value
					end
				end

				if type(old_value) == "table" then
					for sub_key in pairs(old_value) do
						if type(sub_key) == "string" and value[sub_key] == nil then
							changed = changed or {}
							changed[sub_key] = component_default(entity, key, sub_key)
						end
					end
				end

				if changed then entity:SetProp(key, changed) end
			elseif not equal(value, old_value) then
				if inst.boundary and is_guarded(key, value) then
					value = guard_callback(inst.boundary, value)
				end

				entity:SetProp(key, value)
			end
		end
	end

	for key, old_value in pairs(old) do
		if new[key] == nil and key ~= "Key" and key ~= "Ref" then
			reset_prop(entity, key, old_value, valid_components)
		end
	end

	if type(new.Ref) == "table" and new.Ref ~= old.Ref then
		set_ref(old.Ref, nil)
		set_ref(new.Ref, entity)
	end

	inst.props = new
	inst.children = reconcile(inst.children, desc.children, entity, inst)
	sync_order(inst)
end

local function render_component(inst)
	if inst.type.is_boundary then return render_boundary(inst) end

	inst.dirty = false
	local previous_inst, previous_index = current_inst, hook_index
	current_inst, hook_index = inst, 0
	local out = inst.type.render(inst.props)
	current_inst, hook_index = previous_inst, previous_index
	inst.children = reconcile(inst.children, {out}, inst.parent_entity, inst)
end

function update(inst, desc)
	local type_ = inst.type

	if type_.is_foreign then return end

	if not type_.is_component then return update_host(inst, desc) end

	if inst.consumers and desc.props.Value ~= inst.props.Value then
		for consumer in pairs(inst.consumers) do
			schedule(consumer)
		end
	end

	if type_.memo and not inst.dirty and props_equal(inst.props, desc.props) then return end

	inst.props = desc.props
	render_component(inst)
end

function mount(desc, parent_entity, parent)
	local type_ = desc.type
	local inst = {
		type = type_,
		key = desc.props.Key,
		props = desc.props,
		parent_entity = parent_entity,
		depth = parent.depth + 1,
		parent = parent,
		host_inst = parent.entity and parent or parent.host_inst,
		children = {},
		boundary = parent.boundary,
		is_boundary = type_.is_boundary,
	}

	if parent.is_boundary and parent.error == nil then inst.boundary = parent end

	if inst.boundary and inst.boundary.created then
		inst.boundary.created[#inst.boundary.created + 1] = inst
	end

	if type_.is_foreign then
		inst.entity = desc.props.Create(parent_entity)
		parent_entity:AddChild(inst.entity)

		return inst
	end

	if type_.is_component then
		inst.hooks = {}

		if type_.context then inst.consumers = {} end

		if type_.is_portal then inst.parent_entity = desc.props.Target end

		if inst.is_boundary then
			inst.reset = function()
				inst.error = nil
				schedule(inst)
			end
		end

		render_component(inst)

		return inst
	end

	local construct = {}

	for key, value in pairs(desc.props) do
		if key ~= "Key" and key ~= "Ref" then
			if inst.boundary and is_guarded(key, value) then
				value = guard_callback(inst.boundary, value)
			end

			construct[key] = value
		end
	end

	construct.Parent = parent_entity
	inst.entity = type_.New(construct)
	inst_of_entity[inst.entity] = inst
	inst.entity:CallOnRemove(on_entity_removed, "react")
	inst.children = reconcile({}, desc.children, inst.entity, inst)
	inst.ents = collect(inst.children, {})
	set_ref(desc.props.Ref, inst.entity)
	return inst
end

function unmount(inst, remove_entity)
	if inst.unmounted then return end

	inst.unmounted = true

	if inst.type.is_component then
		cleanup_hooks(inst)

		for _, child in ipairs(inst.children) do
			unmount(child, remove_entity or inst.type.is_portal)
		end

		return
	end

	for _, child in ipairs(inst.children) do
		unmount(child, false)
	end

	set_ref(inst.props.Ref, nil)

	if remove_entity and inst.entity:IsValid() then inst.entity:Remove() end
end

function reconcile(old, descs, parent_entity, parent)
	local flat = flatten(descs, {})
	local keyed = {}
	local used = {}
	local matched = {}
	local new = {}

	for _, inst in ipairs(old) do
		if inst.key ~= nil then keyed[inst.key] = inst end
	end

	for i, desc in ipairs(flat) do
		local key = desc.props.Key
		local inst

		if key ~= nil then
			inst = keyed[key]
		else
			inst = old[i]

			if inst and inst.key ~= nil then inst = nil end
		end

		if
			inst and
			not used[inst] and
			not inst.unmounted and
			inst.type == desc.type and
			(not inst.entity or inst.entity:IsValid())
		then
			used[inst] = true
			matched[i] = inst
		end
	end

	-- what goes away is removed before anything new is mounted, a widget that limits its children (splitter) never sees both
	for _, inst in ipairs(old) do
		if not used[inst] then unmount(inst, true) end
	end

	for i, desc in ipairs(flat) do
		local inst = matched[i]

		if inst then
			update(inst, desc)
		else
			inst = mount(desc, parent_entity, parent)
		end

		new[i] = inst
	end

	return new
end

local function reconcile_children(inst)
	inst.children = reconcile(inst.children, inst.props.children, inst.parent_entity, inst)
end

function render_boundary(inst)
	inst.dirty = false

	if inst.error == nil then
		if inst.fallback_shown then
			for _, child in ipairs(inst.children) do
				unmount(child, true)
			end

			inst.children = {}
			inst.fallback_shown = false
		end

		if guard(inst, reconcile_children, inst) then return end
	end

	if not inst.fallback_shown then
		for _, child in ipairs(inst.children) do
			unmount(child, true)
		end

		inst.children = {}
		inst.fallback_shown = true
	end

	local info = inst.error
	local fallback = inst.props.Fallback(info.error, inst.reset, info.trace)
	inst.children = reconcile(inst.children, {fallback}, inst.parent_entity, inst)
end

do -- hooks
	local function use_hook()
		hook_index = hook_index + 1
		local hooks = current_inst.hooks
		local hook = hooks[hook_index]

		if hook then return hook, false end

		hook = {}
		hooks[hook_index] = hook
		return hook, true
	end

	function react.UseState(initial)
		local hook, is_new = use_hook()

		if is_new then
			local inst = current_inst

			if type(initial) == "function" then initial = initial() end

			hook.value = initial

			hook.set = function(value)
				if type(value) == "function" then value = value(hook.value) end

				if value == hook.value then return end

				hook.value = value
				schedule(inst)
			end
		end

		return hook.value, hook.set
	end

	function react.UseReducer(reducer, initial)
		local value, set = react.UseState(initial)
		local hook = current_inst.hooks[hook_index]

		if not hook.dispatch then
			hook.dispatch = function(action)
				set(|current| -> reducer(current, action))
			end
		end

		return value, hook.dispatch
	end

	function react.UseRef(initial)
		local hook, is_new = use_hook()

		if is_new then hook.ref = {current = initial} end

		return hook.ref
	end

	function react.UseMemo(compute, deps)
		local hook, is_new = use_hook()

		if is_new or not deps_equal(hook.deps, deps) then
			hook.deps = deps
			hook.value = compute()
		end

		return hook.value
	end

	function react.UseCallback(callback, deps)
		return react.UseMemo(|| -> callback, deps)
	end

	function react.UseContext(context)
		local hook, is_new = use_hook()

		if is_new then
			local provider = current_inst.parent

			while provider and not (provider.type and provider.type.context == context) do
				provider = provider.parent
			end

			if provider then
				hook.provider = provider
				provider.consumers[current_inst] = true
			end
		end

		if hook.provider then return hook.provider.props.Value end

		return context.default
	end

	-- calls callback (the latest one, no need to memoize it) for every event_name event while the component is mounted
	function react.UseEvent(event_name, callback)
		local latest = react.UseRef()
		latest.current = callback

		react.UseEffect(function()
			local id = {}

			event.AddListener(event_name, id, function(...)
				return latest.current(...)
			end)

			return function()
				event.RemoveListener(event_name, id)
			end
		end, {event_name})
	end

	-- create() runs on the first render and again when deps change (never without deps), dispose(value) when it is replaced or the component unmounts, a boundary that tears a half built subtree down included
	function react.UseResource(create, dispose, deps)
		local hook, is_new = use_hook()
		deps = deps or {}

		if is_new or not deps_equal(hook.deps, deps) then
			if hook.cleanup then hook.cleanup() end

			local value = create()
			hook.deps = deps
			hook.value = value
			hook.cleanup = function()
				dispose(value)
			end
		end

		return hook.value
	end

	-- fn() on the first render and again every interval seconds (every frame without one) while mounted, the result is state so each poll renders, give it a result that is worth a render
	function react.UsePoll(fn, interval)
		local value, set_value = react.UseState(fn)
		local latest = react.UseRef()
		local last_poll = react.UseRef()
		latest.current = fn

		if not last_poll.current then last_poll.current = system.GetElapsedTime() end

		react.UseEvent("Update", function()
			local now = system.GetElapsedTime()

			if now - last_poll.current >= (interval or 0) then
				last_poll.current = now
				set_value(latest.current())
			end
		end)

		return value
	end

	-- value once it has stayed the same for delay seconds
	function react.UseDebounce(value, delay)
		local debounced, set_debounced = react.UseState(value)
		local pending = react.UseRef()

		react.UseEffect(function()
			pending.current = {value = value, deadline = system.GetElapsedTime() + delay}
		end, {value})

		react.UseEvent("Update", function()
			local change = pending.current

			if change and system.GetElapsedTime() >= change.deadline then
				pending.current = nil
				set_debounced(change.value)
			end
		end)

		return debounced
	end

	function react.UseEffect(effect, deps)
		local hook, is_new = use_hook()

		if is_new or not deps_equal(hook.deps, deps) then
			hook.deps = deps
			hook.effect = effect
			hook.inst = current_inst
			pending_effects[#pending_effects + 1] = hook
		end
	end
end

local function is_alive(inst)
	if not inst.parent_entity:IsValid() then return false end

	local ents = collect(inst.children, {})

	for _, ent in ipairs(ents) do
		if ent:IsValid() then return true end
	end

	return ents[1] == nil
end

local function render_dirty(inst)
	render_component(inst)
	sync_order(inst.host_inst)
end

local function by_depth(a, b)
	return a.depth < b.depth
end

function react.Flush()
	local passes = 0

	while dirty[1] or pending_effects[1] or removed_hosts[1] do
		passes = passes + 1

		if passes > 50 then error("too many re-renders, a state update keeps triggering itself", 0) end

		local removed = removed_hosts
		removed_hosts = {}

		for _, inst in ipairs(removed) do
			unmount(inst, false)
			local ancestor = inst.parent

			while ancestor and ancestor.type do
				if ancestor.type.is_component and not ancestor.unmounted then
					if is_alive(ancestor) then break end

					unmount(ancestor, false)
				end

				ancestor = ancestor.parent
			end
		end

		local list = dirty
		dirty = {}
		table.sort(list, by_depth)

		for _, inst in ipairs(list) do
			if inst.dirty and not inst.unmounted then
				if is_alive(inst) then
					if inst.boundary then
						if not guard(inst.boundary, render_dirty, inst) then schedule(inst.boundary) end
					else
						render_dirty(inst)
					end
				else
					unmount(inst, false)
				end
			end
		end

		local effects = pending_effects
		pending_effects = {}

		for _, hook in ipairs(effects) do
			local effect = hook.effect

			if effect and not hook.inst.unmounted then
				hook.effect = nil

				if hook.cleanup then hook.cleanup() end

				local boundary = hook.inst.boundary
				local cleanup

				if boundary then
					local ok, result = guard(boundary, effect)

					if ok then cleanup = result else schedule(boundary) end
				else
					cleanup = effect()
				end

				hook.cleanup = type(cleanup) == "function" and cleanup or nil
			end
		end
	end
end

event.AddListener("Update", "ui_react", react.Flush)
local Root = {}
Root.__index = Root

function react.Mount(desc, parent_entity)
	parent_entity = parent_entity or Panel.World
	local root = setmetatable({entity = parent_entity, depth = 0, children = {}, ents = {}}, Root)
	root:Render(desc)
	return root
end

function Root:Render(desc)
	self.children = reconcile(self.children, {desc}, self.entity, self)
	sync_order(self)
	react.Flush()
	return self
end

function Root:GetEntity()
	return self.ents[1]
end

function Root:Unmount()
	for _, inst in ipairs(self.children) do
		unmount(inst, true)
	end

	self.children = {}
	self.ents = {}
end

return react
