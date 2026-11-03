local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Collapsible = import("goluwa/render2d/ui/widgets/collapsible.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local PropertyNumber = import("goluwa/render2d/ui/widgets/properties/number.lua")
local PropertyVector = import("goluwa/render2d/ui/widgets/properties/vector.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Dock = import("goluwa/render2d/ui/widgets/dock.lua")

T.Test2D("template component defaults merge with given tables and never leak between instances", function()
	local default = Row{}
	local custom = Row{layout = {ChildGap = 3, GrowWidth = 0}}
	local after = Row{}
	T(default.layout:GetDirection())["=="]("x")
	T(custom.layout:GetDirection())["=="]("x")
	T(custom.layout:GetChildGap())["=="](3)
	T(custom.layout:GetGrowWidth())["=="](0)
	T(after.layout:GetChildGap())["=="](default.layout:GetChildGap())
	T(after.layout:GetGrowWidth())["=="](1)
	default:Remove()
	custom:Remove()
	after:Remove()
end)

T.Test2D("clickable ignores clicks while disabled and mirrors its properties into theme state", function()
	local clicks = 0
	local enabled = Clickable{
		Mode = "outline",
		OnClick = function()
			clicks = clicks + 1
		end,
	}
	local disabled = Clickable{
		Disabled = true,
		OnClick = function()
			clicks = clicks + 1
		end,
	}
	T(enabled:GetState("mode"))["=="]("outline")
	T(disabled:GetState("disabled"))["=="](true)
	T(disabled.clickable:GetDisabled())["=="](true)
	enabled:CallLocalEvent("OnClick")
	T(clicks)["=="](1)
	enabled:SetDisabled(true)
	T(enabled:GetState("disabled"))["=="](true)
	enabled:SetActive(true)
	T(enabled:GetState("active"))["=="](true)
	enabled:Remove()
	disabled:Remove()
end)

T.Test2D("button keeps its label when children are replaced and updates it with SetText", function()
	local button = Button{Text = "first"}
	T(button.label.text:GetText())["=="]("first")
	button:SetText("second")
	T(button.label.text:GetText())["=="]("second")
	T(button.Text)["=="]("second")
	local extra = Text{Text = "extra"}
	button{extra}
	T(button.label:IsValid())["=="](true)
	T(extra:GetParent())["=="](button)
	button{}
	T(button.label:IsValid())["=="](true)
	T(extra:IsValid())["=="](false)
	button:Remove()
end)

T.Test2D("checkbox and slider notify only when asked to", function()
	local changes = {}
	local checkbox = Checkbox{
		Value = true,
		OnChange = function(value)
			changes[#changes + 1] = value
		end,
	}
	checkbox:SetValue(false)
	T(#changes)["=="](0)
	checkbox:SetValue(true, true)
	T(changes[1])["=="](true)
	T(checkbox:GetState("value"))["=="](true)
	local values = {}
	local slider = Slider{
		Value = 0.25,
		OnChange = function(value)
			values[#values + 1] = value
		end,
	}
	T(slider:GetState("value"))["=="](0.25)
	slider:SetValue(0.75, true)
	T(values[1])["=="](0.75)
	checkbox:Remove()
	slider:Remove()
end)

T.Test2D("collapsible honors Collapsed, forwards children to its body and reports toggles", function()
	local toggles = {}
	local collapsible = Collapsible{
		Title = "Section",
		Collapsed = true,
		OnToggle = function(collapsed)
			toggles[#toggles + 1] = collapsed
		end,
	}
	T(collapsible.OpenFraction)["=="](0)
	local child = Text{Text = "inside"}
	collapsible{child}
	T(child:GetParent())["=="](collapsible._body)
	collapsible:SetCollapsed(false)
	T(toggles[1])["=="](false)
	T(collapsible.Collapsed)["=="](false)
	collapsible:Remove()
end)

T.Test2D("window forwards children to its content and removes itself on close", function()
	local window = Window{Title = "Test", Size = Vec2(300, 200)}
	local child = Text{Text = "content"}
	window{child}
	T(child:GetParent())["=="](window._content)
	window:SetTitle("Renamed")
	T(window._title.text:GetText())["=="]("Renamed")
	T(window.resizable:GetMinimumSize().x)["=="](100)
	window:OnClose()
	T(window:IsValid())["=="](false)
end)

T.Test2D("window maximizes, snaps to halves, restores and aligns to siblings", function()
	local a = Window{Title = "A", Size = Vec2(300, 200), Position = Vec2(50, 60)}
	local b = Window{Title = "B", Size = Vec2(250, 200), Position = Vec2(500, 100)}
	local world = Panel.World.transform:GetSize()
	a:Maximize()
	T(a:IsMaximized())["=="](true)
	T(a.transform:GetSize().x)["=="](world.x)
	a:ToggleMaximize()
	T(a:IsMaximized())["=="](false)
	T(a.transform:GetPosition().x)["=="](50)
	T(a.transform:GetSize().x)["=="](300)
	a.snappable:Snap("left")
	T(a.transform:GetSize().x)["=="](world.x / 2)
	T(a.transform:GetSize().y)["=="](world.y)
	a.snappable:Unsnap()
	T(a.transform:GetSize().x)["=="](300)
	local aligned = b.snappable:Align(Vec2(356, 63))
	T(aligned.x)["=="](350)
	T(aligned.y)["=="](60)
	a:Remove()
	b:Remove()
end)

T.Test2D("window minimizes into the dock and restores from it", function()
	local window = Window{Title = "Dock me"}
	local dock = Dock.GetInstance()
	window:Minimize()
	T(window:IsMinimized())["=="](true)
	T(window.visual:GetVisible())["=="](false)
	T(dock:HasItem(window))["=="](true)
	dock:ActivateItem(window)
	T(window:IsMinimized())["=="](false)
	T(window.visual:GetVisible())["=="](true)
	T(dock:HasItem(window))["=="](false)
	window:Minimize()
	window:Remove()
	T(dock:HasItem(window))["=="](false)
end)

T.Test2D("dropdown shows the text of the selected value and reports selections", function()
	local selected
	local dropdown = Dropdown{
		Options = {{Text = "One", Value = 1}, {Text = "Two", Value = 2}},
		Value = 2,
		OnSelect = function(value, text, index)
			selected = {value, text, index}
		end,
	}
	T(dropdown.label.text:GetText())["=="]("Two")
	dropdown:SetValue(1)
	T(dropdown.label.text:GetText())["=="]("One")
	dropdown:select_option(2)
	T(selected[1])["=="](2)
	T(selected[2])["=="]("Two")
	T(selected[3])["=="](2)
	T(dropdown:GetValue())["=="](2)
	dropdown:Remove()
end)

T.Test2D("splitter sizes its first child, clamps the split and rejects a third child", function()
	local splitter = Splitter{InitialSize = 100, MinSplitSize = 40}
	local first = Panel.New{transform = true, layout = {}}
	local second = Panel.New{transform = true, layout = {}}
	splitter{first, second}
	T(first.layout:GetMinSize().x)["=="](100)
	splitter:SetSplitSize(10)
	T(splitter:GetSplitSize())["=="](40)
	T(#splitter:GetChildren())["=="](3)
	local ok = pcall(function()
		splitter:AddChild(Panel.New{transform = true, layout = {}})
	end)
	T(ok)["=="](false)
	splitter:Remove()
end)

T.Test2D("property number clamps, parses and steps its value", function()
	local changes = {}
	local field = PropertyNumber{
		Value = 5,
		Min = 0,
		Max = 10,
		Step = 2,
		Precision = 1,
		OnChange = function(value)
			changes[#changes + 1] = value
		end,
	}
	T(field:GetValue())["=="](5)
	field:SetValue(50, true)
	T(field:GetValue())["=="](10)
	T(changes[1])["=="](10)
	field:Increment(-1)
	T(field:GetValue())["=="](8)
	T(field:EncodeValue())["=="]("8")
	local decoded, ok = field:DecodeValue("99")
	T(ok)["=="](true)
	T(decoded)["=="](10)
	local _, bad = field:DecodeValue("nope")
	T(bad)["=="](false)
	field:Remove()
end)

T.Test2D("property vector updates its fields, encodes them and notifies on change", function()
	local changed
	local vector = PropertyVector{
		Value = Vec3(1, 2, 3),
		Components = {"x", "y", "z"},
		Factory = function(v)
			return Vec3(v[1], v[2], v[3])
		end,
		Precision = 1,
		OnChange = function(value)
			changed = value
		end,
	}
	T(vector:EncodeValue())["=="]("1 2 3")
	vector:SetValue(Vec3(4, 5, 6), true)
	T(changed.x)["=="](4)
	T(vector._fields[3]:GetValue())["=="](6)
	local decoded, ok = vector:DecodeValue("7 8 9")
	T(ok)["=="](true)
	T(decoded.z)["=="](9)
	vector:Remove()
end)

T.Test2D("property editor builds rows from items and routes edits through node and editor callbacks", function()
	local node_changes = {}
	local editor_changes = {}
	local editor = PropertyEditor{
		Items = {
			{
				Key = "group",
				Text = "Group",
				Children = {
					{
						Key = "group/number",
						Text = "Number",
						Type = "number",
						Value = 1,
						OnChange = function(node, value)
							node_changes[#node_changes + 1] = value
						end,
					},
					{Key = "group/flag", Text = "Flag", Type = "boolean", Value = false},
					{Key = "group/name", Text = "Name", Type = "string", Value = "x"},
				},
			},
		},
		OnChange = function(node, value, key)
			editor_changes[#editor_changes + 1] = key
		end,
	}
	T(editor:GetPanelForKey("group/number"):IsValid())["=="](true)
	local control = editor._row_infos["group/number"].editor_panel
	control:SetValue(7, true)
	T(node_changes[1])["=="](7)
	T(editor_changes[1])["=="]("group/number")
	T(editor:GetSelectedKey())["=="]("group/number")
	editor:UpdateValueForKey("group/flag", true)
	T(editor._row_infos["group/flag"].editor_panel:GetValue())["=="](true)
	editor:SetSelectedKey("group/name")
	T(editor:GetSelectedKey())["=="]("group/name")
	editor:Remove()
end)

T.Test2D("property editor color picker window writes picked colors back to the color control", function()
	local changes = {}
	local editor = PropertyEditor{
		Items = {
			{
				Key = "group",
				Text = "Group",
				Children = {
					{
						Key = "group/tint",
						Text = "Tint",
						Type = "color",
						Value = Color(1, 0, 0, 1),
						OnChange = function(node, value)
							changes[#changes + 1] = value
						end,
					},
				},
			},
		},
	}
	local control = editor._row_infos["group/tint"].editor_panel
	editor:open_color_picker_window(control)
	local window = Panel.World:GetKeyed("PropertyColorPickerWindow/" .. control.PropertyKey)
	local picker

	for _, child in ipairs(window:GetChildrenList()) do
		if child.apply_hsva then picker = child end
	end

	picker:apply_hsva(0.5, 1, 1, 1, true)
	T(#changes)["=="](1)
	T(changes[1].g > 0)["=="](true)
	window:Remove()
	editor:Remove()
end)

T.Test2D("menu bar creates a button per item and tracks the open menu", function()
	local bar = MenuBar{
		Items = {
			{
				Text = "File",
				Items = function()
					return {}
				end,
			},
			{Text = "Edit", Disabled = true},
		},
	}
	T(#bar._buttons)["=="](2)
	T(bar._buttons[2]:GetState("disabled"))["=="](true)
	bar:Remove()
end)

T.Test2D("property_number drag rate is bounded by the screen height and accelerates with speed", function()
	local PropertyNumber = import("goluwa/render2d/ui/widgets/properties/number.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	local bounded = PropertyNumber{Value = 0, Min = 0, Max = 0.1, Precision = 2}
	local rate, accelerates = bounded:get_drag_rate()
	T(accelerates)["=="](false)
	T(
		math.abs(rate * select(2, import("goluwa/render2d/render2d.lua").GetSize()) - 0.1) < 0.0001
	)["=="](true)
	bounded:Remove()
	local huge = PropertyNumber{Value = 0, Min = 0, Max = 1000000, Precision = 0}
	rate, accelerates = huge:get_drag_rate()
	T(accelerates)["=="](true)
	T(rate)["=="](0.25)
	huge:Remove()
	local free = PropertyNumber{Value = 0, Precision = 0}
	free._drag_value = 0
	local slow = PropertyNumber.OnDragValue(Vec2(0, -1), free)
	free._drag_value = 0
	local fast = PropertyNumber.OnDragValue(Vec2(0, -400), free)
	T(fast)[">"](slow * 400)
	free:Remove()
end)

T.Test2D("vector component fields open the vector's context menu so reset restores the default", function()
	local Vector = import("goluwa/render2d/ui/widgets/properties/vector.lua")
	local vec = Vector{
		Value = {x = 1, y = 2, z = 3},
		Components = {"x", "y", "z"},
		Factory = function(t)
			return t
		end,
		DefaultEncoded = "1 2 3",
		Precision = 2,
	}
	vec._fields[2]:SetValue(50, true)
	T(vec:EncodeValue())["=="]("1 50 3")
	T(vec._fields[2].MenuControl == vec)["=="](true)
	local value, ok = vec._fields[2].MenuControl:DecodeValue(vec._fields[2].MenuControl:GetDefaultEncoded())
	T(ok)["=="](true)
	vec:SetValue(value, true)
	T(vec:EncodeValue())["=="]("1 2 3")
	vec:Remove()
end)

T.Test2D("stretch alignment caps children at MaxSize but never squeezes growing viewports", function()
	local Panel = import("goluwa/render2d/ui/panel.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
	local Column = import("goluwa/render2d/ui/elements/column.lua")
	local column = Column{
		layout = {AlignmentX = "stretch", FitHeight = true},
		transform = {Size = Vec2(400, 10)},
	}
	local capped = Panel.New{transform = {Size = Vec2(10, 20)}, layout = {MaxSize = Vec2(200, 0)}}
	local edit = TextEdit{Hint = "hint", Size = Vec2(400, 38)}
	column:AddChild(capped)
	column:AddChild(edit)

	for _ = 1, 3 do
		column.layout:SetDirty(true)
		column.layout:UpdateLayout()
	end

	T(capped.transform:GetWidth())["=="](200)
	T(edit.transform:GetWidth())["=="](400)
	T(edit:GetTextPanel():GetParent().transform:GetWidth())[">"](100)
	column:Remove()
end)

T.Test2D("read only text edit can select but never changes its text", function()
	local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
	local edit = TextEdit{Text = "read only text", Editable = false}
	local editor = edit:GetTextPanel().text.editor
	T(editor ~= nil)["=="](true)
	editor:SetSelectionStart(1)
	editor:SetCursor(5)
	local start, stop = editor:GetSelection()
	T(start)["=="](1)
	T(stop)["=="](5)
	editor:OnKeyInput("backspace")
	editor:OnCharInput("x")
	editor:SetControlDown(true)
	editor:OnKeyInput("x")
	editor:OnKeyInput("v")
	editor:SetControlDown(false)
	T(edit:GetTextPanel().text:GetText())["=="]("read only text")
	edit:Remove()
end)

T.Test2D("growing children stop at MaxSize and the leftover goes to the others", function()
	local Panel = import("goluwa/render2d/ui/panel.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	local Row = import("goluwa/render2d/ui/elements/row.lua")
	local row = Row{
		layout = {FitWidth = false, FitHeight = false},
		transform = {Size = Vec2(600, 40)},
	}
	local capped = Panel.New{
		transform = {Size = Vec2(10, 20)},
		layout = {GrowWidth = 1, MaxSize = Vec2(100, 0)},
	}
	local free = Panel.New{transform = {Size = Vec2(10, 20)}, layout = {GrowWidth = 1}}
	row:AddChild(capped)
	row:AddChild(free)

	for _ = 1, 3 do
		row.layout:SetDirty(true)
		row.layout:UpdateLayout()
	end

	T(capped.transform:GetWidth())["=="](100)
	T(free.transform:GetWidth())[">"](400)
	row:Remove()
end)

T.Test2D("clicking empty space in a text edit moves the caret to the nearest position", function()
	local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
	local system = import("goluwa/system.lua")
	local event = import("goluwa/event.lua")
	local edit = TextEdit{Text = "foo", Size = Vec2(300, 38)}
	edit.transform:SetPosition(Vec2(10, 10))
	edit:SetParent(Panel.World)

	for _ = 1, 3 do
		event.CallUpdate()
	end

	local window = system.GetWindow()
	local old_pos = window:GetMousePosition():Copy()
	window:SetMousePosition(Vec2(280, 28))
	event.Call("MouseInput", "button_1", true)
	event.Call("MouseInput", "button_1", false)
	local cursor = edit:GetTextPanel().text.editor.Cursor
	window:SetMousePosition(old_pos)
	edit:Remove()
	T(cursor)["=="](4)
end)

T.Test2D("read only text edit focuses and starts a selection from empty space", function()
	local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
	local system = import("goluwa/system.lua")
	local event = import("goluwa/event.lua")
	local objects = import("goluwa/objects/objects.lua")
	local edit = TextEdit{Text = "foo", Editable = false, Size = Vec2(300, 38)}
	edit.transform:SetPosition(Vec2(10, 10))
	edit:SetParent(Panel.World)

	for _ = 1, 3 do
		event.CallUpdate()
	end

	local window = system.GetWindow()
	local old_pos = window:GetMousePosition():Copy()
	window:SetMousePosition(Vec2(280, 28))
	event.Call("MouseInput", "button_1", true)
	local text_panel = edit:GetTextPanel()
	local focused = objects.GetFocusedObject() == text_panel
	local cursor = text_panel.text.editor.Cursor
	event.Call("MouseInput", "button_1", false)
	window:SetMousePosition(old_pos)
	edit:Remove()
	T(focused)["=="](true)
	T(cursor)["=="](4)
end)

T.Test2D("checkbox and radio button labels are part of the control", function()
	local RadioButton = import("goluwa/render2d/ui/elements/radio_button.lua")
	local event = import("goluwa/event.lua")
	local system = import("goluwa/system.lua")
	local changes = {}
	local checkbox = Checkbox{
		Text = "Enabled",
		Value = false,
		OnChange = function(value)
			changes[#changes + 1] = value
		end,
	}
	local selected
	local radio = RadioButton{
		Text = "Low",
		IsSelected = function()
			return selected
		end,
		OnSelect = function()
			selected = true
		end,
	}
	local old_world = Panel.World
	local world = Panel.New{ComponentSet = {"transform", "visual"}}
	world:SetName("TestWorld")
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	local row = Row{layout = {ChildGap = "L"}}{checkbox, radio}
	row:SetParent(world)

	for _ = 1, 3 do
		row.layout:SetDirty(true)
		row.layout:UpdateLayout()
		world.visual:DrawRecursive()
		event.CallUpdate()
	end

	local window = system.GetWindow()
	local old_pos = window:GetMousePosition():Copy()

	local function click_label(control)
		local x, y = control._label.transform:GetWorldMatrix():GetTranslation()
		window:SetMousePosition(Vec2(x + 2, y + 2))
		event.CallUpdate()
		event.Call("MouseInput", "button_1", true)
		event.Call("MouseInput", "button_1", false)
	end

	click_label(checkbox)
	T(changes[1])["=="](true)
	T(checkbox:GetState("value"))["=="](true)
	T(checkbox._box:GetState("hovered"))["=="](true)
	click_label(radio)
	T(selected)["=="](true)
	checkbox:SetText("Renamed")
	T(checkbox._label.text:GetText())["=="]("Renamed")
	local bare = Checkbox{}
	T(bare._label == nil)["=="](true)
	window:SetMousePosition(old_pos)
	bare:Remove()
	row:Remove()
	world:Remove()
	Panel.World = old_world
end)

T.Test2D("property editor list nodes build rows and group items, route actions and reorder by dragging", function()
	local log = {}
	local names = {"a", "b", "c"}

	local function log_action(name)
		return function(...)
			log[#log + 1] = name .. ":" .. table.concat({...}, ",")
		end
	end

	local items = {}

	for i, name in ipairs(names) do
		items[i] = {Key = "names/" .. i, Type = "string", Value = name}
	end

	local editor = PropertyEditor{
		Items = {
			{
				Key = "cat",
				Text = "Cat",
				Children = {
					{
						Key = "names",
						Text = "Names",
						Type = "list",
						Items = items,
						Actions = {
							Add = log_action("add"),
							Insert = log_action("insert"),
							Duplicate = log_action("duplicate"),
							Remove = log_action("remove"),
							Move = log_action("move"),
							Clear = log_action("clear"),
						},
					},
					{
						Key = "groups",
						Text = "Groups",
						Type = "list",
						Items = {
							{
								Key = "groups/1",
								Text = "one",
								Children = {{Key = "groups/1/x", Text = "X", Type = "number", Value = 1}},
							},
						},
						Actions = {
							Add = log_action("add"),
							Insert = log_action("insert"),
							Duplicate = log_action("duplicate"),
							Remove = log_action("remove"),
							Move = log_action("move"),
							Clear = log_action("clear"),
						},
					},
				},
			},
		},
	}
	local lists = {}

	for _, child in ipairs(editor:GetChildrenList()) do
		if child.Name == "property_list" then lists[#lists + 1] = child end
	end

	T(#lists)["=="](2)
	local rows = lists[1]._rows
	T(#rows)["=="](3)
	T(#lists[1]._drag_controls)["=="](3)
	lists[1]._drag_controls[2].control.Node.ContextActions[2].OnClick()
	T(log[1])["=="]("remove:2")
	table.remove(log, 1)
	T(lists[1]._drag_controls[1].control:GetEditClickCount())["=="](2)
	lists[1]:begin_drag(1, rows[1].transform:LocalToGlobal(Vec2(4, 0)))
	T(lists[1]._drag.ghost:IsValid())["=="](true)
	local last = rows[3]
	lists[1]:OnGlobalMouseMove(last.transform:LocalToGlobal(Vec2(20, last.transform:GetHeight() * 0.9)))
	T(lists[1]._drag.drop)["=="](4)
	lists[1]:OnGlobalMouseInput("button_1", false)
	T(log[1])["=="]("move:1,3")
	lists[1]:begin_drag(3, rows[3].transform:LocalToGlobal(Vec2(4, 0)))
	lists[1]:OnGlobalMouseMove(rows[1].transform:LocalToGlobal(Vec2(20, 0)))
	lists[1]:OnGlobalMouseInput("button_1", false)
	T(log[2])["=="]("move:3,1")
	T(#log)["=="](2)
	editor:Remove()
end)

T.Test2D("property editor chip lists drag with a ghost, edit on double click and end with an add button", function()
	local log = {}

	local function log_action(name)
		return function(...)
			log[#log + 1] = name .. ":" .. table.concat({...}, ",")
		end
	end

	local items = {}

	for i, name in ipairs({"fire", "flames", "embers"}) do
		items[i] = {Key = "words/" .. i, Type = "string", Value = name}
	end

	local editor = PropertyEditor{
		Items = {
			{
				Key = "cat",
				Text = "Cat",
				Children = {
					{
						Key = "words",
						Text = "Words",
						Type = "list",
						Display = "chips",
						Items = items,
						Actions = {
							Add = log_action("add"),
							Insert = log_action("insert"),
							Duplicate = log_action("duplicate"),
							Remove = log_action("remove"),
							Move = log_action("move"),
							Clear = log_action("clear"),
						},
					},
				},
			},
		},
	}
	local list

	for _, child in ipairs(editor:GetChildrenList()) do
		if child.Name == "property_list" then list = child end
	end

	local chips = list._chips
	T(#chips)["=="](3)

	for i, chip in ipairs(chips) do
		chip.transform:SetSize(Vec2(60, 24))
		chip.transform:SetPosition(Vec2(i * 70, 0))
	end

	T(chips[1].Control:GetEditClickCount())["=="](2)
	T(chips[2].Control.Node.ContextActions[1].Text)["=="]("Duplicate")
	chips[2].Control.Node.ContextActions[1].OnClick()
	T(log[1])["=="]("duplicate:2")
	chips[2].Control.Node.ContextActions[2].OnClick()
	T(log[2])["=="]("remove:2")
	log[1] = nil
	log[2] = nil
	local first = chips[1].transform:LocalToGlobal(Vec2(4, 4))
	list:begin_drag(1, first)
	T(list._drag.ghost:IsValid())["=="](true)
	list:OnGlobalMouseMove(chips[3].transform:LocalToGlobal(chips[3].transform:GetSize() - Vec2(1, 1)))
	T(list._drag.drop)["=="](4)
	list:OnGlobalMouseInput("button_1", false)
	T(log[1])["=="]("move:1,3")
	T(list._drag)["=="](nil)
	editor:Remove()
end)

T.Test2D("a ghost draws the source panel subtree at an offset with an alpha override", function()
	local render2d = import("goluwa/render2d/render2d.lua")
	local Ghost = import("goluwa/render2d/ui/elements/ghost.lua")
	local draws = {}
	local source = Panel.New{
		Parent = Panel.World,
		transform = {Size = Vec2(40, 20), Position = Vec2(100, 100)},
		visual = true,
		OnDraw = function()
			draws[#draws + 1] = render2d.GetAlphaMultiplier()
		end,
	}
	source.visual:DrawGhost(30, 40, 0.5)
	T(#draws)["=="](1)
	T(draws[1])["=="](0.5)
	T(render2d.GetAlphaMultiplier())["=="](1)
	local ghost = Ghost{Parent = Panel.World, Source = source, GrabPosition = Vec2(110, 110)}
	T(ghost.Grab.x)["=="](10)
	T(ghost.Grab.y)["=="](10)
	T(source.visual:GetGhosted())["=="](true)
	T(Panel.World.ChildrenMap[ghost] ~= nil)["=="](true)
	ghost:Remove()
	T(Panel.World.ChildrenMap[ghost])["=="](nil)
	T(source.visual:GetGhosted())["=="](false)
	source:Remove()
end)

T.Test2D("sound property has a play button before the browse button and plays through the node", function()
	local played
	local editor = PropertyEditor{
		Items = {
			{
				Key = "cat",
				Text = "Cat",
				Children = {
					{
						Key = "cue",
						Text = "Cue",
						Type = "sound",
						Value = "ambient/fire/ignite.wav",
						PlayAction = function(path)
							played = path
						end,
					},
				},
			},
		},
	}
	local control

	for _, child in ipairs(editor:GetChildrenList()) do
		if child.Name == "property_sound" then control = child end
	end

	T(control ~= nil)["=="](true)
	T(control.AssetCategory)["=="]("sounds")
	T(#control.RightElements)["=="](2)
	T(control.RightElements[1].Icon)["=="]("play")
	T(control.RightElements[2].Icon)["=="]("folder_open")
	control.RightElements[1].OnClick(control.RightElements[1])
	T(played)["=="]("ambient/fire/ignite.wav")
	editor:Remove()
end)

T.Test2D("a curve row edits its keys in a curve editor window and writes the curve back through its node", function()
	local written
	local editor = PropertyEditor{
		Items = {
			{
				Key = "group",
				Text = "Group",
				Children = {
					{
						Key = "group/size",
						Text = "Size",
						Type = "curve",
						Kind = "scalar",
						Min = 0,
						Max = 2,
						Value = {Keys = {{0, 0.5}, {1, 0.1}}},
						OnChange = function(node, value)
							written = value
						end,
					},
				},
			},
		},
	}
	local control = editor._row_infos["group/size"].editor_panel
	T(control.Name)["=="]("property_curve")
	editor:open_curve_editor_window(control)
	local window = Panel.World:GetKeyed("PropertyCurveEditorWindow/" .. control.PropertyKey)
	local curve_editor

	for _, child in ipairs(window:GetChildrenList()) do
		if child.AddKey then curve_editor = child end
	end

	T(curve_editor ~= nil)["=="](true)
	curve_editor.canvas.transform:SetSize(Vec2(440, 240))
	curve_editor:AddKey(0.5, 1.5)
	T(#written.Keys)["=="](3)
	T(written.Keys[2][1])["=="](0.5)
	T(written.Keys[2][2])["=="](1.5)
	curve_editor:MoveKey(2, 0.75, 5)
	T(written.Keys[2][1])["=="](0.75)
	T(written.Keys[2][2])["=="](2)
	curve_editor:MoveKey(2, 5, 1)
	T(written.Keys[2][1])["=="](1)
	curve_editor:MoveKey(2, 0.5, 1)
	curve_editor:Select(nil)
	T(#curve_editor:BuildItems()[1].Children)["=="](2)
	curve_editor:Select(2)
	local key_group = curve_editor:BuildItems()[1].Children[3]
	T(key_group.Text)["=="]("key 2")
	T(key_group.Children[1].Value)["=="](0.5)
	key_group.Children[2].OnChange(nil, 0.25)
	T(written.Keys[2][2])["=="](0.25)
	key_group.Children[3].OnChange(nil, "smooth")
	T(written.Keys[2][3])["=="]("smooth")
	curve_editor:RemoveKey(2)
	T(#written.Keys)["=="](2)
	curve_editor:ApplyPreset{{0, 0}, {0.5, 1}, {1, 0}}
	T(#written.Keys)["=="](3)
	T(written.Keys[2][2])["=="](0.5)
	curve_editor:BuildItems()[1].Children[1].OnChange(nil, true)
	T(#written.MaxKeys)["=="](3)
	T(#curve_editor:BuildItems()[1].Children)["=="](3)
	curve_editor:BuildItems()[1].Children[2].OnChange(nil, "MaxKeys")
	curve_editor:AddKey(0.25, 2)
	T(#written.MaxKeys)["=="](4)
	T(#written.Keys)["=="](3)
	local canvas = curve_editor.canvas
	local x, y = canvas:to_screen(0.25, 2)
	canvas:OnMouseInput("button_1", true, Vec2(x, y))
	T(curve_editor._selected)["=="](2)
	T(canvas._drag ~= nil)["=="](true)
	local drag_x, drag_y = canvas:to_screen(0.6, 1)
	canvas:OnGlobalMouseMove(canvas.transform:LocalToGlobal(Vec2(drag_x, drag_y)))
	T(math.abs(written.MaxKeys[2][1] - 0.5) < 1e-6)["=="](true)
	canvas:OnMouseInput("button_1", false, Vec2(drag_x, drag_y))
	T(canvas._drag)["=="](nil)
	curve_editor:BuildItems()[1].Children[1].OnChange(nil, false)
	T(written.MaxKeys)["=="](nil)
	window:Remove()
	editor:Remove()
end)

T.Test2D("a color curve row keeps rgba keys and a color range row writes both swatch colors back", function()
	local curve_written, range_written
	local editor = PropertyEditor{
		Items = {
			{
				Key = "group",
				Text = "Group",
				Children = {
					{
						Key = "group/fade",
						Text = "Color",
						Type = "curve",
						Kind = "color",
						Value = {Keys = {{0, {1, 1, 1, 1}}, {1, {1, 0, 0, 0}}}},
						OnChange = function(node, value)
							curve_written = value
						end,
					},
					{
						Key = "group/pair",
						Text = "Pair",
						Type = "color_range",
						Value = {{1, 0, 0, 1}, {0, 0, 1, 1}},
						OnChange = function(node, value)
							range_written = value
						end,
					},
				},
			},
		},
	}
	local control = editor._row_infos["group/fade"].editor_panel
	editor:open_curve_editor_window(control)
	local window = Panel.World:GetKeyed("PropertyCurveEditorWindow/" .. control.PropertyKey)
	local curve_editor

	for _, child in ipairs(window:GetChildrenList()) do
		if child.AddKey then curve_editor = child end
	end

	curve_editor.canvas.transform:SetSize(Vec2(440, 240))
	curve_editor:AddKey(0.5, 0)
	T(#curve_written.Keys)["=="](3)
	T(math.abs(curve_written.Keys[2][2][2] - 0.5) < 1e-6)["=="](true)
	T(math.abs(curve_written.Keys[2][2][4] - 0.5) < 1e-6)["=="](true)
	curve_editor:Select(2)
	local color_row = curve_editor:BuildItems()[1].Children[3].Children[2]
	T(color_row.Type)["=="]("color")
	color_row.OnChange(nil, Color(0, 1, 0, 0.75))
	T(curve_written.Keys[2][2][2])["=="](1)
	T(curve_written.Keys[2][2][4])["=="](0.75)
	curve_editor:ApplyPreset{{0, 1}, {1, 0}}
	T(curve_written.Keys[1][2][1])["=="](1)
	T(curve_written.Keys[2][2][4])["=="](0)
	window:Remove()
	local range = editor._row_infos["group/pair"].editor_panel
	T(range.Name)["=="]("property_color_range")
	T(#range._swatches)["=="](2)
	editor:open_color_picker_window{
		Node = range.Node,
		PropertyKey = "pair/2",
		PropertyPath = range.PropertyPath,
		GetValue = function()
			return Color(0, 0, 1, 1)
		end,
		SetValue = function() end,
	}
	Panel.World:GetKeyed("PropertyColorPickerWindow/pair/2"):Remove()
	range._swatches[1].OnClick(range._swatches[1])
	local picker_window = Panel.World:GetKeyed("PropertyColorPickerWindow/" .. range.PropertyKey .. "/1")
	local picker

	for _, child in ipairs(picker_window:GetChildrenList()) do
		if child.apply_hsva then picker = child end
	end

	picker:apply_hsva(0.5, 1, 1, 1, true)
	T(range_written[1][2] > 0)["=="](true)
	T(range_written[2][3])["=="](1)
	picker_window:Remove()
	editor:Remove()
end)

T.Test2D("a searchable dropdown with thousands of options only builds the visible window", function()
	local options = {}

	for i = 1, 5000 do
		options[i] = "option " .. i
	end

	local dropdown = Dropdown{Options = options, Value = "option 1", Searchable = true}
	dropdown:open_menu()

	local function count_options(column)
		local count = 0

		for _, child in ipairs(column:GetChildrenList()) do
			if child.OptionIndex then count = count + 1 end
		end

		return count
	end

	local column = dropdown._results_column
	T(count_options(column))["<"](100)
	T(count_options(column))[">"](0)
	local viewport = dropdown._results_panel:GetViewport()
	viewport.transform:SetScroll(Vec2(0, dropdown._item_height * 3000))
	dropdown:show_window()
	T(count_options(column))["<"](100)
	T(column:GetChildrenList()[1].OptionIndex)[">"](2500)
	dropdown:rebuild_results("option 99")
	T(#dropdown._matches)["=="](11)
	dropdown:rebuild_results("nothing like it")
	T(count_options(column))["=="](0)
	Panel.CloseContextMenu()
	dropdown:Remove()
	local plain = Dropdown{Options = options, Value = "option 1"}
	plain:open_menu()
	T(#plain._matches)["=="](5000)
	Panel.CloseContextMenu()
	plain:Remove()
end)

T.Test2D("the ui theme leaves a numeric emitter size alone", function()
	local Entity = import("goluwa/entities/entity.lua")
	local theme = import("goluwa/render2d/ui/theme.lua")
	local entity = Entity.New{
		Name = "theme_size_emitter",
		transform = {},
		particle_emitter_gpu = {Size = 0.05},
	}
	T(entity.particle_emitter_gpu:GetSize())["=="](0.05)
	T(theme.active:OnEntitySetProperty(entity.particle_emitter_gpu, "Size", 0.05))["=="](0.05)
	entity:Remove()
end)
