local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

local function create_world()
	local old_world = Panel.World
	local world = Panel.New{
		ComponentSet = { "transform", "visual" },
	}
	world:SetName("TestWorld")
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

local function green_cov(x, y)
	local r, g, b, a = T.GetScreenPixel(x, y)
	return g or 0
end

T.Test2D("clipped button rect is pixel aligned from fractional size/position", function(width, height)
	local old_world, world = create_world()
	local btn = Panel.New{
		Parent = world,
		transform = true,
		visual = true,
	}
	-- fractional requests that the transform must snap to whole pixels
	btn.transform:SetPosition(Vec2(100.3, 50.7))
	btn.transform:SetSize(Vec2(100.4, 80.6))
	btn.visual:SetClipping(true)

	function btn:OnDraw()
		local w, h = btn.transform.Size.x, btn.transform.Size.y
		render2d.SetColor(1, 0, 0, 1)
		render2d.DrawRect(0, 0, w, h)
		render2d.SetColor(0, 1, 0, 1)
		render2d.DrawRect(0, 0, w, 1)
		render2d.DrawRect(0, h - 1, w, 1)
		render2d.DrawRect(0, 0, 1, h)
		render2d.DrawRect(w - 1, 0, 1, h)
	end

	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(0, 0, width, height)
	world.visual:DrawRecursive()

	return function()
		local ok, err = xpcall(
			function()
				local px, py = btn.transform:GetPosition().x, btn.transform:GetPosition().y
				local sx, sy = btn.transform:GetSize().x, btn.transform:GetSize().y
				T(px % 1 == 0)["=="](true)
				T(py % 1 == 0)["=="](true)
				T(sx % 1 == 0)["=="](true)
				T(sy % 1 == 0)["=="](true)

				local function peak(vx, vy, vert)
					local mx = 0
					for i = -1, 1 do
						local x, y = vx, vy
						if vert then y = vy + i else x = vx + i end
						local c = green_cov(x, y)
						if c > mx then mx = c end
					end
					return math.round(mx * 100)
				end

				local cx, cy = px + math.floor(sx / 2), py + math.floor(sy / 2)
				local l = peak(px, cy, true)
				local r = peak(px + sx - 1, cy, true)
				local t = peak(cx, py, false)
				local b = peak(cx, py + sy - 1, false)
				print(string.format("button edges L=%d R=%d T=%d B=%d (rect %d,%d %dx%d)", l, r, t, b, px, py, sx, sy))
				T(math.abs(l - r))["<="](5)
				T(math.abs(l - t))["<="](5)
				T(math.abs(l - b))["<="](5)
				T(l) [">="](95)
			end,
			debug.traceback
		)
		if world and world.IsValid and world:IsValid() then world:Remove() end
		Panel.World = old_world
		if not ok then error(err, 0) end
	end
end)
