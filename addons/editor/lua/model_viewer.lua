local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local SceneView = import("goluwa/render3d/scene_view.lua")
local Environment = import("goluwa/render3d/environment.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local previews = import("lua/asset_preview.lua")
local DEFAULT_ENVIRONMENT = "Nishita midday"
local WINDOW_SIZE = Vec2(1040, 740)
local LOAD_TIMEOUT = 20
-- the view is rendered at multiples of this and stretched to the canvas, a bundle of passes is kept
-- for every size
local SIZE_STEP = 16
local RESIZE_DELAY = 0.25
local DOUBLE_CLICK_TIME = 0.3
local HELP = "drag to orbit, right drag to pan, wheel to zoom, double click to reset"
return function(entry)
	local key = "ModelViewer/" .. entry.path
	local open = Panel.World:GetKeyed(key)

	if open then return open end

	local entity = previews.CreateModelEntity(entry.path)

	if not entity then return end

	local visual = entity.visual
	local view = SceneView.New{TransparentSky = false}
	view:SetEnvironment(Environment.GetPreset(DEFAULT_ENVIRONMENT))

	function view.OnDrawGeometry()
		SceneView.DrawVisual(visual)
	end

	local orbit = OrbitCamera.New(view:GetCamera())
	local started = system.GetElapsedTime()
	local last_time = started
	local ready = false
	local sized = false
	local failed = false
	local auto_rotate = false
	local drag
	local drag_button
	local drag_x
	local drag_y
	local last_press = 0
	local pending_width
	local pending_height
	local pending_since
	local status_text

	local function set_status(text)
		if status_text and status_text:IsValid() then status_text.text:SetText(text) end
	end

	local function fit()
		visual:BuildAABB()
		local aabb = visual:GetWorldAABB()
		local size = Vec3(aabb.max_x - aabb.min_x, aabb.max_y - aabb.min_y, aabb.max_z - aabb.min_z)
		local center = Vec3(
			(aabb.min_x + aabb.max_x) / 2,
			(aabb.min_y + aabb.max_y) / 2,
			(aabb.min_z + aabb.max_z) / 2
		)
		orbit:Fit(center, math.max(size:GetLength() / 2, 1e-3), view:GetWidth() / view:GetHeight())
		orbit:Apply()
		view:Invalidate()
	end

	local function update_loading(now)
		if failed then return end

		if now - started > LOAD_TIMEOUT then
			failed = true
			set_status("could not load " .. entry.path)
			return
		end

		local entries = visual:GetRenderEntries()

		if not visual.Loading and entries[1] and previews.AreModelMaterialsReady(visual) then
			ready = true
			-- not before, the first render is at the size of the canvas
			view:SetAutoRender(true)
			fit()
			set_status(HELP)
		end
	end

	local function get_render_size(canvas_size)
		return math.max(math.floor(canvas_size.x / SIZE_STEP) * SIZE_STEP, SIZE_STEP * 4),
		math.max(math.floor(canvas_size.y / SIZE_STEP) * SIZE_STEP, SIZE_STEP * 4)
	end

	local function apply_size(width, height)
		view:SetWidth(width)
		view:SetHeight(height)
		view:SetSupersample(width * height <= 900 * 600 and 2 or 1)
	end

	-- the view follows the canvas once it has stopped changing size, a size of passes is not free
	local function update_size(now, canvas_size)
		local width, height = get_render_size(canvas_size)

		if width == view:GetWidth() and height == view:GetHeight() then
			pending_since = nil
			return
		end

		if pending_since == nil or width ~= pending_width or height ~= pending_height then
			pending_width, pending_height, pending_since = width, height, now
			return
		end

		if now - pending_since < RESIZE_DELAY then return end

		pending_since = nil
		apply_size(width, height)
	end

	local function update_drag()
		if not drag then return false end

		-- the release isn't seen when it happens outside of the canvas
		if not input.IsMouseDown(drag_button) then
			drag = nil
			return false
		end

		local x, y = system.GetWindow():GetMousePosition():Unpack()
		local dx, dy = x - drag_x, y - drag_y
		drag_x, drag_y = x, y

		if dx == 0 and dy == 0 then return false end

		if drag == "orbit" then
			orbit:Rotate(dx, dy)
		else
			orbit:Pan(dx, dy, view:GetHeight())
		end

		return true
	end

	local function on_update(self)
		local now = system.GetElapsedTime()
		local dt = math.min(now - last_time, 0.1)
		last_time = now
		local canvas_size = self.transform:GetSize()

		if not sized then
			-- the layout hasn't given the canvas its size yet
			if canvas_size.x < SIZE_STEP * 4 or canvas_size.y < SIZE_STEP * 4 then return end

			sized = true
			apply_size(get_render_size(canvas_size))
		end

		if not ready then
			update_loading(now)
			return
		end

		update_size(now, canvas_size)
		local changed = update_drag()

		if auto_rotate and not drag then
			orbit:Rotate(dt * 40, 0)
			changed = true
		end

		if changed then
			orbit:Apply()
			view:Invalidate()
		end
	end

	local function on_mouse_input(self, button, press)
		if button == "mwheel_up" or button == "mwheel_down" then
			if ready and press then
				orbit:Zoom(button == "mwheel_up" and -1 or 1)
				orbit:Apply()
				view:Invalidate()
			end

			return true
		end

		if button ~= "button_1" and button ~= "button_2" and button ~= "button_3" then
			return
		end

		if not press then
			drag = nil
			return true
		end

		if not ready then return true end

		drag_x, drag_y = system.GetWindow():GetMousePosition():Unpack()
		drag_button = button

		if button == "button_1" then
			drag = "orbit"
			local now = system.GetTime()

			if now - last_press < DOUBLE_CLICK_TIME then
				orbit:Reset()
				orbit:Apply()
				view:Invalidate()
				last_press = 0
			else
				last_press = now
			end
		else
			drag = "pan"
		end

		return true
	end

	local function draw_canvas(self)
		local size = self.Owner.transform:GetSize()
		render2d.SetTexture(nil)
		render2d.SetColor(0.07, 0.08, 0.09, 1)
		render2d.DrawRect(0, 0, size.x, size.y)

		if not (ready and view:HasRendered()) then return end

		render2d.PushTexture(view:GetTexture())
		render2d.PushColorUV(0, 1, 1, 0, 0)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
		render2d.PopColorUV()
		render2d.PopTexture()
	end

	local window = Window{
		Key = key,
		Title = entry.path:upper(),
		Size = WINDOW_SIZE,
		Padding = "none",
		Position = (Panel.World.transform:GetSize() - WINDOW_SIZE) / 2,
		layout = {FitHeight = false, FitWidth = false},
	}{
		Column{
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				FitHeight = false,
				AlignmentX = "stretch",
				ChildGap = 6,
				Padding = Rect() + 8,
			},
		}{
			Row{layout = {GrowWidth = 1, ChildGap = 10, AlignmentY = "center"}}{
				Text{Text = "Environment", Color = "text_disabled", layout = {FitWidth = true}},
				Dropdown{
					Options = Environment.GetPresetNames(),
					Value = DEFAULT_ENVIRONMENT,
					Padding = "XS",
					OnSelect = function(value)
						view:SetEnvironment(Environment.GetPreset(value))
					end,
					layout = {MinSize = Vec2(180, 0), MaxSize = Vec2(180, 0), GrowWidth = 0},
				},
				Checkbox{
					Text = "Background",
					Value = true,
					OnChange = function(value)
						view:SetTransparentSky(not value)
					end,
				},
				Checkbox{
					Text = "Auto rotate",
					Value = false,
					OnChange = function(value)
						auto_rotate = value
					end,
				},
				Text{Text = "Exposure", Color = "text_disabled", layout = {FitWidth = true}},
				Slider{
					Mode = "horizontal",
					Min = -4,
					Max = 4,
					Value = 0,
					OnChange = function(value)
						view:SetExposureCompensation(value)
					end,
					Tooltip = "exposure compensation in stops",
					layout = {MinSize = Vec2(140, 16), MaxSize = Vec2(140, 16), FitWidth = false},
				},
				Button{
					Text = "Reset view",
					Mode = "outline",
					OnClick = function()
						if not ready then return end

						orbit:Reset()
						orbit:Apply()
						view:Invalidate()
					end,
				},
			},
			Panel.New{
				Name = "ModelViewerCanvas",
				transform = true,
				visual = {OnDraw = draw_canvas},
				mouse_input = {Cursor = "sizeall"},
				layout = {GrowWidth = 1, GrowHeight = 1},
				Ref = function(self)
					self:AddGlobalEvent("Update")
				end,
				OnUpdate = on_update,
				OnMouseInput = on_mouse_input,
			},
			Text{
				Ref = function(self)
					status_text = self
				end,
				Text = "loading...",
				Color = "text_disabled",
				layout = {GrowWidth = 1},
			},
		},
	}

	window:CallOnRemove(
		function()
			view:Remove()

			if entity:IsValid() then entity:Remove() end
		end,
		"model_viewer_cleanup"
	)

	return Panel.World:Ensure(window)
end
