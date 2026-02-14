local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")

local function NewBox(name, size)
	local e = Panel.New()
	e:SetName(name)
	e:AddComponent("transform")
	e.transform:SetSize(size or Vec2(0, 0))
	return e
end

T.Test("layout - horizontal fit", function()
	local parent = NewBox("Parent", Vec2(100, 100))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetFitWidth(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(10, 10, 10, 10))
	parent.layout:SetChildGap(5)
	local child1 = NewBox("Child1", Vec2(30, 40))
	child1:SetParent(parent)
	local child2 = NewBox("Child2", Vec2(20, 50))
	child2:SetParent(parent)
	-- Force layout update
	parent.layout:UpdateLayout()
	-- Padding(10) + child1(30) + gap(5) + child2(20) + padding(10) = 75
	T(parent.transform:GetWidth())["=="](75)
	-- Padding(10) + max(40, 50) + padding(10) = 70
	T(parent.transform:GetHeight())["=="](70)
	-- Child positions
	T(child1.transform:GetX())["=="](10)
	T(child2.transform:GetX())["=="](45) -- 10 + 30 + 5
	-- Cleanup
	parent:Remove()
end)

T.Test("layout - grow", function()
	local parent = NewBox("Parent", Vec2(200, 100))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)
	local child1 = NewBox("Child1", Vec2(50, 50))
	child1:SetParent(parent)
	child1:AddComponent("layout")
	child1.layout:SetGrowWidth(1)
	local child2 = NewBox("Child2", Vec2(50, 50))
	child2:SetParent(parent)
	child2:AddComponent("layout")
	child2.layout:SetGrowWidth(1)
	parent.layout:UpdateLayout()
	-- 200 total, 50 + 50 fixed = 100 leftover. 50 + 50 = 100 each.
	T(child1.transform:GetWidth())["=="](100)
	T(child2.transform:GetWidth())["=="](100)
	T(child2.transform:GetX())["=="](100)
	parent:Remove()
end)

T.Test("layout - alignment", function()
	local parent = NewBox("Parent", Vec2(200, 200))
	parent:AddComponent("layout")
	parent.layout:SetDirection("y")
	parent.layout:SetAlignmentX("center")
	parent.layout:SetAlignmentY("end")
	local child = NewBox("Child", Vec2(50, 50))
	child:SetParent(parent)
	parent.layout:UpdateLayout()
	-- Center X: (200 - 50) / 2 = 75
	T(child.transform:GetX())["=="](75)
	-- End Y: 200 - 50 = 150
	T(child.transform:GetY())["=="](150)
	parent:Remove()
end)

T.Test("layout - reactive invalidation", function()
	local parent = NewBox("Parent", Vec2(100, 100))
	parent:AddComponent("layout")
	parent.layout:SetFitWidth(true)
	local child = NewBox("Child", Vec2(50, 50))
	child:SetParent(parent)
	child:AddComponent("layout")
	-- First layout
	parent.layout:UpdateLayout()
	T(parent.transform:GetWidth())["=="](50)
	-- Change child size - should invalidate parent
	child.transform:SetWidth(100)
	T(parent.layout:GetDirty())["=="](true)
	-- Update again
	parent.layout:UpdateLayout()
	T(parent.transform:GetWidth())["=="](100)
	parent:Remove()
end)

T.Test("layout - collapse repro", function()
	local parent = Panel.New(
		{
			Name = "Parent",
			transform = true,
			layout = {
				Direction = "y",
				FitHeight = true,
			},
		}
	)
	local child1 = Panel.New(
		{
			Parent = parent,
			Name = "Child1",
			transform = true,
			layout = {
				FitHeight = true, -- This will collapse to 0 because no children
			},
		}
	)
	local child2 = Panel.New(
		{
			Parent = parent,
			Name = "Child2",
			transform = true,
			layout = {
				FitHeight = true, -- Also collapses to 0
			},
		}
	)
	parent.layout:UpdateLayout()
	-- If they collapse to 0, they both sit at 0
	T(child1.transform:GetY())["=="](0)
	T(child1.transform:GetHeight())["=="](0)
	T(child2.transform:GetY())["=="](0)
	T(child2.transform:GetHeight())["=="](0)
	parent:Remove()
end)

T.Test("layout - text content intrinsic size", function()
	local parent = Panel.New(
		{
			Name = "Parent",
			transform = true,
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
		}
	)
	local text = Panel.New(
		{
			Parent = parent,
			Text = "Hello World",
			text = true,
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
		}
	)
	-- Mock font size for consistent testing in headless
	local font = text.text:GetFont()
	local w, h = 100, 20
	font.GetTextSize = function()
		return w, h
	end
	parent.layout:UpdateLayout()
	T(text.transform:GetWidth())["=="](w)
	T(text.transform:GetHeight())["=="](h)
	T(parent.transform:GetWidth())["=="](w)
	T(parent.transform:GetHeight())["=="](h)
	parent:Remove()
end)

T.Test("layout - nested grow and fit", function()
	local outer = Panel.New(
		{
			Name = "Outer",
			transform = true,
			layout = {
				Direction = "y",
				FitWidth = true,
				FitHeight = true,
				Padding = Rect(10, 10, 10, 10),
			},
		}
	)
	local row = Panel.New(
		{
			Parent = outer,
			Name = "Row",
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1, -- Conflicts with FitWidth on parent if not handled
				FitHeight = true,
				MinSize = Vec2(0, 50),
				AlignmentY = "center",
			},
		}
	)
	local item = Panel.New(
		{
			Parent = row,
			Name = "Item",
			transform = true,
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
		}
	)
	-- Mock intrinsic size for item
	item:AddComponent("text")
	item.text.GetFont = function()
		return {
			GetTextSize = function()
				return 100, 20
			end,
		}
	end
	outer.layout:UpdateLayout()
	-- Inner item should be 100x20
	T(item.transform:GetWidth())["=="](100)
	T(item.transform:GetHeight())["=="](20)
	-- Row should be 100x50 (MinSize.y = 50)
	T(row.transform:GetWidth())["=="](100)
	T(row.transform:GetHeight())["=="](50)
	-- Outer should be 100+padding x 50+padding = 120x70
	T(outer.transform:GetWidth())["=="](120)
	T(outer.transform:GetHeight())["=="](70)
	outer:Remove()
end)

T.Test("layout - default cross axis stretch", function()
	local parent = Panel.New(
		{
			Name = "Parent",
			transform = true,
			Size = Vec2(200, 200),
			layout = {
				Direction = "y", -- Vertical
				Padding = Rect(0, 0, 0, 0),
			},
		}
	)
	local child = Panel.New(
		{
			Parent = parent,
			Name = "Child",
			transform = true,
			layout = {
				Direction = "x",
				MinSize = Vec2(50, 50),
			},
		}
	)
	parent.layout:UpdateLayout()
	-- Direction is Y, so cross axis is X. 
	-- AlignmentX defaults to stretch.
	-- Parent is 200px wide. Child should be 200px wide.
	T(child.transform:GetWidth())["=="](200)
	parent:Remove()
end)

T.Test("layout - text wrapping", function()
	local container = Panel.New(
		{
			Name = "WrapContainer",
			transform = true,
			layout = {
				Direction = "y",
				FitWidth = true,
				FitHeight = true,
				MinSize = Vec2(100, 0),
				MaxSize = Vec2(100, 0),
			},
		}
	)
	local text_panel = Panel.New(
		{
			Parent = container,
			Name = "TextPanel",
			transform = true,
			layout = {
				GrowWidth = 1,
				FitHeight = true,
			},
		}
	)
	local text_comp = text_panel:AddComponent("text")
	-- Mock font measurement for wrapping
	-- We want to simulate that at 100px width, "A B C" wraps to 3 lines
	local font = {
		GetTextSize = function(self, text)
			if text == "A\nB\nC" then return 20, 60 end

			return 60, 20
		end,
		WrapString = function(self, text, width)
			if width <= 30 then return "A\nB\nC" end

			return text
		end,
	}
	text_comp.GetFont = function()
		return font
	end
	text_comp:SetText("A B C")
	text_comp:SetWrap(true)
	-- Force layout multiple times to converge
	container.layout:UpdateLayout()
	container.layout:UpdateLayout()
	-- 100px is wide enough NOT to wrap (width > 30).
	T(text_panel.transform:GetHeight())["=="](20)
	-- Now change container width to 20px
	container.layout:SetMinSize(Vec2(20, 0))
	container.layout:SetMaxSize(Vec2(20, 0))
	-- Converge
	container.layout:UpdateLayout()
	container.layout:UpdateLayout()
	T(text_panel.transform:GetHeight())["=="](60)
	T(container.transform:GetHeight())["=="](60)
	container:Remove()
end)
