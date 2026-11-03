local T = import("test/environment.lua")
local data_history = import("lua/data_history.lua")

T.Test("data history coalesces quick edits and steps through undo and redo", function()
	local data = {a = 1}
	local history = data_history.New(data)
	data.a = 2
	history:Commit(data, 10)
	data.a = 3
	history:Commit(data, 10.1)
	data.a = 4
	history:Commit(data, 12)
	T(#history.Undo)["=="](2)
	T(history:DoUndo().a)["=="](3)
	T(history:DoUndo().a)["=="](1)
	T(history:DoUndo())["=="](nil)
	T(history:DoRedo().a)["=="](3)
	T(history:DoRedo().a)["=="](4)
	T(history:DoRedo())["=="](nil)
	data.a = 5
	history:Commit(data, 20, true)
	history:DoUndo()
	data.a = 6
	history:Commit(data, 30, true)
	T(#history.Redo)["=="](0)
end)
