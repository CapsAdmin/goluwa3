local event = require("event")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local window = require("window")
local input = require("input")
package.loaded["gui.gui"] = nil
package.loaded["gui.lsx"] = nil
package.loaded["gui.base_surface"] = nil
package.loaded["gui.base_surface_layout"] = nil
require("gui.gui").Initialize()
local lsx = require("gui.lsx")

local function UseTime()
	local time, set_time = lsx.UseState(0)

	lsx.UseEffect(
		function()
			return event.AddListener("Update", {}, function(dt)
				set_time(function(t)
					return t + dt
				end)
			end)
		end,
		{}
	)

	return time
end

local function UseMouse()
	local pos, set_pos = lsx.UseState(Vec2(0, 0))

	lsx.UseEffect(
		function()
			return event.AddListener("Update", {}, function()
				local mpos = window.GetMousePosition()
				set_pos(Vec2(mpos.x, mpos.y))
			end)
		end,
		{}
	)

	return pos
end

local function UseHover(ref)
	local is_hovered, set_hovered = lsx.UseState(false)
	local mouse = UseMouse()

	lsx.UseEffect(
		function()
			if ref.current then
				local hovered = ref.current:IsHovered(mouse)
				set_hovered(hovered)
			end
		end,
		{mouse.x, mouse.y}
	)

	return is_hovered
end

local function UsePrevious(value)
	local ref = UseRef(nil)

	lsx.UseEffect(function()
		ref.current = value
	end, {value})

	return ref.current
end

local function UseToggle(initial)
	local value, set_value = lsx.UseState(initial or false)
	local toggle = UseCallback(function()
		set_value(function(v)
			return not v
		end)
	end, {})
	return value, toggle
end

local MouseFollower = lsx.Component(function(props)
	local mouse = UseMouse()
	local time = UseTime()
	return lsx.Panel(
		{
			Position = mouse - 40,
			Size = Vec2(80, 80),
			Rotation = time * 90,
			Color = Color(
				0.5 + math.sin(time * 2) * 0.5,
				0.5 + math.sin(time * 2.5) * 0.5,
				0.5 + math.sin(time * 3) * 0.5,
				0.7
			),
		}
	)
end)
local HoverPanel = lsx.Component(function(props)
	local ref = lsx.UseRef(nil)
	local is_hovered = UseHover(ref)
	local time = UseTime()
	return lsx.Panel(
		{
			Name = "HoverPanel",
			ref = ref,
			Position = props.Position,
			Size = props.Size or Vec2(120, 80),
			Scale = Vec2() + (is_hovered and 1.1 or 1.0),
			Color = (props.Color or Color(0.4, 0.4, 0.5, 1)):GetLerped(is_hovered and 1 or 0, Color(0.6, 0.7, 0.9, 1)):SetAlpha(1),
		}
	)
end)
local Slider = lsx.Component(function(props)
	local value, set_value = lsx.UseState(props.Value or 0.5)
	local is_dragging, set_dragging = lsx.UseState(false)
	local track_ref = lsx.UseRef(nil)
	local width = props.Width or 200
	local height = props.Height or 30
	local handle_width = 20
	local handle_x = value * (width - handle_width)

	lsx.UseEffect(
		function()
			if not is_dragging then return end

			return event.AddListener("Update", {}, function()
				if not track_ref.current then return end

				if not input.IsMouseDown("button_1") then
					set_dragging(false)
					return
				end

				local mpos = window.GetMousePosition()
				local local_pos = track_ref.current:GlobalToLocal(mpos)
				local new_value = math.max(0, math.min(1, local_pos.x / width))
				set_value(new_value)

				if props.OnChange then props.OnChange(new_value) end
			end)
		end,
		{is_dragging, width}
	)

	return lsx.Panel(
		{
			Name = "Slider",
			ref = track_ref,
			Position = props.Position,
			Size = Vec2(width, height),
			Color = Color(0.25, 0.25, 0.3, 1),
			OnMouseInput = function(self, button, press, local_pos)
				if press and button == "button_1" then
					local new_value = math.max(0, math.min(1, local_pos.x / width))
					set_value(new_value)

					if props.OnChange then props.OnChange(new_value) end

					set_dragging(true)
					return true
				elseif not press then
					set_dragging(false)
				end
			end,
			lsx.Panel(
				{
					Position = Vec2(0, 0),
					Size = Vec2(handle_x + handle_width / 2, height),
					Color = props.FillColor or Color(0.4, 0.6, 0.9, 1),
				}
			),
			lsx.Panel(
				{
					Position = Vec2(handle_x, 0),
					Size = Vec2(handle_width, height),
					Color = Color(0.9, 0.9, 0.95, 1),
				}
			),
			lsx.Text(
				{
					Position = Vec2(width + 10, 0),
					Text = string.format("%.2f", value),
					Color = Color(1, 1, 1, 1),
					AlignY = "center",
					Size = Vec2(40, height),
				}
			),
		}
	)
end)
local ColorPicker = lsx.Component(function(props)
	local r, set_r = lsx.UseState(props.Initial and props.Initial.r or 0.5)
	local g, set_g = lsx.UseState(props.Initial and props.Initial.g or 0.5)
	local b, set_b = lsx.UseState(props.Initial and props.Initial.b or 0.5)
	local preview_color = Color(r, g, b, 1)
	local on_change = props.OnChange

	lsx.UseEffect(function()
		if on_change then on_change(preview_color) end
	end, {r, g, b})

	return lsx.Panel(
		{
			Position = props.Position,
			Size = Vec2(250, 200),
			Color = Color(0.2, 0.2, 0.25, 1),
			Name = "ColorPicker",
			lsx.Text(
				{
					Position = Vec2(10, 5),
					Text = "Color Picker",
					Color = Color(0.8, 0.8, 1, 1),
				}
			),
			lsx.Panel(
				{
					Position = Vec2(180, 40),
					Size = Vec2(50, 140),
					Color = preview_color,
				}
			),
			Slider(
				{
					Position = Vec2(20, 40),
					Width = 140,
					Height = 30,
					Value = r,
					FillColor = Color(0.9, 0.2, 0.2, 1),
					OnChange = set_r,
				}
			),
			Slider(
				{
					Position = Vec2(20, 90),
					Width = 140,
					Height = 30,
					Value = g,
					FillColor = Color(0.2, 0.9, 0.2, 1),
					OnChange = set_g,
				}
			),
			Slider(
				{
					Position = Vec2(20, 140),
					Width = 140,
					Height = 30,
					Value = b,
					FillColor = Color(0.2, 0.2, 0.9, 1),
					OnChange = set_b,
				}
			),
		}
	)
end)

local function UseReducer(reducer, initialState)
	local state, set_state = lsx.UseState(initialState)
	local dispatch = lsx.UseCallback(
		function(action)
			set_state(function(current)
				return reducer(current, action)
			end)
		end,
		{}
	)
	return state, dispatch
end

local StateMachine = lsx.Component(function(props)
	local function reducer(state, action)
		if action == "NEXT" then
			return (state % 4) + 1
		elseif action == "PREV" then
			return ((state - 2) % 4) + 1
		elseif action == "RESET" then
			return 1
		end

		return state
	end

	local state, dispatch = UseReducer(reducer, 1)
	local colors = {
		Color(0.9, 0.3, 0.3, 1), -- Red
		Color(0.3, 0.9, 0.3, 1), -- Green
		Color(0.3, 0.3, 0.9, 1), -- Blue
		Color(0.9, 0.9, 0.3, 1), -- Yellow
	}
	return lsx.Panel(
		{
			Position = props.Position,
			Size = Vec2(150, 150),
			Color = colors[state],
			Name = "StateMachine_" .. state,
			OnMouseInput = function(self, button, press)
				if press then
					if button == "button_1" then
						dispatch("NEXT")
					elseif button == "button_2" then
						dispatch("PREV")
					elseif button == "button_3" then
						dispatch("RESET")
					end

					return true
				end
			end,
			lsx.Text(
				{
					Position = Vec2(75, 75),
					Text = "State: " .. state .. "\nL: Next\nR: Prev\nM: Reset",
					Color = Color(0, 0, 0, 1),
					AlignX = "center",
					AlignY = "center",
				}
			),
		}
	)
end)
local App = lsx.Component(function()
	return lsx.Panel(
		{
			Name = "App",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0),
			Padding = Rect(20, 20, 20, 20),
			lsx.Text(
				{
					Text = "The quick brown fox jumps over the lazy dog.",
					Color = Color(0, 0, 0, 1),
					Debug = true,
					Layout = {"MoveTop", "CenterXSimple"},
					Padding = Rect() + 10,
				}
			),
			lsx.Panel(
				{
					Name = "content",
					Color = Color(0, 0, 0, 0),
					Layout = {"Fill"},
					lsx.Panel(
						{
							Name = "LeftColumn",
							Width = 300,
							Color = Color(0, 0, 1, 1),
							Layout = {"CenterYSimple", "MoveLeft", "FillY"},
							HoverPanel(
								{
									Position = Vec2(20, 0),
									Size = Vec2(50, 50),
									Color = Color(1, 0.3, 0.4, 1),
									Layout = {"CenterXSimple"},
									ref = function(pnl)
										print(pnl)
									end,
								}
							),
							nil,
							HoverPanel(
								{
									Size = Vec2(50, 50),
									Color = Color(0.5, 0.3, 0.4, 1),
									Layout = {"CenterX", "MoveUp"},
									Margin = Rect(0, 0, 0, 10),
								}
							),
						}
					),
					nil,
					lsx.Panel(
						{
							Name = "MiddleColumn",
							Size = Vec2(300, 500),
							Color = Color(0, 0, 0, 0),
							Layout = {"MoveRight"},
							Margin = Rect(20, 40, 0, 0),
							Slider(
								{
									Width = 200,
									Layout = {"MoveDown"},
									Margin = Rect(0, 0, 0, 20),
									OnChange = function(v)
										print("Slider:", v)
									end,
								}
							),
							ColorPicker(
								{
									Initial = Color(0.3, 0.6, 0.9),
									Layout = {"MoveDown"},
									OnChange = function(c)
										print("Color:", c.r, c.g, c.b)
									end,
								}
							),
						}
					),
					StateMachine({
						Layout = {"MoveRight"},
						Margin = Rect(20, 40, 0, 0),
					}),
				}
			),
		}
	)
end)
lsx.Mount(App())
