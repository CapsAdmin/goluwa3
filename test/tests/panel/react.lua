local T = import("test/environment.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Panel = import("goluwa/render2d/ui/panel.lua")

local function texts(entity)
	local out = {}

	for _, child in ipairs(entity:GetChildren()) do
		out[#out + 1] = child.text:GetText()
	end

	return out
end

T.Test2D("react counter updates the same entities on state change", function()
	local set_count
	local renders = 0
	local Counter = react.Component(|props| -> do
		local count, set = react.UseState(props.Start)
		set_count = set
		renders += 1

		return Column{}{
			Text{Text = "count " .. count},
			Button{Text = "+", OnClick = || -> set(count + 1)},
		}
	end)
	local root = react.Mount(Counter{Start = 2}, Panel.World)
	local column = root:GetEntity()
	local label, button = column:GetChildren()[1], column:GetChildren()[2]
	T(label.text:GetText())["=="]("count 2")
	button:CallLocalEvent("OnClick")
	T(label.text:GetText())["=="]("count 2")
	react.Flush()
	T(label.text:GetText())["=="]("count 3")
	T(column:GetChildren()[1])["=="](label)
	T(column:GetChildren()[2])["=="](button)
	button:CallLocalEvent("OnClick")
	button:CallLocalEvent("OnClick")
	react.Flush()
	T(renders)["=="](3)
	root:Unmount()
	T(column:IsValid())["=="](false)
end)

T.Test2D("react conditionals and keyed lists keep order and identity", function()
	local function view(show, ids)
		return Column{}{
			show && Text{Key = "head", Text = "head"},
			list.map(ids, |id| -> Text{Key = id, Text = id}),
			Text{Key = "tail", Text = "tail"},
		}
	end

	local root = react.Mount(view(false, {"a", "b", "c"}), Panel.World)
	local column = root:GetEntity()
	T(table.concat(texts(column), ","))["=="]("a,b,c,tail")
	local by_text = {}

	for _, child in ipairs(column:GetChildren()) do
		by_text[child.text:GetText()] = child
	end

	root:Render(view(true, {"c", "a", "d"}))
	T(table.concat(texts(column), ","))["=="]("head,c,a,d,tail")
	T(column:GetChildren()[2])["=="](by_text.c)
	T(column:GetChildren()[3])["=="](by_text.a)
	T(by_text.b:IsValid())["=="](false)
	root:Render(view(false, {"d"}))
	T(table.concat(texts(column), ","))["=="]("d,tail")
	root:Unmount()
end)

T.Test2D("react removed props reset to defaults and component props are diffed", function()
	local function view(props)
		return Button(props)
	end

	local root = react.Mount(view({Text = "x", Disabled = true, layout = {GrowWidth = 1}}), Panel.World)
	local button = root:GetEntity()
	T(button:GetDisabled())["=="](true)
	T(button.layout:GetGrowWidth())["=="](1)
	local clicks = 0
	root:Render(view({Text = "y", OnClick = || -> do clicks += 1 end}))
	T(button:GetText())["=="]("y")
	T(button:GetDisabled())["=="](false)
	T(button.layout:GetGrowWidth())["=="](0)
	button:CallLocalEvent("OnClick")
	T(clicks)["=="](1)
	root:Render(view({Text = "y"}))
	button:CallLocalEvent("OnClick")
	T(clicks)["=="](1)
	root:Unmount()
end)

T.Test2D("react effects run after render, rerun on deps and clean up on unmount", function()
	local log = {}
	local set_value
	local Child = react.Component(|props| -> do
		react.UseEffect(|| -> do
			log[#log + 1] = "mount"

			return || -> do log[#log + 1] = "unmount" end
		end, {})

		react.UseEffect(|| -> do
			log[#log + 1] = "dep " .. props.Value

			return || -> do log[#log + 1] = "undep " .. props.Value end
		end, {props.Value})

		return Text{Text = tostring(props.Value)}
	end)
	local Parent = react.Component(|props| -> do
		local value, set = react.UseState(1)
		set_value = set

		return Column{}{value < 3 && Child{Value = value}}
	end)
	local root = react.Mount(Parent{}, Panel.World)
	T(table.concat(log, ","))["=="]("mount,dep 1")
	set_value(2)
	react.Flush()
	T(table.concat(log, ","))["=="]("mount,dep 1,undep 1,dep 2")
	set_value(3)
	react.Flush()
	T(table.concat(log, ","))["=="]("mount,dep 1,undep 1,dep 2,unmount,undep 2")
	root:Unmount()
end)

T.Test2D("react component swapping its root and refs", function()
	local seen
	local set_wide
	local View = react.Component(|props| -> do
		local wide, set = react.UseState(false)
		set_wide = set

		return wide && Row{Ref = |e| -> do if e then seen = "row" end end}{Text{Text = "wide"}} || Column{Ref = |e| -> do if e then seen = "column" end end}{Text{Text = "narrow"}}
	end)
	local root = react.Mount(Column{}{View{}, Text{Text = "after"}}, Panel.World)
	local column = root:GetEntity()
	T(seen)["=="]("column")
	T(#column:GetChildren())["=="](2)
	set_wide(true)
	react.Flush()
	T(seen)["=="]("row")
	T(#column:GetChildren())["=="](2)
	T(column:GetChildren()[2].text:GetText())["=="]("after")
	root:Unmount()
end)

local ErrorBoundary = react.ErrorBoundary

local function fallback(err, reset)
	return Column{}{
		Text{Key = "message", Text = "failed: " .. tostring(err):gsub("^.-:%d+: ", "")},
		Button{Key = "retry", Text = "retry", OnClick = reset},
	}
end

T.Test2D("react error boundary shows the fallback for a render error and resets", function()
	local broken = true
	local Bad = react.Component(|props| -> do
		if broken then error("render exploded", 0) end

		return Text{Text = "fine"}
	end)
	local root = react.Mount(
		Column{}{Text{Text = "outside"}, ErrorBoundary{Fallback = fallback}{Text{Text = "before"}, Bad{}}},
		Panel.World
	)
	local column = root:GetEntity()
	T(#column:GetChildren())["=="](2)
	T(column:GetChildren()[1].text:GetText())["=="]("outside")
	local shown = column:GetChildren()[2]
	T(shown:GetChildren()[1].text:GetText())["=="]("failed: render exploded")
	broken = false
	shown:GetChildren()[2]:CallLocalEvent("OnClick")
	react.Flush()
	T(table.concat(texts(column), ","))["=="]("outside,before,fine")
	root:Unmount()
end)

T.Test2D("react error boundary removes entities that were built before the error", function()
	local root = react.Mount(
		Column{}{
			ErrorBoundary{Fallback = fallback}{
				Column{}{Text{Text = "built"}, Button{Text = "bad", Disabled = "not a boolean"}},
			},
		},
		Panel.World
	)
	local column = root:GetEntity()
	T(#column:GetChildren())["=="](1)
	T(column:GetChildren()[1]:GetChildren()[1].text:GetText():starts_with("failed:"))["=="](true)
	T(#column:GetChildren()[1]:GetChildren())["=="](2)
	root:Unmount()
end)

T.Test2D("react error boundary catches handler errors and a later update that throws", function()
	local set_value
	local Child = react.Component(|props| -> do
		local value, set = react.UseState(0)
		set_value = set

		if value == 2 then error("update exploded", 0) end

		return Button{Text = "go " .. value, OnClick = || -> error("click exploded", 0)}
	end)
	local root = react.Mount(Column{}{ErrorBoundary{Fallback = fallback}{Child{}}}, Panel.World)
	local column = root:GetEntity()
	local button = column:GetChildren()[1]
	T(button:GetText())["=="]("go 0")
	button:CallLocalEvent("OnClick")
	react.Flush()
	T(#column:GetChildren())["=="](1)
	T(column:GetChildren()[1]:GetChildren()[1].text:GetText())["=="]("failed: click exploded")
	root:Unmount()
	root = react.Mount(Column{}{ErrorBoundary{Fallback = fallback}{Child{}}}, Panel.World)
	column = root:GetEntity()
	set_value(2)
	react.Flush()
	T(column:GetChildren()[1]:GetChildren()[1].text:GetText())["=="]("failed: update exploded")
	root:Unmount()
end)

T.Test2D("react error boundary catches effect errors and nests", function()
	local Effect = react.Component(|props| -> do
		react.UseEffect(|| -> error("effect exploded", 0), {})

		return Text{Text = "effect"}
	end)
	local Throws = react.Component(|props| -> error("inner fallback exploded", 0))
	local root = react.Mount(
		Column{}{
			ErrorBoundary{Fallback = fallback}{Effect{}},
			ErrorBoundary{Fallback = |err| -> Text{Text = "outer got " .. tostring(err)}}{
				ErrorBoundary{Fallback = |err| -> Throws{}}{Throws{}},
			},
		},
		Panel.World
	)
	local column = root:GetEntity()
	T(column:GetChildren()[1]:GetChildren()[1].text:GetText())["=="]("failed: effect exploded")
	T(column:GetChildren()[2].text:GetText())["=="]("outer got inner fallback exploded")
	root:Unmount()
end)

T.Test2D("react error boundary leaves per frame callbacks unwrapped and guards the rest", function()
	local draw = function() error("draw exploded", 0) end
	local click = function() end
	local root = react.Mount(
		Column{}{ErrorBoundary{Fallback = fallback}{Text{Text = "x", OnDraw = draw, OnMouseMove = draw, OnClick = click}}},
		Panel.World
	)
	local text = root:GetEntity():GetChildren()[1]
	T(text.OnDraw)["=="](draw)
	T(text.OnMouseMove)["=="](draw)
	T(text.OnClick ~= click)["=="](true)
	T(pcall(text.OnDraw))["=="](false)
	root:Unmount()
end)

T.Test2D("react memo skips renders with equal props and renders again for state and context", function()
	local renders = {}
	local Ctx = react.CreateContext("default")
	local set_value
	local Item = react.Memo(react.Component(|props| -> do
		renders[props.Name] = (renders[props.Name] or 0) + 1

		return Text{Text = props.Name .. ":" .. tostring(props.Selected)}
	end))
	local Reader = react.Memo(react.Component(|props| -> do
		renders.reader = (renders.reader or 0) + 1

		return Text{Text = "ctx " .. react.UseContext(Ctx)}
	end))
	local function view(selected, value)
		return Ctx.Provider{Value = value}{
			Column{}{
				Item{Name = "a", Selected = selected == "a"},
				Item{Name = "b", Selected = selected == "b"},
				Item{Name = "c", Selected = selected == "c", OnClick = || -> nil},
				Reader{},
			},
		}
	end

	local root = react.Mount(view("a", 1), Panel.World)
	local column = root:GetEntity()
	T(table.concat(texts(column), ","))["=="]("a:true,b:false,c:false,ctx 1")
	root:Render(view("b", 1))
	T(table.concat(texts(column), ","))["=="]("a:false,b:true,c:false,ctx 1")
	T(renders.a)["=="](2)
	T(renders.b)["=="](2)
	T(renders.c)["=="](2)
	T(renders.reader)["=="](1)
	root:Render(view("b", 2))
	T(table.concat(texts(column), ","))["=="]("a:false,b:true,c:false,ctx 2")
	T(renders.a)["=="](2)
	T(renders.reader)["=="](2)
	root:Unmount()
	T(Ctx.default)["=="]("default")
end)

T.Test2D("react use context reads the default without a provider and nests providers", function()
	local Ctx = react.CreateContext("none")
	local Reader = react.Component(|props| -> Text{Text = react.UseContext(Ctx)})
	local root = react.Mount(
		Column{}{
			Reader{},
			Ctx.Provider{Value = "outer"}{Reader{}, Ctx.Provider{Value = "inner"}{Reader{}}},
		},
		Panel.World
	)
	T(table.concat(texts(root:GetEntity()), ","))["=="]("none,outer,inner")
	root:Unmount()
end)

T.Test2D("react foreign hosts an entity made elsewhere and removes it with the node", function()
	local made = 0
	local function create()
		made = made + 1

		return Panel.New{Name = "foreign" .. made}
	end

	local function view(key)
		return Column{}{Text{Text = "before"}, react.Foreign{Key = key, Create = create}, Text{Text = "after"}}
	end

	local root = react.Mount(view("a"), Panel.World)
	local column = root:GetEntity()
	T(#column:GetChildren())["=="](3)
	local first = column:GetChildren()[2]
	T(first:GetName())["=="]("foreign1")
	root:Render(view("a"))
	T(made)["=="](1)
	T(column:GetChildren()[2])["=="](first)
	root:Render(view("b"))
	T(made)["=="](2)
	T(first:IsValid())["=="](false)
	T(column:GetChildren()[2]:GetName())["=="]("foreign2")
	T(column:GetChildren()[3].text:GetText())["=="]("after")
	root:Unmount()
end)

T.Test2D("react use event subscribes while mounted and sees the latest callback", function()
	local event = import("goluwa/event.lua")
	local seen = {}
	local set_show
	local Listener = react.Component(|props| -> do
		react.UseEvent("react_test_event", |value| -> do seen[#seen + 1] = props.Tag .. value end)

		return Text{Text = props.Tag}
	end)
	local View = react.Component(|props| -> do
		local show, set = react.UseState(true)
		local tag, set_tag = react.UseState("a")
		set_show = |value| -> do
			set(value)
			set_tag("b")
		end

		return Column{}{show && Listener{Tag = tag}}
	end)
	local root = react.Mount(View{}, Panel.World)
	event.Call("react_test_event", 1)
	set_show(false)
	react.Flush()
	event.Call("react_test_event", 2)
	T(table.concat(seen, ","))["=="]("a1")
	root:Unmount()
end)

T.Test2D("react unmounts components whose entities were removed from outside and runs their cleanups", function()
	local event = import("goluwa/event.lua")
	local log = {}
	local Inner = react.Component(|props| -> do
		react.UseEffect(|| -> do return || -> do log[#log + 1] = "inner cleanup" end end, {})

		return Text{Text = "inner"}
	end)
	local Outer = react.Component(|props| -> do
		react.UseEffect(|| -> do return || -> do log[#log + 1] = "outer cleanup" end end, {})
		react.UseEvent("react_removed_test", || -> do log[#log + 1] = "event" end)

		return Column{}{Inner{}}
	end)
	local root = react.Mount(Outer{}, Panel.World)
	event.Call("react_removed_test")
	T(table.concat(log, ","))["=="]("event")
	root:GetEntity():Remove()
	react.Flush()
	T(table.concat(log, ","))["=="]("event,inner cleanup,outer cleanup")
	event.Call("react_removed_test")
	T(#log)["=="](3)
	root:Unmount()
	T(#log)["=="](3)
end)

T.Test2D("react use resource creates once, replaces on deps and disposes on unmount and when a boundary tears it down", function()
	local log = {}
	local set_tag
	local Holder = react.Component(|props| -> do
		local tag, set = react.UseState("a")
		set_tag = set
		local resource = react.UseResource(
			|| -> do log[#log + 1] = "create " .. tag return {tag = tag} end,
			|value| -> do log[#log + 1] = "dispose " .. value.tag end,
			{tag}
		)

		if props.Throw then error("render exploded", 0) end

		return Text{Text = resource.tag}
	end)
	local root = react.Mount(Column{}{Holder{}}, Panel.World)
	root:Render(Column{}{Holder{}})
	T(table.concat(log, ","))["=="]("create a")
	set_tag("b")
	react.Flush()
	T(table.concat(log, ","))["=="]("create a,dispose a,create b")
	root:Unmount()
	T(table.concat(log, ","))["=="]("create a,dispose a,create b,dispose b")
	log = {}
	local boundary_root = react.Mount(
		Column{}{ErrorBoundary{Fallback = fallback}{Holder{Throw = true}}},
		Panel.World
	)
	T(table.concat(log, ","))["=="]("create a,dispose a")
	boundary_root:Unmount()
end)

T.Test2D("react portal mounts under its target, stays out of the parent's order and goes with the portal", function()
	local PanelElement = react.Element(Panel)
	local target = Panel.New{Name = "portal target"}
	local log = {}
	local Inner = react.Component(|props| -> do
		react.UseEffect(|| -> do return || -> do log[#log + 1] = "cleanup" end end, {})

		return PanelElement{Name = "in portal"}
	end)

	local function view(open)
		return Column{}{Text{Text = "a"}, open && react.Portal{Target = target}{Inner{}}, Text{Text = "b"}}
	end

	local root = react.Mount(view(true), Panel.World)
	local column = root:GetEntity()
	T(table.concat(texts(column), ","))["=="]("a,b")
	T(#target:GetChildren())["=="](1)
	T(target:GetChildren()[1]:GetName())["=="]("in portal")
	root:Render(view(true))
	T(#target:GetChildren())["=="](1)
	root:Render(view(false))
	T(#target:GetChildren())["=="](0)
	T(table.concat(log, ","))["=="]("cleanup")
	root:Render(view(true))
	local inside = target:GetChildren()[1]
	inside:Remove()
	react.Flush()
	T(table.concat(log, ","))["=="]("cleanup,cleanup")
	root:Render(view(true))
	T(#target:GetChildren())["=="](1)
	T(target:GetChildren()[1] ~= inside)["=="](true)
	root:Unmount()
	T(#target:GetChildren())["=="](0)
	T(table.concat(log, ","))["=="]("cleanup,cleanup,cleanup")
	target:Remove()
end)

T.Test2D("react use poll recomputes every update without an interval, rarely with a long one and stops when unmounted", function()
	local event = import("goluwa/event.lua")
	local frame_calls = 0
	local slow_calls = 0
	local Frames = react.Component(|props| -> do
		local value = react.UsePoll(|| -> do
			frame_calls = frame_calls + 1

			return frame_calls
		end)

		return Text{Text = "frames " .. value}
	end)
	local Slow = react.Component(|props| -> do
		local value = react.UsePoll(|| -> do
			slow_calls = slow_calls + 1

			return slow_calls
		end, 1000)

		return Text{Text = "slow " .. value}
	end)
	local root = react.Mount(Column{}{Frames{}, Slow{}}, Panel.World)
	local column = root:GetEntity()
	T(table.concat(texts(column), ","))["=="]("frames 1,slow 1")
	event.CallUpdate(0.016)
	react.Flush()
	event.CallUpdate(0.016)
	react.Flush()
	T(table.concat(texts(column), ","))["=="]("frames 3,slow 1")
	root:Unmount()
	event.CallUpdate(0.016)
	T(frame_calls)["=="](3)
	T(slow_calls)["=="](1)
end)

T.Test2D("react use debounce follows a value on the first update after its delay and not before", function()
	local event = import("goluwa/event.lua")
	local Shown = react.Component(|props| -> Text{Text = props.Name .. " " .. react.UseDebounce(props.Value, props.Delay)})
	local function tree(value)
		return Column{}{Shown{Name = "now", Value = value, Delay = 0}, Shown{Name = "later", Value = value, Delay = 1000}}
	end
	local root = react.Mount(tree(1), Panel.World)
	local column = root:GetEntity()
	T(table.concat(texts(column), ","))["=="]("now 1,later 1")
	root:Render(tree(2))
	T(table.concat(texts(column), ","))["=="]("now 1,later 1")
	event.CallUpdate(0.016)
	react.Flush()
	T(table.concat(texts(column), ","))["=="]("now 2,later 1")
	root:Unmount()
end)

T.Test2D("react prop diff does not recurse into cyclic tables", function()
	local function make()
		local folder = {name = "folder", entries = {}}
		local entry = {name = "entry", folder = folder}
		folder.entries[1] = entry
		folder.parent = folder

		return {entry}
	end
	local root = react.Mount(Column{Data = make()}{}, Panel.World)
	root:Render(Column{Data = make()}{})
	root:Unmount()
end)

T.Test2D("react layout effect sees the layout of the render that scheduled it and an effect runs after it", function()
	local order = {}
	local heights = {}
	local Measured = react.Component(|props| -> do
		local box = react.UseRef()

		react.UseEffect(|| -> do
			order[#order + 1] = "effect"
		end, {})
		react.UseLayoutEffect(|| -> do
			order[#order + 1] = "layout"
			heights[#heights + 1] = box.current.transform:GetSize().y

			return || -> do
				order[#order + 1] = "cleanup"
			end
		end, {props.Rows})

		local rows = {}

		for i = 1, props.Rows do
			rows[i] = Text{Key = i, Text = "row " .. i}
		end

		return Column{Ref = box, layout = {FitHeight = true, FitWidth = true}}{rows}
	end)
	local root = react.Mount(Measured{Rows = 2}, Panel.World)
	T(table.concat(order, ","))["=="]("layout,effect")
	T(heights[1])[">"](0)
	root:Render(Measured{Rows = 4})
	T(table.concat(order, ","))["=="]("layout,effect,cleanup,layout")
	T(heights[2])[">"](heights[1])
	root:Unmount()
	T(table.concat(order, ","))["=="]("layout,effect,cleanup,layout,cleanup")
end)

T.Test2D("react use stable keeps its identity and calls the callback of the latest render", function()
	local seen = {}
	local calls = {}
	local Holder = react.Component(|props| -> do
		local stable = react.UseStable(|| -> props.Name)
		seen[#seen + 1] = stable
		calls[#calls + 1] = stable()

		return Text{Text = props.Name}
	end)
	local root = react.Mount(Column{}{Holder{Name = "first"}}, Panel.World)
	root:Render(Column{}{Holder{Name = "second"}})
	T(seen[1])["=="](seen[2])
	T(table.concat(calls, ","))["=="]("first,second")
	root:Unmount()
end)

T.Test2D("react open window opens once per key, hands the component a close and opens again after it", function()
	local closes = {}
	local Closable = react.Component(|props| -> do
		closes[#closes + 1] = props.Close

		return Text{Text = props.Title}
	end)
	local first = react.OpenWindow("test_window", Closable, {Title = "one"})
	T(react.OpenWindow("test_window", Closable, {Title = "two"}))["=="](first)
	T(#closes)["=="](1)
	closes[1]()
	T(first:IsValid())["=="](false)
	local second = react.OpenWindow("test_window", Closable, {Title = "three"})
	T(second ~= first)["=="](true)
	T(second.text:GetText())["=="]("three")
	closes[2]()
	T(second:IsValid())["=="](false)
end)

T.Test2D("react use drag reports the press, the moves outside the panel, the end and whether it was a click", function()
	local log = {}
	local PanelElement = react.Element(Panel)
	local Surface = react.Component(|| -> do
		local drag = react.UseDrag{
			OnDrag = |position, size, dx, dy, moved| -> do
				log[#log + 1] = ("drag %d,%d %dx%d moved=%s"):format(position.x, position.y, size.x, size.y, tostring(moved))
			end,
			OnEnd = |moved| -> do
				log[#log + 1] = "end moved=" .. tostring(moved)
			end,
		}

		return PanelElement{
			transform = true,
			Size = Vec2(100, 50),
			OnMouseInput = drag.OnMouseInput,
			OnGlobalMouseMove = drag.OnGlobalMouseMove,
			OnGlobalMouseInput = drag.OnGlobalMouseInput,
		}
	end)
	local root = react.Mount(Surface{}, Panel.World)
	local panel = root:GetEntity()
	T(panel.OnMouseInput(panel, "button_2", true, Vec2(1, 1)))["=="](nil)
	panel.OnGlobalMouseMove(panel, Vec2(500, 500))
	T(#log)["=="](0)
	panel.OnMouseInput(panel, "button_1", true, Vec2(10, 5))
	local x, y = import("goluwa/system.lua").GetWindow():GetMousePosition():Unpack()
	panel.OnGlobalMouseMove(panel, Vec2(x + 40, y))
	panel.OnGlobalMouseInput(panel, "button_1", false)
	panel.OnGlobalMouseMove(panel, Vec2(x + 80, y))
	T(log[1])["=="]("drag 10,5 100x50 moved=false")
	T(log[2]:starts_with("drag "))["=="](true)
	T(log[2]:ends_with("moved=true"))["=="](true)
	T(log[3])["=="]("end moved=true")
	T(#log)["=="](3)
	panel.OnMouseInput(panel, "button_1", true, Vec2(1, 1))
	panel.OnGlobalMouseInput(panel, "button_1", false)
	T(log[#log])["=="]("end moved=false")
	root:Unmount()
end)
