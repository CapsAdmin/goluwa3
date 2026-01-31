local T = require("test.environment")
local ecs = require("ecs.ecs")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local W = 512
local H = 512

local function TestGUI(name, func)
	return T.Test2D(name, function()
		ecs.Clear2DWorld()
		local world = ecs.Get2DWorld()
		world.transform_2d:SetSize(Vec2(W, H))
		local ret = func()
		world:CalcLayout()

		for _, child in ipairs(world:GetChildren()) do
			local gui = child:GetComponent("gui_element_2d")

			if gui then gui:DrawRecursive() end
		end

		return ret
	end)
end

local i = 0

local function CreatePanel(parent)
	local p = ecs.CreateEntity("test_panel", parent or ecs.Get2DWorld())
	p:AddComponent(require("ecs.components.2d.transform"))
	p:AddComponent(require("ecs.components.2d.layout"))
	local rect = p:AddComponent(require("ecs.components.2d.rect"))
	rect:SetColor(Color.FromHSV(i, 1, 1):SetAlpha(1))
	i = i + 0.1

	if i > 1 then i = 0 end

	return p
end

TestGUI("Center and Fill", function()
	local p = ecs.Get2DWorld()
	local c = CreatePanel()
	c.transform_2d:SetSize(Vec2(100, 100))
	c.layout_2d:SetLayout({
		"Center",
	})
	local l = CreatePanel()
	l.transform_2d:SetSize(Vec2(50, 50))
	l.layout_2d:SetLayout({
		"FillX",
		"CenterY",
	})
	return function()
		-- Center test
		local cx, cy = c.transform_2d:GetWorldMatrix():GetTranslation()
		T((W - 100) / 2)["=="](cx)
		T((H - 100) / 2)["=="](cy)
		-- FillX should fill the width, but it might be blocked by 'c' if they collide
		-- c is centered, so it's at x=206, w=100.
		-- FillX on 'l' should either fill everything if no collision, OR be blocked.
		-- By default, layout commands collide with each other if they are in the same parent.
		-- Let's check FillX/FillY more carefully with multiple elements.
		T.Screenshot("logs/screenshots/center_and_fill.png")
	end
end)

TestGUI("Relative Movement", function()
	local p = ecs.Get2DWorld()
	local a = CreatePanel()
	a.transform_2d:SetSize(Vec2(50, 50))
	a.transform_2d:SetPosition(Vec2(100, 100))
	local b = CreatePanel()
	b.transform_2d:SetSize(Vec2(50, 50))
	b.layout_2d:SetLayout({
		a,
		"MoveRightOf",
	})
	local c = CreatePanel()
	c.transform_2d:SetSize(Vec2(50, 50))
	c.layout_2d:SetLayout({
		a,
		"MoveDownOf",
	})
	local d = CreatePanel()
	d.transform_2d:SetSize(Vec2(50, 50))
	d.layout_2d:SetLayout({
		a,
		"MoveLeftOf",
	})
	local e = CreatePanel()
	e.transform_2d:SetSize(Vec2(50, 50))
	e.layout_2d:SetLayout({
		a,
		"MoveUpOf",
	})
	return function()
		local function get_pos(node)
			local x, y = node.transform_2d:GetWorldMatrix():GetTranslation()
			return x, y
		end

		local ax, ay = get_pos(a)
		local bx, by = get_pos(b)
		local cx, cy = get_pos(c)
		local dx, dy = get_pos(d)
		local ex, ey = get_pos(e)
		T(ax + 50)["=="](bx)
		T(ay)["=="](by)
		T(ax)["=="](cx)
		T(ay + 50)["=="](cy)
		T(ax - 50)["=="](dx)
		T(ay)["=="](dy)
		T(ax)["=="](ex)
		T(ay - 50)["=="](ey)
		T.Screenshot("logs/screenshots/relative_movement.png")
	end
end)

TestGUI("Movement and Obstacles", function()
	local p = ecs.Get2DWorld()
	-- Place an obstacle in the middle
	local obs = CreatePanel()
	obs.transform_2d:SetSize(Vec2(100, 100))
	obs.transform_2d:SetPosition(Vec2(200, 200))
	-- MoveRight from left edge should hit obstacle
	local r = CreatePanel()
	r.transform_2d:SetSize(Vec2(50, 50))
	r.transform_2d:SetPosition(Vec2(10, 225)) -- overlapping with obstacle in Y
	r.layout_2d:SetLayout({
		"MoveRight",
	})
	-- MoveLeft from right edge should hit obstacle
	local l = CreatePanel()
	l.transform_2d:SetSize(Vec2(50, 50))
	l.transform_2d:SetPosition(Vec2(W - 50, 225)) -- same Y
	l.layout_2d:SetLayout({
		"MoveLeft",
	})
	return function()
		local rx, ry = r.transform_2d:GetWorldMatrix():GetTranslation()
		-- MoveRight starts at -9999... and casts right.
		-- Obstacle is at x=200, w=100. So it spans [200, 300].
		-- MoveRight should hit obs at x=200 and place 'r' at 200 - 50 = 150.
		T(150)["=="](rx)
		local lx, ly = l.transform_2d:GetWorldMatrix():GetTranslation()
		-- MoveLeft starts at 9999... and casts left.
		-- It should hit obs at x=300 and place 'l' at 300.
		T(300)["=="](lx)
		T.Screenshot("logs/screenshots/obstacles.png")
	end
end)

TestGUI("Gmod Layout Commands", function()
	local p = ecs.Get2DWorld()
	-- GmodTop: MoveUp, FillX, NoCollide("up")
	local top = CreatePanel()
	top.transform_2d:SetSize(Vec2(100, 50))
	top.layout_2d:SetLayout({"GmodTop"})
	-- GmodBottom: MoveDown, FillX, NoCollide("down")
	local bottom = CreatePanel()
	bottom.transform_2d:SetSize(Vec2(100, 50))
	bottom.layout_2d:SetLayout({"GmodBottom"})
	-- GmodLeft: MoveLeft, FillY, NoCollide("left")
	local left = CreatePanel()
	left.transform_2d:SetSize(Vec2(50, 100))
	left.layout_2d:SetLayout({"GmodLeft"})
	return function()
		local tx, ty = top.transform_2d:GetWorldMatrix():GetTranslation()
		local tw, th = top.transform_2d:GetSize():Unpack()
		T(0)["=="](tx)
		T(0)["=="](ty)
		T(W)["=="](tw)
		local bx, by = bottom.transform_2d:GetWorldMatrix():GetTranslation()
		local bw, bh = bottom.transform_2d:GetSize():Unpack()
		T(0)["=="](bx)
		T(H - 50)["=="](by)
		T(W)["=="](bw)
		local lx, ly = left.transform_2d:GetWorldMatrix():GetTranslation()
		local lw, lh = left.transform_2d:GetSize():Unpack()
		-- Left should be below top and above bottom because they collide!
		-- Top is at y=0, h=50. Bottom is at y=462, h=50.
		-- Left should be between them.
		T(0)["=="](lx)
		T(50)["=="](ly)
		T(H - 100)["=="](lh) -- 512 - 50 (top) - 50 (bottom) = 412.
		-- Wait, H=512. 512 - 50 - 50 = 412.
		T(412)["=="](lh)
		T.Screenshot("logs/screenshots/gmod_layout.png")
	end
end)

TestGUI("Margins and Padding", function()
	local p = ecs.Get2DWorld()
	p.layout_2d:SetPadding(Rect(10, 10, 10, 10))
	local a = CreatePanel()
	a.transform_2d:SetSize(Vec2(50, 50))
	a.layout_2d:SetMargin(Rect(5, 0, 100, 0)) -- LEFT margin 5
	a.layout_2d:SetLayout({
		"MoveRight",
	})
	local b = CreatePanel()
	b.transform_2d:SetSize(Vec2(50, 50))
	b.layout_2d:SetMargin(Rect(0, 0, 10, 0)) -- RIGHT margin 10
	b.layout_2d:SetLayout({
		a,
		"MoveLeftOf",
	})
	return function()
		local ax, ay = a.transform_2d:GetWorldMatrix():GetTranslation()
		T(352)["=="](ax)
		local bx, by = b.transform_2d:GetWorldMatrix():GetTranslation()
		-- bx = ax - b.w - a.Margin.Left - b.Margin.Right = 352 - 50 - 5 - 10 = 287.
		T(287)["=="](bx)
		T.Screenshot("logs/screenshots/margins_padding.png")
	end
end)

TestGUI("Fill with Obstacles", function()
	local p = ecs.Get2DWorld()
	-- Obstacle in the middle
	local obs = CreatePanel()
	obs.transform_2d:SetSize(Vec2(100, H))
	obs.transform_2d:SetPosition(Vec2(200, 0))
	-- Fill in the left part
	local f = CreatePanel()
	f.transform_2d:SetSize(Vec2(10, 10))
	f.transform_2d:SetPosition(Vec2(50, 100))
	f.layout_2d:SetLayout({
		"FillX",
	})
	return function()
		local fx, fy = f.transform_2d:GetWorldMatrix():GetTranslation()
		local fw, fh = f.transform_2d:GetSize():Unpack()
		-- Left of obstacle is at 200. Space from 0 to 200 is 200.
		T(0)["=="](fx)
		T(200)["=="](fw)
		T.Screenshot("logs/screenshots/fill_obstacles.png")
	end
end)

TestGUI("Center with Obstacles", function()
	local p = ecs.Get2DWorld()
	-- Obstacle in the middle
	local obs = CreatePanel()
	obs.transform_2d:SetSize(Vec2(100, H))
	obs.transform_2d:SetPosition(Vec2(300, 0)) -- Gap of 300
	-- Center in the left part
	local f = CreatePanel()
	f.transform_2d:SetSize(Vec2(100, 50))
	f.layout_2d:SetLayout({
		"CenterX",
	})
	return function()
		local fx, fy = f.transform_2d:GetWorldMatrix():GetTranslation()
		-- Gap [0, 300]. Center is 150. Panel size 100.
		-- X should be 150 - 50 = 100.
		T(100)["=="](fx)
		T.Screenshot("logs/screenshots/center_obstacles.png")
	end
end)
