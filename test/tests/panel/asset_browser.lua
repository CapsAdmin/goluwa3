local T = import("test/environment.lua")
local react = import("goluwa/render2d/ui/react.lua")
local assets = import("goluwa/assets.lua")
local AssetBrowser = import("lua/asset_browser.lua")

local function find_first(root, predicate)
	for _, child in ipairs(root:GetChildrenList()) do
		if predicate(child) then return child end
	end
end

local function find_grid(root)
	return find_first(root, |child| -> child.SetItems and child.GetSelectedIndex and child.OnDrawItem)
end

local function button(root, text)
	return find_first(root, |child| -> child.Type == "panel_button" and child:GetText() == text)
end

local function tab(root, name)
	return find_first(root, |child| -> child.TabName == name)
end

local function has_text(root, text)
	return find_first(root, |child| -> child.Type == "panel_text" and child.text:GetText() == text) ~= nil
end

local function names(grid)
	local list = {}

	for _, item in ipairs(grid:GetItems()) do
		list[#list + 1] = (item.is_folder and "[" .. item.name .. "]" or item.name)
	end

	return table.concat(list, ",")
end

T.Test2D("asset browser opens once per key and a pick calls back and closes it", function()
	local picked
	local window = AssetBrowser{
		Key = "TestAssetPicker",
		PickerCategory = "components",
		OnPick = |entry| -> do
			picked = entry
		end,
	}
	react.Flush()
	T(AssetBrowser{Key = "TestAssetPicker"})["=="](window)
	local grid = find_grid(window)
	local items = grid:GetItems()
	T(#items)[">"](0)
	T(items[1].category)["=="]("components")
	T(has_text(window, "Select an asset, then press Select."))["=="](true)
	grid.OnSelect(items[1], 1)
	react.Flush()
	T(has_text(window, items[1].name .. items[1].extension))["=="](true)
	T(has_text(window, items[1].path))["=="](true)
	button(window, "Select"):CallLocalEvent("OnClick")
	T(picked)["=="](items[1])
	react.Flush()
	T(window:IsValid())["=="](false)
end)

T.Test2D("asset browser navigates folders, keeps the tree, the breadcrumb and the selection in step and lists subfolders", function()
	local paths = {
		"models/test_browser/one.lua",
		"models/test_browser/sub/two.lua",
		"models/test_browser/sub/three.lua",
	}

	for _, path in ipairs(paths) do
		assets.RegisterVirtualAsset(path, {category = "models", load = || -> nil})
	end

	local window = AssetBrowser{Key = "TestAssetNavigation"}
	react.Flush()
	local grid = find_grid(window)
	local top
	local models_tab = tab(window, "models")
	models_tab.OnClick(models_tab)
	react.Flush()

	for _, item in ipairs(grid:GetItems()) do
		if item.is_folder and item.name == "test_browser" then top = item end
	end

	T(top ~= nil)["=="](true)
	grid.OnActivate(top, 1)
	react.Flush()
	T(names(grid))["=="]("[sub],one")
	T(has_text(window, "test_browser"))["=="](true)
	T(has_text(window, "2 folders, 1 assets") or has_text(window, "1 folders, 1 assets"))["=="](true)
	local sub = grid:GetItems()[1]
	-- selecting a folder highlights it in the grid but there are no asset details for it
	grid.OnSelect(sub, 1)
	react.Flush()
	T(has_text(window, "Select an asset to see details."))["=="](true)
	grid.OnActivate(sub, 1)
	react.Flush()
	T(names(grid))["=="]("three,two")
	local tree = find_first(window, |child| -> child.GetSelectedKey)
	T(tree:GetSelectedKey():find("sub", 1, true) ~= nil)["=="](true)
	grid.OnSelect(grid:GetItems()[2], 2)
	react.Flush()
	T(has_text(window, "models/test_browser/sub/two.lua"))["=="](true)
	T(grid:GetSelectedItem().name)["=="]("two")
	local subfolders = button(window, "Subfolders")
	subfolders:CallLocalEvent("OnClick")
	react.Flush()
	T(#grid:GetItems())["=="](2)
	local textures_tab = tab(window, "textures")
	textures_tab.OnClick(textures_tab)
	react.Flush()
	T(grid:GetItems()[1].category ~= "models" or #grid:GetItems() == 0)["=="](true)
	models_tab.OnClick(models_tab)
	react.Flush()
	T(has_text(window, "models"))["=="](true)
	window:Remove()
	react.Flush()

	for _, path in ipairs(paths) do
		assets.UnregisterVirtualAsset(path)
	end
end)
