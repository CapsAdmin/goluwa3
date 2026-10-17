local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Dropdown = react.Element(import("goluwa/render2d/ui/widgets/dropdown.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Checkbox = react.Element(import("goluwa/render2d/ui/elements/checkbox.lua"))
local Slider = react.Element(import("goluwa/render2d/ui/elements/slider.lua"))
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local SceneView = import("goluwa/render3d/scene_view.lua")
local Environment = import("goluwa/render3d/environment.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local previews = import("lua/asset_preview.lua")
local kit = import("lua/editor_kit.lua")
local ViewerWindow = kit.ViewerWindow
local Canvas = kit.Canvas
local DEFAULT_ENVIRONMENT = "Studio"
local WINDOW_SIZE = Vec2(1040, 740)
local LOAD_TIMEOUT = 20
-- the view is rendered at multiples of this and stretched to the canvas, a bundle of passes is kept
-- for every size
local SIZE_STEP = 16
local RESIZE_DELAY = 0.25
local DOUBLE_CLICK_TIME = 0.3
local HELP = "drag to orbit, right drag to pan, wheel to zoom, double click to reset"

local function fit(state)
	local view = state.view
	state.visual:BuildAABB()
	local aabb = state.visual:GetWorldAABB()
	local size = Vec3(aabb.max_x - aabb.min_x, aabb.max_y - aabb.min_y, aabb.max_z - aabb.min_z)
	local center = Vec3(
		(aabb.min_x + aabb.max_x) / 2,
		(aabb.min_y + aabb.max_y) / 2,
		(aabb.min_z + aabb.max_z) / 2
	)
	state.orbit:Fit(center, math.max(size:GetLength() / 2, 1e-3), view:GetWidth() / view:GetHeight())
	state.orbit:Apply()
	view:Invalidate()
end

local function get_render_size(canvas_size)
	return math.max(math.floor(canvas_size.x / SIZE_STEP) * SIZE_STEP, SIZE_STEP * 4),
	math.max(math.floor(canvas_size.y / SIZE_STEP) * SIZE_STEP, SIZE_STEP * 4)
end

local function apply_size(state, width, height)
	state.view:SetWidth(width)
	state.view:SetHeight(height)
	state.view:SetSupersample(width * height <= 900 * 600 and 2 or 1)
end

local ModelView = react.Component(|props| -> do
	local entry = props.Entry
	local canvas = react.UseRef()
	local status, set_status = react.UseState("loading...")
	-- everything the frames and the mouse change lives here, the scene view and the entity go when the window does
	local state = react.UseResource(|| -> do
		local entity = props.Entity
		local view = SceneView.New{TransparentSky = false}
		local started = system.GetElapsedTime()
		view:SetEnvironment(Environment.GetPreset(DEFAULT_ENVIRONMENT))

		function view.OnDrawGeometry()
			SceneView.DrawVisual(entity.visual)
		end

		return {
			entity = entity,
			visual = entity.visual,
			view = view,
			orbit = OrbitCamera.New(view:GetCamera()),
			started = started,
			last_time = started,
			last_press = 0,
			ready = false,
			sized = false,
			failed = false,
			auto_rotate = false,
		}
	end, |state| -> do
		state.view:Remove()

		if state.entity:IsValid() then state.entity:Remove() end
	end, {})

	react.UseEvent("Update", || -> do
		local panel = canvas.current

		if not panel then return end

		local view = state.view
		local now = system.GetElapsedTime()
		local dt = math.min(now - state.last_time, 0.1)
		state.last_time = now
		local canvas_size = panel.transform:GetSize()

		if not state.sized then
			-- the layout hasn't given the canvas its size yet
			if canvas_size.x < SIZE_STEP * 4 or canvas_size.y < SIZE_STEP * 4 then return end

			state.sized = true
			local width, height = get_render_size(canvas_size)
			apply_size(state, width, height)
		end

		if not state.ready then
			if state.failed then return end

			if now - state.started > LOAD_TIMEOUT then
				state.failed = true
				set_status("could not load " .. entry.path)

				return
			end

			if
				not state.visual.Loading and
				state.visual:GetRenderEntries()[1] and
				previews.AreModelMaterialsReady(state.visual)
			then
				state.ready = true
				-- not before, the first render is at the size of the canvas
				view:SetAutoRender(true)
				fit(state)
				set_status(HELP)
			end

			return
		end

		-- the view follows the canvas once it has stopped changing size, a size of passes is not free
		local width, height = get_render_size(canvas_size)

		if width == view:GetWidth() and height == view:GetHeight() then
			state.pending_since = nil
		elseif
			state.pending_since == nil or
			width ~= state.pending_width or
			height ~= state.pending_height
		then
			state.pending_width, state.pending_height, state.pending_since = width, height, now
		elseif now - state.pending_since >= RESIZE_DELAY then
			state.pending_since = nil
			apply_size(state, width, height)
		end

		local changed = false

		if state.drag then
			-- the release isn't seen when it happens outside of the canvas
			if not input.IsMouseDown(state.drag_button) then
				state.drag = nil
			else
				local x, y = system.GetWindow():GetMousePosition():Unpack()
				local dx, dy = x - state.drag_x, y - state.drag_y
				state.drag_x, state.drag_y = x, y

				if dx ~= 0 or dy ~= 0 then
					if state.drag == "orbit" then
						state.orbit:Rotate(dx, dy)
					else
						state.orbit:Pan(dx, dy, view:GetHeight())
					end

					changed = true
				end
			end
		end

		if state.auto_rotate and not state.drag then
			state.orbit:Rotate(dt * 40, 0)
			changed = true
		end

		if changed then
			state.orbit:Apply()
			view:Invalidate()
		end
	end)

	local on_mouse_input = react.UseCallback(|self, button, press| -> do
		if button == "mwheel_up" or button == "mwheel_down" then
			if state.ready and press then
				state.orbit:Zoom(button == "mwheel_up" and -1 or 1)
				state.orbit:Apply()
				state.view:Invalidate()
			end

			return true
		end

		if button ~= "button_1" and button ~= "button_2" and button ~= "button_3" then return end

		if not press then
			state.drag = nil

			return true
		end

		if not state.ready then return true end

		state.drag_x, state.drag_y = system.GetWindow():GetMousePosition():Unpack()
		state.drag_button = button

		if button == "button_1" then
			state.drag = "orbit"
			local now = system.GetTime()

			if now - state.last_press < DOUBLE_CLICK_TIME then
				state.orbit:Reset()
				state.orbit:Apply()
				state.view:Invalidate()
				state.last_press = 0
			else
				state.last_press = now
			end
		else
			state.drag = "pan"
		end

		return true
	end, {})
	local draw = react.UseCallback(|self| -> do
		local size = self.Owner.transform:GetSize()
		render2d.SetTexture(nil)
		render2d.SetColor(0.07, 0.08, 0.09, 1)
		render2d.DrawRect(0, 0, size.x, size.y)

		if not (state.ready and state.view:HasRendered()) then return end

		render2d.PushTexture(state.view:GetTexture())
		render2d.PushColorUV(0, 1, 1, 0, 0)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
		render2d.PopColorUV()
		render2d.PopTexture()
	end, {})

	return ViewerWindow{
		Title = entry.path:upper(),
		Size = WINDOW_SIZE,
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
					OnSelect = |value| -> state.view:SetEnvironment(Environment.GetPreset(value)),
					layout = {MinSize = Vec2(180, 0), MaxSize = Vec2(180, 0), GrowWidth = 0},
				},
				Checkbox{
					Text = "Background",
					Value = true,
					OnChange = |value| -> state.view:SetTransparentSky(not value),
				},
				Checkbox{
					Text = "Auto rotate",
					Value = false,
					OnChange = |value| -> do state.auto_rotate = value end,
				},
				Text{Text = "Exposure", Color = "text_disabled", layout = {FitWidth = true}},
				Slider{
					Mode = "horizontal",
					Min = -4,
					Max = 4,
					Value = 0,
					OnChange = |value| -> state.view:SetExposureCompensation(value),
					Tooltip = "exposure compensation in stops",
					layout = {MinSize = Vec2(140, 16), MaxSize = Vec2(140, 16), FitWidth = false},
				},
				Button{
					Text = "Reset view",
					Mode = "outline",
					OnClick = || -> do
						if not state.ready then return end

						state.orbit:Reset()
						state.orbit:Apply()
						state.view:Invalidate()
					end,
				},
			},
			Canvas{
				Name = "ModelViewerCanvas",
				Cursor = "sizeall",
				Ref = canvas,
				OnDraw = draw,
				OnMouseInput = on_mouse_input,
			},
			Text{Text = status, Color = "text_disabled", layout = {GrowWidth = 1}},
		},
	}
end)

return function(entry)
	return kit.OpenOnce("ModelViewer/" .. entry.path, function()
		local entity = previews.CreateModelEntity(entry.path)

		if not entity then return end

		return react.Mount(ModelView{Entry = entry, Entity = entity}, Panel.World):GetEntity()
	end)
end
