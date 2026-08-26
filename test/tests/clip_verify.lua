local render2d = import("goluwa/render2d/render2d.lua")
local T = import("test/environment.lua")

-- Axis-aligned PushClipRect uses the scissor fast path. A scissor is a whole-pixel
-- region, so a fractional clip rect must include every pixel with any overlap:
--   x in [floor(min_x), ceil(max_x)),  y in [floor(min_y), ceil(max_y))
local function blue(x, y)
	local r, g, b, a = T.GetScreenPixel(x, y)
	return b > 0.5 and r < 0.3
end

local function check(label, cx, cy, cw, ch)
	T.Test2D("pushclip scissor " .. label, function()
		render2d.SetColor(1, 0, 0, 1)
		render2d.DrawRect(0, 0, 512, 512)
		render2d.PushClipRect(cx, cy, cw, ch)
		render2d.SetColor(0, 0.4, 1, 1)
		render2d.DrawRect(0, 0, 512, 512)
		render2d.PopClip()
		return function()
			local midy = math.floor(cy + ch / 2)
			local midx = math.floor(cx + cw / 2)
			local L, R = math.floor(cx), math.ceil(cx + cw)
			local Tp, B = math.floor(cy), math.ceil(cy + ch)

			-- outside the region on both sides of each axis
			T(blue(L - 1, midy))["=="](false)
			T(blue(R, midy))["=="](false)
			T(blue(midx, Tp - 1))["=="](false)
			T(blue(midx, B))["=="](false)

			-- the overlapping boundary pixels are included
			T(blue(L, midy))["=="](true)
			T(blue(R - 1, midy))["=="](true)
			T(blue(midx, Tp))["=="](true)
			T(blue(midx, B - 1))["=="](true)
		end
	end)
end

check("integer rect", 100, 50, 200, 100)
check("fractional min and size", 100.5, 50.5, 200.5, 100.5)
check("integer min, fractional size", 100, 50, 200.5, 100.5)
check("fractional min, integer size", 100.5, 50.5, 200, 100)
check("tiny fractional offset", 100.001, 50.001, 200, 100)
check("frac(max) <= frac(min)", 100.8, 50.8, 200.1, 100.1)
