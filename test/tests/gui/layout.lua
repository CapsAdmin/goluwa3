local T = require("test.environment")
local gui = require("gui.gui")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local W = 512
local H = 512

local function TestGUI(name, func)
	return T.Test2D(name, function()
		gui.Initialize() -- resets the gui.Root
		local ret = func()
		gui.Root:Draw() -- draw once to the render target
		return ret
	end)
end

local i = 0

local function CreatePanel(parent)
	local p = gui.Create("base", parent)
	p:SetColor(Color.FromHSV(i, 1, 1):SetAlpha(1))
	i = i + 0.1

	if i > 1 then i = 0 end

	return p
end

TestGUI("Center and Fill", function()
	local p = gui.Root
	local c = CreatePanel()
	c:SetSize(Vec2(100, 100))
	c:SetLayout({
		"Center",
	})
	local l = CreatePanel()
	l:SetSize(Vec2(50, 50))
	l:SetLayout({
		"FillX",
		"CenterY",
	})
	return function()
		-- Center test
		local cx, cy = c.WorldMatrix:GetTranslation()
		T((W - 100) / 2)["=="](cx)
		T((H - 100) / 2)["=="](cy)
		-- FillX should fill the width, but it might be blocked by 'c' if they collide
		-- c is centered, so it's at x=206, w=100.
		-- FillX on 'l' should either fill everything if no collision, OR be blocked.
		-- By default, layout commands collide with each other if they are in the same parent.
		-- Let's check FillX/FillY more carefully with multiple elements.
		T.Screenshot("center_and_fill")
	end
end)

TestGUI("Relative Movement", function()
	local p = gui.Root
	local a = CreatePanel()
	a:SetSize(Vec2(50, 50))
	a:SetPosition(Vec2(100, 100))
	local b = CreatePanel()
	b:SetSize(Vec2(50, 50))
	b:SetLayout({
		a,
		"MoveRightOf",
	})
	local c = CreatePanel()
	c:SetSize(Vec2(50, 50))
	c:SetLayout({
		a,
		"MoveDownOf",
	})
	local d = CreatePanel()
	d:SetSize(Vec2(50, 50))
	d:SetLayout({
		a,
		"MoveLeftOf",
	})
	local e = CreatePanel()
	e:SetSize(Vec2(50, 50))
	e:SetLayout({
		a,
		"MoveUpOf",
	})
	return function()
		local function get_pos(node)
			local x, y = node.WorldMatrix:GetTranslation()
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
		T.Screenshot("relative_movement")
	end
end)

TestGUI("Movement and Obstacles", function()
	local p = gui.Root
	-- Place an obstacle in the middle
	local obs = CreatePanel()
	obs:SetSize(Vec2(100, 100))
	obs:SetPosition(Vec2(200, 200))
	-- MoveRight from left edge should hit obstacle
	local r = CreatePanel()
	r:SetSize(Vec2(50, 50))
	r:SetPosition(Vec2(10, 225)) -- overlapping with obstacle in Y
	r:SetLayout({
		"MoveRight",
	})
	-- MoveLeft from right edge should hit obstacle
	local l = CreatePanel()
	l:SetSize(Vec2(50, 50))
	l:SetPosition(Vec2(W - 50, 225)) -- same Y
	l:SetLayout({
		"MoveLeft",
	})
	return function()
		local rx, ry = r.WorldMatrix:GetTranslation()
		-- MoveRight starts at -9999... and casts right.
		-- Obstacle is at x=200, w=100. So it spans [200, 300].
		-- MoveRight should hit obs at x=200 and place 'r' at 200 - 50 = 150.
		T(150)["=="](rx)
		local lx, ly = l.WorldMatrix:GetTranslation()
		-- MoveLeft starts at 9999... and casts left.
		-- It should hit obs at x=300 and place 'l' at 300.
		T(300)["=="](lx)
		T.Screenshot("obstacles")
	end
end)

TestGUI("Gmod Layout Commands", function()
	local p = gui.Root
	-- GmodTop: MoveUp, FillX, NoCollide("up")
	local top = CreatePanel()
	top:SetSize(Vec2(100, 50))
	top:SetLayout({"GmodTop"})
	-- GmodBottom: MoveDown, FillX, NoCollide("down")
	local bottom = CreatePanel()
	bottom:SetSize(Vec2(100, 50))
	bottom:SetLayout({"GmodBottom"})
	-- GmodLeft: MoveLeft, FillY, NoCollide("left")
	local left = CreatePanel()
	left:SetSize(Vec2(50, 100))
	left:SetLayout({"GmodLeft"})
	return function()
		local tx, ty = top.WorldMatrix:GetTranslation()
		local tw, th = top:GetSize():Unpack()
		T(0)["=="](tx)
		T(0)["=="](ty)
		T(W)["=="](tw)
		local bx, by = bottom.WorldMatrix:GetTranslation()
		local bw, bh = bottom:GetSize():Unpack()
		T(0)["=="](bx)
		T(H - 50)["=="](by)
		T(W)["=="](bw)
		local lx, ly = left.WorldMatrix:GetTranslation()
		local lw, lh = left:GetSize():Unpack()
		-- Left should be below top and above bottom because they collide!
		-- Top is at y=0, h=50. Bottom is at y=462, h=50.
		-- Left should be between them.
		T(0)["=="](lx)
		T(50)["=="](ly)
		T(H - 100)["=="](lh) -- 512 - 50 (top) - 50 (bottom) = 412.
		-- Wait, H=512. 512 - 50 - 50 = 412.
		T(412)["=="](lh)
		T.Screenshot("gmod_layout")
	end
end)

TestGUI("Margins and Padding", function()
	local p = gui.Root
	p:SetPadding(Rect(10, 10, 10, 10))
	local a = CreatePanel()
	a:SetSize(Vec2(50, 50))
	a:SetMargin(Rect(5, 0, 100, 0)) -- LEFT margin 5
	a:SetLayout({
		"MoveRight",
	})
	local b = CreatePanel()
	b:SetSize(Vec2(50, 50))
	b:SetMargin(Rect(0, 0, 10, 0)) -- RIGHT margin 10
	b:SetLayout({
		a,
		"MoveLeftOf",
	})
	return function()
		local ax, ay = a.WorldMatrix:GetTranslation()
		T(352)["=="](ax)
		local bx, by = b.WorldMatrix:GetTranslation()
		-- bx = ax - b.w - a.Margin.Left - b.Margin.Right = 352 - 50 - 5 - 10 = 287.
		T(287)["=="](bx)
		T.Screenshot("margins_padding")
	end
end)

TestGUI("Fill with Obstacles", function()
	local p = gui.Root
	-- Obstacle in the middle
	local obs = CreatePanel()
	obs:SetSize(Vec2(100, H))
	obs:SetPosition(Vec2(200, 0))
	-- Fill in the left part
	local f = CreatePanel()
	f:SetSize(Vec2(10, 10))
	f:SetPosition(Vec2(50, 100))
	f:SetLayout({
		"FillX",
	})
	return function()
		local fx, fy = f.WorldMatrix:GetTranslation()
		local fw, fh = f:GetSize():Unpack()
		-- Left of obstacle is at 200. Space from 0 to 200 is 200.
		T(0)["=="](fx)
		T(200)["=="](fw)
		T.Screenshot("fill_obstacles")
	end
end)

TestGUI("Center with Obstacles", function()
	local p = gui.Root
	-- Obstacle in the middle
	local obs = CreatePanel()
	obs:SetSize(Vec2(100, H))
	obs:SetPosition(Vec2(300, 0)) -- Gap of 300
	-- Center in the left part
	local f = CreatePanel()
	f:SetSize(Vec2(100, 50))
	f:SetLayout({
		"CenterX",
	})
	return function()
		local fx, fy = f.WorldMatrix:GetTranslation()
		-- Gap [0, 300]. Center is 150. Panel size 100.
		-- X should be 150 - 50 = 100.
		T(100)["=="](fx)
		T.Screenshot("center_obstacles")
	end
end)
