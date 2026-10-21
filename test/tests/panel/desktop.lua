local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")

local function find_all(root, type_name)
	local found = {}

	for _, child in ipairs(root:GetChildrenList()) do
		if child.Type == type_name then found[#found + 1] = child end
	end

	return found
end

local function get_root()
	for _, child in ipairs(Panel.World:GetChildren()) do
		if desktop.IsBackdrop(child) then return child end
	end
end

local function button_names(root)
	local names = {}

	for _, button in ipairs(find_all(root, "panel_button")) do
		names[#names + 1] = button:GetText()
	end

	return table.concat(names, ",")
end

T.Test2D("desktop adds programs and menus registered after it was made to the root it has", function()
	desktop.RegisterProgram{
		Name = "TestEarly",
		Icon = "folder",
		Create = function()
			return Window{Title = "EARLY"}
		end,
	}
	desktop.Show(false)
	react.Flush()
	local root = get_root()
	T(root ~= nil)["=="](true)
	T(root.visual:GetVisible())["=="](true)
	T(button_names(root):find("TestEarly", 1, true) ~= nil)["=="](true)
	T(button_names(root):find("Load", 1, true) == nil)["=="](true)
	local bar = find_all(root, "panel_menu_bar")[1]
	T(#bar.Items)["=="](2)
	desktop.RegisterProgram{
		Name = "TestLate",
		Icon = "folder",
		Create = function()
			return Window{Title = "LATE"}
		end,
	}
	desktop.RegisterMenu{
		Text = "TESTMENU",
		Items = function()
			return {}
		end,
	}
	react.Flush()
	T(get_root())["=="](root)
	T(button_names(root):find("TestLate", 1, true) ~= nil)["=="](true)
	T(#bar.Items)["=="](3)
	T(bar.Items[3].Text)["=="]("TESTMENU")

	for _, button in ipairs(find_all(root, "panel_button")) do
		if button:GetText() == "TestLate" then button:CallLocalEvent("OnClick") end
	end

	T(desktop.IsOpen("TestLate"))["=="](true)
	desktop.Hide()
	T(root.visual:GetVisible())["=="](false)
	desktop.Show(false)
	T(get_root())["=="](root)
	T(root.visual:GetVisible())["=="](true)
	desktop.Hide()
	desktop.GetProgram("TestLate").Window:Remove()
	desktop.GetProgram("TestEarly").Window:Remove()
end)
