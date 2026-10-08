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
		event.Call("Update")
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
		event.Call("Update")
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
		event.Call("Update")
	end

	local window = system.GetWindow()
	local old_pos = window:GetMousePosition():Copy()

	local function click_label(control)
		local x, y = control._label.transform:GetWorldMatrix():GetTranslation()
		window:SetMousePosition(Vec2(x + 2, y + 2))
		event.Call("Update")
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
