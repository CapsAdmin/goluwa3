local T = import("test/environment.lua")
local attest = import("goluwa/helpers/attest.lua")
local commands = import("goluwa/commands.lua")
local gine = import("goluwa/gmod/gine.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local resource = import("goluwa/resource.lua")
local test_render = import("test/test_render.lua")

local function ensure_ginit()
	if gine.env and gine.env.gamemode and gine.env.vgui then return end

	local ok, err = commands.ExecuteCommandString("ginit")

	if not ok then error(err, 0) end
end

local function pump_draws(frame_count)
	for _ = 1, frame_count do
		render.Draw(0.016)
	end
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
				("%s pixel mismatch at (%d, %d): expected %.3f %.3f %.3f %.3f, got %.3f %.3f %.3f %.3f")
					:format(
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

T.Test2D("gmod ginit bootstrap smoke", function()
	ensure_ginit()

	attest.truthy(gine.env)
	attest.truthy(gine.env.include)
	attest.truthy(gine.env.gamemode)
	attest.truthy(gine.env.gamemode.Register)
	attest.truthy(gine.env.gamemode.Call)
end)

T.Test("gmod derma_controls Draw2D smoke", function()
	test_render.Init2D()
	ensure_ginit()

	local ok, err

	ok, err = commands.ExecuteCommandString("derma_controls")

	if not ok then error(err, 0) end

	attest.truthy(gine.gui_world)
	attest.truthy(gine.gui_world:IsValid())
	pump_draws(3)
end)

T.Test("gmod scoreboard Draw2D smoke", function()
	test_render.Init2D()
	ensure_ginit()

	gine.env.gamemode.Call("ScoreboardShow")

	attest.truthy(gine.env.GetHostName)
	attest.truthy(gine.gui_world)
	attest.truthy(gine.gui_world:IsValid())
	pump_draws(3)
	gine.env.gamemode.Call("ScoreboardHide")
end)

T.Test("gmod surface DrawRect runtime smoke", function()
	test_render.Init2D()
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
	test_render.Init2D()
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
	assert_pixel_close(tex, 4, 4, {0, 0, 0, 1}, 0.1, "background")
end)

T.Test("gmod notification panel geometry smoke", function()
	test_render.Init2D()
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
	local panel = gine.GetMetaTable("Panel")

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
	test_render.Init2D()
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
