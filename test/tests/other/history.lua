local T = import("test/environment.lua")
local History = import("goluwa/history.lua")

local function make_counter(history, name, key)
	local state = {value = 0}

	function state.Set(value)
		local old = state.value
		state.value = value
		history:Push{
			Name = name,
			Key = key,
			Undo = function()
				state.value = old
			end,
			Redo = function()
				state.value = value
			end,
		}
	end

	return state
end

T.Test("history undo redo and branching", function()
	local history = History.New()
	local state = make_counter(history, "set")
	state.Set(1)
	state.Set(2)
	state.Set(3)
	T(state.value)["=="](3)
	history:Undo()
	T(state.value)["=="](2)
	history:GoTo(0)
	T(state.value)["=="](0)
	history:Redo()
	T(state.value)["=="](1)
	state.Set(10)
	T(history:CanRedo())["=="](false)
	T(#history:GetEntries())["=="](2)
	history:GoTo(2)
	T(state.value)["=="](10)
end)

T.Test("history groups and merges", function()
	local history = History.New()
	local a = make_counter(history, "a")
	local b = make_counter(history, "b")
	history:Begin("both")
	a.Set(1)
	b.Set(2)
	history:End()
	T(#history:GetEntries())["=="](1)
	history:Undo()
	T(a.value + b.value)["=="](0)
	history:Redo()
	T(a.value + b.value)["=="](3)
	history:Clear()
	local slider = make_counter(history, "slider", "key")
	slider.Set(1)
	slider.Set(2)
	slider.Set(3)
	T(#history:GetEntries())["=="](1)
	history:Undo()
	T(slider.value)["=="](0)
	history:Redo()
	T(slider.value)["=="](3)
end)

T.Test("history ignores pushes while applying", function()
	local history = History.New()
	local state = make_counter(history, "set")
	state.Set(1)
	history.entries[1].Undo = function()
		state.Set(5)
	end
	history:Undo()
	T(#history:GetEntries())["=="](1)
end)
