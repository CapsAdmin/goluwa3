local T = import("test/environment.lua")
local attest = import("goluwa/helpers/attest.lua")
local commands = import("goluwa/commands.lua")
local gine = import("goluwa/gmod/gine.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local resource = import("goluwa/resource.lua")
local system = import("goluwa/system.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local test_render = import("test/test_render.lua")

local function ensure_ginit()
	return test_render.InitGMod2D("sandbox", 1)
end

local function pump_draws(frame_count)
	local clear_id = {}

	event.AddListener("PreDraw2D", clear_id, function()
		render2d.SetColor(0, 0, 0, 1)
		render2d.DrawRect(0, 0, render.GetWidth(), render.GetHeight())
	end)

	for _ = 1, frame_count do
		render.Draw(0.016)
	end

	event.RemoveListener("PreDraw2D", clear_id)
end

local function find_panels_by_class(class_name)
	local out = {}

	for _, panel in ipairs(gine.env.vgui.GetAll()) do
		if panel:IsValid() and panel:GetClassName() == class_name then
			out[#out + 1] = panel
		end
	end

	return out
end

local function assert_pixel_close(tex, x, y, expected, tolerance, label)
	local r, g, b, a = tex:GetPixel(x, y)
	local actual = {r / 255, g / 255, b / 255, a / 255}

	for i = 1, 4 do
		local delta = math.abs(actual[i] - expected[i])

		if delta > tolerance then
			error(
				(
					"%s pixel mismatch at (%d, %d): expected %.3f %.3f %.3f %.3f, got %.3f %.3f %.3f %.3f"
				):format(
					label,
					x,
					y,
					expected[1],
					expected[2],
					expected[3],
					expected[4],
					actual[1],
					actual[2],
					actual[3],
					actual[4]
				),
				0
			)
		end
	end
end

T.Test("gmod ginit bootstrap smoke", function()
	ensure_ginit()
	attest.truthy(gine.env)
	attest.truthy(gine.env.include)
	attest.truthy(gine.env.gamemode)
	attest.truthy(gine.env.gamemode.Register)
	attest.truthy(gine.env.gamemode.Call)
end)

T.Test("gmod Color wrapper smoke", function()
	ensure_ginit()
	local color = gine.env.Color(12, 34, 56, 78)
	local h, s, v = gine.env.ColorToHSV(color)
	local h2, s2, v2 = gine.env.ColorToHSV(color.r, color.g, color.b)
	local hsv_color = gine.env.HSVToColor(h, s, v)
	local copy = gine.env.Color(color.r, color.g, color.b, color.a)
	attest.truthy(gine.env.IsColor(color))
	attest.equal(color.r, 12)
	attest.equal(color.g, 34)
	attest.equal(color.b, 56)
	attest.equal(color.a, 78)
	attest.equal(h, h2)
	attest.equal(s, s2)
	attest.equal(v, v2)
	attest.truthy(type(h) == "number" and h >= 0 and h <= 1)
	attest.truthy(type(s) == "number" and s >= 0 and s <= 1)
	attest.truthy(type(v) == "number" and v >= 0 and v <= 1)
	attest.truthy(hsv_color ~= nil)
	copy.r = 200
	attest.equal(color.r, 12)
	attest.equal(copy.r, 200)
end)

T.Test("gmod derma_controls Draw2D smoke", function()
	ensure_ginit()
	local ok, err
	ok, err = commands.ExecuteCommandString("derma_controls")

	if not ok then error(err, 0) end

	attest.truthy(gine.gui_world)
	attest.truthy(gine.gui_world:IsValid())
	pump_draws(3)
end)

T.Test("gmod derma popup interaction defaults", function()
	ensure_ginit()
	gine.env.gui.EnableScreenClicker(false)
	local frame = gine.env.vgui.Create("DFrame")
	local skin = gine.env.derma and
		gine.env.derma.GetDefaultSkin and
		gine.env.derma.GetDefaultSkin() or
		nil
	local title_color = skin and skin.Colours and skin.Colours.Window and skin.Colours.Window.TitleActive
	attest.truthy(frame)
	attest.truthy(frame:IsEnabled())
	attest.truthy(title_color)
	attest.falsy(title_color.r == 255 and title_color.g == 0 and title_color.b == 255)
	frame:MakePopup()
	attest.truthy(gine.env.vgui.CursorVisible())

	if frame and frame.IsValid and frame:IsValid() then frame:Remove() end

	gine.env.gui.EnableScreenClicker(false)
end)

T.Test("gmod label content size applies inset once", function()
	ensure_ginit()
	local label = gine.env.vgui.Create("DLabel")
	label:SetText("Inset Test")
	label:SetTextInset(10, 4)
	local text_w, text_h = label:GetTextSize()
	local content_w, content_h = label:GetContentSize()
	attest.equal(content_w, text_w + 10)
	attest.equal(content_h, text_h + 4)
	label:SizeToContents()
	attest.equal(label:GetWide(), content_w)
	attest.equal(label:GetTall(), content_h)

	if label.Remove then label:Remove() end
end)

T.Test("gmod button hover text color resets on leave", function()
	ensure_ginit()
	local skin = gine.env.derma and
		gine.env.derma.GetDefaultSkin and
		gine.env.derma.GetDefaultSkin() or
		nil
	local button = gine.env.vgui.Create("DButton")
	local wnd = system.GetWindow()
	local hover_color = skin and skin.Colours and skin.Colours.Button and skin.Colours.Button.Hover
	local normal_color = skin and skin.Colours and skin.Colours.Button and skin.Colours.Button.Normal
	attest.truthy(button)
	attest.truthy(hover_color)
	attest.truthy(normal_color)
	button:SetPos(120, 120)
	button:SetSize(180, 28)
	button:SetText("Hover me")
	button:InvalidateLayout(true)
	wnd:SetMousePosition(Vec2(140, 134))
	event.Call("Update")
	pump_draws(1)
	local active_hover = button:GetTextStyleColor()
	attest.equal(active_hover.r, hover_color.r)
	attest.equal(active_hover.g, hover_color.g)
	attest.equal(active_hover.b, hover_color.b)
	wnd:SetMousePosition(Vec2(20, 20))
	event.Call("Update")
	pump_draws(1)
	local active_normal = button:GetTextStyleColor()
	attest.equal(active_normal.r, normal_color.r)
	attest.equal(active_normal.g, normal_color.g)
	attest.equal(active_normal.b, normal_color.b)

	if button.Remove then button:Remove() end
end)

T.Test("gmod surface GetTextSize includes descender space", function()
	ensure_ginit()
	local font = gine.render2d_fonts.dermadefault
	attest.truthy(font)
	gine.env.surface.SetFont("DermaDefault")
	local raw_w, raw_h = font:GetTextSize("Hg")
	local surface_w, surface_h = gine.env.surface.GetTextSize("Hg")
	local expected_w, expected_h = gine.MeasureTextBoundsForGMod(font, "Hg")
	attest.equal(surface_w, expected_w)
	attest.equal(surface_h, expected_h)
	attest.truthy(surface_h >= raw_h)
end)

T.Test("gmod text-bearing controls compute aligned text offsets", function()
	ensure_ginit()
	local button = gine.env.vgui.Create("DButton")
	button:SetSize(220, 36)
	button:SetText("Centered button")
	button:InvalidateLayout(true)
	local button_offset = button.__obj.text_offset
	local button_text_w, button_text_h = button:GetTextSize()
	attest.truthy(button_offset.x > 0)
	attest.truthy(button_offset.y > 0)
	attest.truthy(button_offset.x + button_text_w <= button:GetWide())
	attest.truthy(button_offset.y + button_text_h <= button:GetTall())

	if button.Remove then button:Remove() end
end)

T.Test("gmod popup mouse click dispatch", function()
	ensure_ginit()

	if Panel.World and Panel.World.IsValid and Panel.World:IsValid() then
		Panel.World:RemoveChildren()
	end

	local wnd = system.GetWindow()
	local frame = gine.env.vgui.Create("DFrame")
	local button = gine.env.vgui.Create("DButton", frame)
	local overlay = Panel.New{
		Parent = Panel.World,
		Name = "overlay_blocker",
		transform = {
			Size = wnd:GetSize(),
		},
		gui_element = true,
		mouse_input = true,
	}
	local clicked = 0
	local pressed = 0
	local released = 0
	frame:SetSize(240, 160)
	frame:SetPos(420, 260)
	frame:MakePopup()
	button:SetPos(30, 40)
	button:SetSize(100, 30)
	attest.falsy(button.__obj.mouse_input:GetIgnoreMouseInput())
	attest.truthy(frame.__obj:HasChild(button.__obj))
	local screen_x, screen_y = button:LocalToScreen(0, 0)
	attest.equal(screen_x, 450)
	attest.equal(screen_y, 300)
	attest.truthy(button.__obj.gui_element:IsHovered(Vec2(470, 315)))

	function button:DoClick()
		clicked = clicked + 1
	end

	function button:OnMousePressed(code)
		pressed = pressed + 1
		return self.BaseClass.OnMousePressed(self, code)
	end

	function button:OnMouseReleased(code)
		released = released + 1
		return self.BaseClass.OnMouseReleased(self, code)
	end

	wnd:SetMousePosition(Vec2(470, 315))
	event.Call("Update")
	attest.truthy(gine.gui_world:GetParent() == Panel.World)
	local world_children = Panel.World:GetChildren()
	local top_child = world_children[#world_children]

	if top_child ~= gine.gui_world then
		local top_name = top_child and top_child.GetName and top_child:GetName() or tostring(top_child)
		error(("expected gui_world on top, got %s"):format(tostring(top_name)), 0)
	end

	button.__obj:CallLocalEvent("OnMouseInput", "button_1", true, Vec2(20, 15))
	button.__obj:CallLocalEvent("OnMouseInput", "button_1", false, Vec2(20, 15))
	attest.equal(pressed, 1)
	attest.equal(released, 1)
	attest.equal(clicked, 1)

	if overlay.Remove then overlay:Remove() end

	if button.Remove then button:Remove() end

	if frame.Remove then frame:Remove() end

	gine.env.gui.EnableScreenClicker(false)
end)

T.Test("gmod property sheet fill tab switch and menubar popup", function()
	ensure_ginit()
	local ok, err = commands.ExecuteCommandString("derma_controls")
	local sheet, menu_bar, file_menu, page_y, menu_x, menu_y, menu_w, menu_h

	if not ok then error(err, 0) end

	pump_draws(2)

	for _, pnl in ipairs(gine.env.vgui.GetAll()) do
		if pnl:IsValid() and pnl:GetClassName() == "DPropertySheet" then
			sheet = pnl

			break
		end
	end

	attest.truthy(sheet)

	for _, item in ipairs(sheet.Items or {}) do
		if item.Tab and item.Tab:GetText() == "DMenuBar" then
			item.Tab:DoClick()
			menu_bar = item.Panel:GetChildren()[1]

			break
		end
	end

	attest.truthy(menu_bar)
	pump_draws(1)
	_, page_y = menu_bar:GetParent():GetPos()
	attest.truthy(page_y < 120)
	attest.truthy(menu_bar:GetParent():GetTall() > 100)
	file_menu = menu_bar.Menus and menu_bar.Menus.File
	attest.truthy(file_menu)
	attest.falsy(file_menu:IsVisible())
	menu_bar:GetChildren()[1]:DoClick()
	pump_draws(1)
	menu_x, menu_y = file_menu:GetPos()
	menu_w, menu_h = file_menu:GetSize()
	attest.truthy(file_menu:IsVisible())
	attest.truthy(menu_y > page_y)
	attest.truthy(menu_w > 100)
	attest.truthy(menu_h > 40)
	gine.env.gui.EnableScreenClicker(false)
end)

T.Test("gmod dtree child lists report content size and expand", function()
	ensure_ginit()
	local ok, err = commands.ExecuteCommandString("derma_controls")
	local sheet, tree, root_list, node

	if not ok then error(err, 0) end

	pump_draws(2)

	for _, pnl in ipairs(gine.env.vgui.GetAll()) do
		if pnl:IsValid() and pnl:GetClassName() == "DPropertySheet" then
			sheet = pnl

			break
		end
	end

	attest.truthy(sheet)

	for _, item in ipairs(sheet.Items or {}) do
		if item.Tab and item.Tab:GetText() == "DTree" then
			item.Tab:DoClick()
			tree = item.Panel

			break
		end
	end

	attest.truthy(tree)
	pump_draws(1)
	root_list = tree.RootNode and tree.RootNode.ChildNodes
	attest.truthy(root_list)
	local list_w, list_h = root_list:ChildrenSize()
	attest.truthy(list_w >= 300)
	attest.truthy(root_list:GetTall() >= 68)
	node = root_list:GetChildren()[2]
	attest.truthy(node)
	attest.truthy(node.ChildNodes)
	node:SetExpanded(true, true)
	pump_draws(1)
	attest.truthy(node:GetTall() > 100)
	attest.truthy(node.ChildNodes:IsVisible())
	attest.truthy(node.ChildNodes:GetTall() >= 102)
	gine.env.gui.EnableScreenClicker(false)
end)

T.Test("gmod frame drag uses primary window mouse", function()
	ensure_ginit()
	local primary = system.GetWindow()
	local frame = gine.env.vgui.Create("DFrame")
	local dummy = {
		pos = Vec2(7, 9),
		cursor = "arrow",
		size = primary:GetSize():Copy(),
		IsValid = function()
			return true
		end,
		GetSize = function(self)
			return self.size
		end,
		GetFramebufferSize = function(self)
			return self.size
		end,
		GetMousePosition = function(self)
			return self.pos
		end,
		SetMousePosition = function(self, pos)
			self.pos = pos
		end,
		GetCursor = function(self)
			return self.cursor
		end,
		SetCursor = function(self, cursor)
			self.cursor = cursor
		end,
		SetMouseTrapped = function() end,
	}
	frame:SetSize(240, 160)
	frame:SetPos(10, 10)
	primary:SetMousePosition(Vec2(20, 20))
	system.RegisterWindow(dummy)
	frame:OnMousePressed(gine.env.MOUSE_LEFT)
	primary:SetMousePosition(Vec2(70, 60))
	pump_draws(2)
	attest.truthy(frame.x ~= 10 or frame.y ~= 10)
	system.UnregisterWindow(dummy)

	if frame.Remove then frame:Remove() end

	primary:SetMousePosition(Vec2(0, 0))

	if system.GetCurrentWindow() ~= primary then system.SetCurrentWindow(primary) end

	if gine.env and gine.env.gui then gine.env.gui.EnableScreenClicker(false) end
end)

T.Test("gmod property sheet active panel stretches", function()
	ensure_ginit()
	local sheet = gine.env.vgui.Create("DPropertySheet")
	local page = gine.env.vgui.Create("DPanel")
	sheet:SetSize(320, 240)
	sheet:AddSheet("Example", page)
	sheet:InvalidateLayout(true)
	attest.truthy(page:GetWide() > 200)
	attest.truthy(page:GetTall() > 100)

	if sheet and sheet.IsValid and sheet:IsValid() then sheet:Remove() end

	if page and page.IsValid and page:IsValid() then page:Remove() end
end)

T.Test("gmod scoreboard Draw2D smoke", function()
	ensure_ginit()
	gine.env.gamemode.Call("ScoreboardShow")
	attest.truthy(gine.env.GetHostName)
	attest.truthy(gine.gui_world)
	attest.truthy(gine.gui_world:IsValid())
	pump_draws(3)
	gine.env.gamemode.Call("ScoreboardHide")
end)

T.Test("gmod surface DrawRect runtime smoke", function()
	ensure_ginit()
	local frames = 0
	local id = {}

	event.AddListener("Draw2D", id, function()
		frames = frames + 1
		gine.env.surface.SetDrawColor(255, 64, 64)
		gine.env.surface.DrawRect(8, 8, 32, 24)
	end)

	pump_draws(3)
	event.RemoveListener("Draw2D", id)
	attest.truthy(frames >= 2)
end)

T.Test("gmod basic vgui panel runtime smoke", function()
	ensure_ginit()
	local panel = gine.env.vgui.Create("DPanel")
	local painted = 0
	panel:SetPos(16, 16)
	panel:SetSize(64, 48)
	panel:SetVisible(true)
	panel:SetPaintBackgroundEnabled(true)
	panel:SetBGColor(32, 160, 224)

	function panel:Paint(w, h)
		painted = painted + 1
		gine.env.surface.SetDrawColor(32, 160, 224)
		gine.env.surface.DrawRect(0, 0, w, h)
	end

	pump_draws(3)
	local tex = render.GetScreenTexture()

	if panel and panel.IsValid and panel:IsValid() then panel:Remove() end

	attest.truthy(painted >= 2)
	assert_pixel_close(tex, 32, 32, {32 / 255, 160 / 255, 224 / 255, 1}, 0.2, "panel interior")
end)

T.Test("gmod notification panel geometry smoke", function()
	ensure_ginit()
	attest.truthy(gine.env.notification)
	attest.truthy(gine.env.notification.AddLegacy)
	gine.env.notification.AddLegacy("hello notice", gine.env.NOTIFY_HINT, 5)
	pump_draws(3)
	local found_height = 0

	for _, panel in ipairs(find_panels_by_class("NoticePanel")) do
		found_height = math.max(found_height, panel:GetTall())

		if panel.Remove then panel:Remove() end
	end

	attest.truthy(found_height > 10)
end)

T.Test("gmod dimage lua method dispatch smoke", function()
	ensure_ginit()
	local image = gine.env.vgui.Create("DImage")
	local dimage = gine.env.vgui.GetControlTable("DImage")
	local panel = gine.EnsureMetaTable("Panel")
	attest.truthy(image)
	attest.truthy(dimage)
	attest.truthy(dimage.PaintAt)
	attest.truthy(dimage.SizeToContents)
	attest.equal(image.PaintAt, dimage.PaintAt)
	attest.equal(image.SizeToContents, dimage.SizeToContents)
	attest.not_equal(image.PaintAt, panel.PaintAt)
	attest.not_equal(image.SizeToContents, panel.SizeToContents)

	if image.Remove then image:Remove() end
end)

T.Test("gmod notice material resolves mounted texture", function()
	ensure_ginit()
	local material = gine.env.Material("vgui/notices/hint")
	local texture = material:GetTexture("$basetexture")
	local name = texture:GetName()
	attest.truthy(material)
	attest.falsy(material:IsError())
	attest.truthy(texture)
	attest.not_equal(name, "textures/error.png")
	attest.truthy(texture:Width() > 1)
	attest.truthy(texture:Height() > 1)
end)

T.Test("gmod direct png material path does not gain vtf suffix", function()
	ensure_ginit()
	local material = gine.env.Material("gui/ContentIcon-hovered.png")
	local texture = material:GetTexture("$basetexture")
	local name = texture:GetName()
	attest.truthy(material)
	attest.truthy(texture)
	attest.truthy(type(name) == "string")
	attest.falsy(name:find("%.png%.vtf$") ~= nil)
	attest.falsy(material:IsError())
	attest.falsy(texture:IsError())
	attest.truthy(texture:Width() > 1)
	attest.truthy(texture:Height() > 1)
end)

T.Test("gmod extensionless image material path does not fallback to texture", function()
	ensure_ginit()
	local material = gine.env.Material("gui/ContentIcon-hovered")
	local texture = material:GetTexture("$basetexture")
	attest.truthy(material)
	attest.truthy(texture)
	attest.truthy(material:IsError())
	attest.truthy(texture:IsError())
end)

T.Test("gmod mislabeled png material can decode by content", function()
	ensure_ginit()
	local material = gine.env.Material("games/16/ageofchivalry.png")
	local texture = material:GetTexture("$basetexture")
	attest.truthy(material)
	attest.truthy(texture)
	attest.falsy(material:IsError())
	attest.falsy(texture:IsError())
	attest.truthy(texture:Width() > 1)
	attest.truthy(texture:Height() > 1)
end)

T.Test("gmod mislabeled gif material can decode by content", function()
	ensure_ginit()
	local material = gine.env.Material("games/16/dystopia.png")
	local texture = material:GetTexture("$basetexture")
	attest.truthy(material)
	attest.truthy(texture)
	attest.falsy(material:IsError())
	attest.falsy(texture:IsError())
	attest.truthy(texture:Width() > 1)
	attest.truthy(texture:Height() > 1)
end)

T.Test("gmod material resolves extensionless mounted texture path", function()
	ensure_ginit()
	local material = gine.env.Material("vgui/notices/hint")
	local texture = material:GetTexture("$basetexture")
	local name = texture:GetName()
	attest.truthy(material)
	attest.truthy(texture)
	attest.truthy(type(name) == "string")
	attest.truthy(name:lower():find("hint%.vtf", nil) ~= nil)
end)

T.Test("gmod vgui children are free-positioned by default", function()
	ensure_ginit()
	local parent = gine.env.vgui.Create("DPanel")
	local child_a = gine.env.vgui.Create("DPanel", parent)
	local child_b = gine.env.vgui.Create("DPanel", parent)
	parent:SetPos(10, 10)
	parent:SetSize(320, 200)
	child_a:SetPos(40, 40)
	child_a:SetSize(100, 60)
	child_b:SetPos(12, 90)
	child_b:SetSize(80, 25)
	pump_draws(3)
	local ax, ay = child_a:GetPos()
	local aw, ah = child_a:GetSize()
	local bx, by = child_b:GetPos()
	local bw, bh = child_b:GetSize()
	attest.equal(ax, 40)
	attest.equal(ay, 40)
	attest.equal(aw, 100)
	attest.equal(ah, 60)
	attest.equal(bx, 12)
	attest.equal(by, 90)
	attest.equal(bw, 80)
	attest.equal(bh, 25)

	if child_b.Remove then child_b:Remove() end

	if child_a.Remove then child_a:Remove() end

	if parent.Remove then parent:Remove() end
end)

T.Test("gmod dock layout responds to size setters", function()
	ensure_ginit()
	local frame = gine.env.vgui.Create("DFrame")
	local top = gine.env.vgui.Create("DPanel", frame)
	local left = gine.env.vgui.Create("DPanel", frame)
	local fill = gine.env.vgui.Create("DPanel", frame)
	frame:SetSize(320, 220)
	top:Dock(gine.env.TOP)
	top:SetTall(48)
	left:Dock(gine.env.LEFT)
	left:SetWide(64)
	fill:Dock(gine.env.FILL)
	pump_draws(3)
	local top_tall = top:GetTall()
	local left_wide = left:GetWide()
	local fill_wide = fill:GetWide()
	local fill_tall = fill:GetTall()
	local top_x, top_y = top:GetPos()
	local left_x, left_y = left:GetPos()
	local fill_x, fill_y = fill:GetPos()

	local function layout_dump()
		return (
			"top=%s@(%s,%s) left=%s@(%s,%s) fill=%sx%s@(%s,%s) frame=%sx%s"
		):format(
			tostring(top_tall),
			tostring(top_x),
			tostring(top_y),
			tostring(left_wide),
			tostring(left_x),
			tostring(left_y),
			tostring(fill_wide),
			tostring(fill_tall),
			tostring(fill_x),
			tostring(fill_y),
			tostring(frame:GetWide()),
			tostring(frame:GetTall())
		)
	end

	if top_tall < 40 then error(layout_dump(), 0) end

	if left_wide < 60 then error(layout_dump(), 0) end

	if fill_wide < 180 then error(layout_dump(), 0) end

	if fill_tall < 120 then error(layout_dump(), 0) end

	if fill.Remove then fill:Remove() end

	if left.Remove then left:Remove() end

	if top.Remove then top:Remove() end

	if frame.Remove then frame:Remove() end
end)

T.Test("gmod nested dock layout inside fill panel", function()
	ensure_ginit()
	local frame = gine.env.vgui.Create("DFrame")
	local fill = gine.env.vgui.Create("DPanel", frame)
	local nested_top = gine.env.vgui.Create("DPanel", fill)
	local nested_bottom = gine.env.vgui.Create("DPanel", fill)
	local nested_left = gine.env.vgui.Create("DPanel", fill)
	local nested_right = gine.env.vgui.Create("DPanel", fill)
	local nested_fill = gine.env.vgui.Create("DPanel", fill)
	frame:SetSize(320, 220)
	fill:Dock(gine.env.FILL)
	nested_top:Dock(gine.env.TOP)
	nested_top:SetTall(32)
	nested_bottom:Dock(gine.env.BOTTOM)
	nested_bottom:SetTall(32)
	nested_left:Dock(gine.env.LEFT)
	nested_left:SetWide(48)
	nested_right:Dock(gine.env.RIGHT)
	nested_right:SetWide(48)
	nested_fill:Dock(gine.env.FILL)
	pump_draws(3)
	local top_h = nested_top:GetTall()
	local bottom_h = nested_bottom:GetTall()
	local left_w = nested_left:GetWide()
	local right_w = nested_right:GetWide()
	local fill_w = nested_fill:GetWide()
	local fill_h = nested_fill:GetTall()
	local top_x, top_y = nested_top:GetPos()
	local left_x, left_y = nested_left:GetPos()
	local fill_x, fill_y = nested_fill:GetPos()

	local function dump()
		return (
			"top=%sx%s@(%s,%s) bottom=%s left=%s@(%s,%s) right=%s fill=%sx%s@(%s,%s)"
		):format(
			tostring(nested_top:GetWide()),
			tostring(top_h),
			tostring(top_x),
			tostring(top_y),
			tostring(bottom_h),
			tostring(left_w),
			tostring(left_x),
			tostring(left_y),
			tostring(right_w),
			tostring(fill_w),
			tostring(fill_h),
			tostring(fill_x),
			tostring(fill_y)
		)
	end

	if top_h < 28 then error(dump(), 0) end

	if bottom_h < 28 then error(dump(), 0) end

	if left_w < 44 then error(dump(), 0) end

	if right_w < 44 then error(dump(), 0) end

	if fill_w < 140 then error(dump(), 0) end

	if fill_h < 100 then error(dump(), 0) end

	if nested_fill.Remove then nested_fill:Remove() end

	if nested_right.Remove then nested_right:Remove() end

	if nested_left.Remove then nested_left:Remove() end

	if nested_bottom.Remove then nested_bottom:Remove() end

	if nested_top.Remove then nested_top:Remove() end

	if fill.Remove then fill:Remove() end

	if frame.Remove then frame:Remove() end
end)

T.Test("gmod dock layout defers fill until after right docks", function()
	ensure_ginit()
	local frame = gine.env.vgui.Create("DFrame")
	local fill = gine.env.vgui.Create("DPanel", frame)
	local right_a = gine.env.vgui.Create("DPanel", frame)
	local right_b = gine.env.vgui.Create("DPanel", frame)
	frame:SetSize(320, 220)
	fill:Dock(gine.env.FILL)
	right_a:Dock(gine.env.RIGHT)
	right_a:SetWide(26)
	right_b:Dock(gine.env.RIGHT)
	right_b:SetWide(26)
	pump_draws(3)
	local fill_w, fill_h = fill:GetSize()
	local right_a_w, right_a_h = right_a:GetSize()
	local right_b_w, right_b_h = right_b:GetSize()
	local fill_x, fill_y = fill:GetPos()
	local right_a_x, right_a_y = right_a:GetPos()
	local right_b_x, right_b_y = right_b:GetPos()

	local function dump()
		return (
			"fill=%sx%s@(%s,%s) right_a=%sx%s@(%s,%s) right_b=%sx%s@(%s,%s) frame=%sx%s"
		):format(
			tostring(fill_w),
			tostring(fill_h),
			tostring(fill_x),
			tostring(fill_y),
			tostring(right_a_w),
			tostring(right_a_h),
			tostring(right_a_x),
			tostring(right_a_y),
			tostring(right_b_w),
			tostring(right_b_h),
			tostring(right_b_x),
			tostring(right_b_y),
			tostring(frame:GetWide()),
			tostring(frame:GetTall())
		)
	end

	if fill_w < 260 then error(dump(), 0) end

	if fill_h < 200 then error(dump(), 0) end

	if right_a_w < 24 or right_a_h < 200 then error(dump(), 0) end

	if right_b_w < 24 or right_b_h < 200 then error(dump(), 0) end

	if right_b_x < fill_x + fill_w then error(dump(), 0) end

	if right_a.Remove then right_a:Remove() end

	if right_b.Remove then right_b:Remove() end

	if fill.Remove then fill:Remove() end

	if frame.Remove then frame:Remove() end
end)
