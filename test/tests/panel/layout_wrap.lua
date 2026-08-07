local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")

local function NewBox(name, size)
	local e = Panel.New()
	e:SetName(name)
	e:AddComponent("transform")
	e.transform:SetSize(size or Vec2(0, 0))
	return e
end

T.Test("layout wrap - basic wrapping", function()
	local parent = NewBox("Parent", Vec2(200, 300))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)

	for i = 1, 5 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- 200px width, 60px tiles => 3 per line (180px), 2 lines
	local line1_count = 0
	local line2_count = 0

	for _, child in ipairs(parent:GetChildren()) do
		local y = child.transform:GetY()

		if y == 0 then
			line1_count = line1_count + 1
		else
			line2_count = line2_count + 1
		end
	end

	T(line1_count)["=="](3)
	T(line2_count)["=="](2)
	-- Height should be 2 lines * 60px = 120px
	T(parent.transform:GetHeight())["=="](120)
	parent:Remove()
end)

T.Test("layout wrap - gaps accounted in line breaking", function()
	local parent = NewBox("Parent", Vec2(200, 300))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(10)

	for i = 1, 10 do
		local child = NewBox("Child" .. i, Vec2(50, 50))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- 200px width, 50px tiles, 10px gap
	-- Per line: n*50 + (n-1)*10 <= 200 => 60n - 10 <= 200 => n <= 3.5 => 3 per line
	local last_on_line1 = nil

	for _, child in ipairs(parent:GetChildren()) do
		if child.transform:GetY() == 0 then last_on_line1 = child end
	end

	-- Last tile on line 1 should not exceed 200px
	local right_edge = last_on_line1.transform:GetX() + last_on_line1.transform:GetWidth()
	T(right_edge)["<="](200)
	parent:Remove()
end)

T.Test("layout wrap - no overflow with large gaps", function()
	local parent = NewBox("Parent", Vec2(400, 600))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(30)

	for i = 1, 20 do
		local child = NewBox("Child" .. i, Vec2(80, 80))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()

	-- No child should extend beyond 400px
	for _, child in ipairs(parent:GetChildren()) do
		local right_edge = child.transform:GetX() + child.transform:GetWidth()
		T(right_edge)["<="](400)
	end

	parent:Remove()
end)

T.Test("layout wrap - space_between alignment no overflow", function()
	local parent = NewBox("Parent", Vec2(300, 300))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetAlignmentX("space_between")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(10)

	for i = 1, 8 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()

	-- No child should extend beyond 300px
	for _, child in ipairs(parent:GetChildren()) do
		local right_edge = child.transform:GetX() + child.transform:GetWidth()
		T(right_edge)["<="](300)
	end

	-- Last child on each line should be at or near the edge
	local last_on_line1 = nil

	for _, child in ipairs(parent:GetChildren()) do
		if child.transform:GetY() == 0 then last_on_line1 = child end
	end

	T(last_on_line1.transform:GetX() + last_on_line1.transform:GetWidth())["=="](300)
	parent:Remove()
end)

T.Test("layout wrap - space_around symmetric padding", function()
	local parent = NewBox("Parent", Vec2(300, 300))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetAlignmentX("space_around")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(10)

	for i = 1, 6 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- Check first line padding is symmetric
	local first_child = parent:GetChildren()[1]
	local last_child_line1 = nil

	for _, child in ipairs(parent:GetChildren()) do
		if child.transform:GetY() == 0 then last_child_line1 = child end
	end

	local left_pad = first_child.transform:GetX()
	local right_pad = 300 - (last_child_line1.transform:GetX() + last_child_line1.transform:GetWidth())
	-- Padding should be symmetric (within 1px tolerance for rounding)
	T(math.abs(left_pad - right_pad))["<"](1)
	parent:Remove()
end)

T.Test("layout wrap - space_evenly symmetric padding", function()
	local parent = NewBox("Parent", Vec2(300, 300))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetAlignmentX("space_evenly")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(10)

	for i = 1, 6 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- Check first line padding is symmetric
	local first_child = parent:GetChildren()[1]
	local last_child_line1 = nil

	for _, child in ipairs(parent:GetChildren()) do
		if child.transform:GetY() == 0 then last_child_line1 = child end
	end

	local left_pad = first_child.transform:GetX()
	local right_pad = 300 - (last_child_line1.transform:GetX() + last_child_line1.transform:GetWidth())
	-- Padding should be symmetric (within 1px tolerance for rounding)
	T(math.abs(left_pad - right_pad))["<"](1)
	parent:Remove()
end)

T.Test("layout wrap - space_evenly no overflow with large gap", function()
	local parent = NewBox("Parent", Vec2(400, 600))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetAlignmentX("space_evenly")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(20)

	for i = 1, 15 do
		local child = NewBox("Child" .. i, Vec2(70, 70))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()

	-- No child should extend beyond 400px
	for _, child in ipairs(parent:GetChildren()) do
		local right_edge = child.transform:GetX() + child.transform:GetWidth()
		T(right_edge)["<="](400)
	end

	parent:Remove()
end)

T.Test("layout wrap - space_around no overflow with large gap", function()
	local parent = NewBox("Parent", Vec2(400, 600))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetAlignmentX("space_around")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(20)

	for i = 1, 15 do
		local child = NewBox("Child" .. i, Vec2(70, 70))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()

	-- No child should extend beyond 400px
	for _, child in ipairs(parent:GetChildren()) do
		local right_edge = child.transform:GetX() + child.transform:GetWidth()
		T(right_edge)["<="](400)
	end

	parent:Remove()
end)

T.Test("layout wrap - fit height with multiple lines", function()
	local parent = NewBox("Parent", Vec2(200, 0))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(5, 5, 5, 5))
	parent.layout:SetChildGap(5)

	for i = 1, 8 do
		local child = NewBox("Child" .. i, Vec2(50, 50))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- 200px - 10px padding = 190px available
	-- 50*3 + 5*2 = 160px per line => 3 per line
	-- 8 children => 3 lines (3+3+2)
	-- Height = 3*50 + 2*5 gaps + 10 padding = 170px
	T(parent.transform:GetHeight())["=="](170)
	parent:Remove()
end)

T.Test("layout wrap - vertical direction", function()
	local parent = NewBox("Parent", Vec2(300, 200))
	parent:AddComponent("layout")
	parent.layout:SetDirection("y")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitWidth(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)

	for i = 1, 5 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- 200px height, 60px tiles => 3 per column, 2 columns
	local col1_count = 0
	local col2_count = 0

	for _, child in ipairs(parent:GetChildren()) do
		local x = child.transform:GetX()

		if x == 0 then col1_count = col1_count + 1 else col2_count = col2_count + 1 end
	end

	T(col1_count)["=="](3)
	T(col2_count)["=="](2)
	-- Width should be 2 columns * 60px = 120px
	T(parent.transform:GetWidth())["=="](120)
	parent:Remove()
end)

T.Test("layout wrap - dynamic resize reflows", function()
	local parent = NewBox("Parent", Vec2(300, 400))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)

	for i = 1, 6 do
		local child = NewBox("Child" .. i, Vec2(100, 100))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- 300px width, 100px tiles => 3 per line => 2 lines
	T(parent.transform:GetHeight())["=="](200)
	-- Resize to 200px => 2 per line => 3 lines
	parent.transform:SetWidth(200)
	parent.layout:UpdateLayout()
	T(parent.transform:GetHeight())["=="](300)
	-- Resize to 400px => 4 per line => 2 lines (4+2)
	parent.transform:SetWidth(400)
	parent.layout:UpdateLayout()
	T(parent.transform:GetHeight())["=="](200)
	parent:Remove()
end)

T.Test("layout wrap - single child does not wrap", function()
	local parent = NewBox("Parent", Vec2(300, 300))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)
	local child = NewBox("Child1", Vec2(100, 100))
	child:SetParent(parent)
	parent.layout:UpdateLayout()
	T(parent.transform:GetHeight())["=="](100)
	T(child.transform:GetX())["=="](0)
	T(child.transform:GetY())["=="](0)
	parent:Remove()
end)

T.Test("layout wrap - child larger than container does not overflow", function()
	local parent = NewBox("Parent", Vec2(100, 200))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)
	local child = NewBox("Child1", Vec2(150, 50))
	child:SetParent(parent)
	parent.layout:UpdateLayout()
	-- Child is wider than container, goes on its own line
	T(child.transform:GetX())["=="](0)
	T(child.transform:GetY())["=="](0)
	parent:Remove()
end)

T.Test("layout wrap - gap zero works correctly", function()
	local parent = NewBox("Parent", Vec2(300, 400))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetAlignmentX("space_evenly")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)

	for i = 1, 6 do
		local child = NewBox("Child" .. i, Vec2(80, 80))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	-- 300px / 80px = 3.75 => 3 per line
	-- With gap=0 and space_evenly, padding should be symmetric
	local first_child = parent:GetChildren()[1]
	local last_child_line1 = nil

	for _, child in ipairs(parent:GetChildren()) do
		if child.transform:GetY() == 0 then last_child_line1 = child end
	end

	local left_pad = first_child.transform:GetX()
	local right_pad = 300 - (last_child_line1.transform:GetX() + last_child_line1.transform:GetWidth())
	T(math.abs(left_pad - right_pad))["<"](1)
	parent:Remove()
end)

T.Test("layout wrap - non-wrap path space_around symmetric", function()
	-- Test the non-wrap single-line path as well
	local parent = NewBox("Parent", Vec2(400, 100))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(false)
	parent.layout:SetAlignmentX("space_around")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(10)

	for i = 1, 4 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	local first_child = parent:GetChildren()[1]
	local last_child = parent:GetChildren()[4]
	local left_pad = first_child.transform:GetX()
	local right_pad = 400 - (last_child.transform:GetX() + last_child.transform:GetWidth())
	T(math.abs(left_pad - right_pad))["<"](1)
	parent:Remove()
end)

T.Test("layout wrap - non-wrap path space_evenly symmetric", function()
	local parent = NewBox("Parent", Vec2(400, 100))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetWrapChildren(false)
	parent.layout:SetAlignmentX("space_evenly")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(10)

	for i = 1, 4 do
		local child = NewBox("Child" .. i, Vec2(60, 60))
		child:SetParent(parent)
	end

	parent.layout:UpdateLayout()
	local first_child = parent:GetChildren()[1]
	local last_child = parent:GetChildren()[4]
	local left_pad = first_child.transform:GetX()
	local right_pad = 400 - (last_child.transform:GetX() + last_child.transform:GetWidth())
	T(math.abs(left_pad - right_pad))["<"](1)
	parent:Remove()
end)
