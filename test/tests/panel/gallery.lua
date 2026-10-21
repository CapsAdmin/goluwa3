local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local vfs = import("goluwa/vfs.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Gallery = import("addons/ui_gallery/lua/gallery_browser.lua")
local names = theme.GetAvailable()
local original
local theme_index = 1
local page_index = 0
local gallery
local items

local function find_all(root, type_name)
	local found = {}

	for _, child in ipairs(root:GetChildrenList()) do
		if child.Type == type_name then found[#found + 1] = child end
	end

	return found
end

local function get_page_area(window)
	local _, second = find_all(window, "panel_splitter")[1]:get_external_children()
	return second
end

T.Test2DFrames("ui gallery builds every page in every theme", #names * (#vfs.Find("lua/gallery/%.lua$") + 2), function()
	if theme_index > #names then return end

	if not gallery then
		original = original or theme.active:GetName()
		theme.LoadTheme(names[theme_index])
		gallery = Gallery{Size = Vec2(1000, 700), Position = Vec2(0, 0)}
		items = find_all(gallery, "panel_context_menu_item")
		T(#items)[">"](10)
		page_index = 0
	elseif page_index < #items then
		page_index = page_index + 1
		items[page_index]:CallLocalEvent("OnClick")
		react.Flush()
		local area = get_page_area(gallery)
		T(items[page_index].Selected)["=="](true)
		T(area:GetViewport():HasChildren())["=="](true)

		for _, child in ipairs(area:GetChildrenList()) do
			if child.text and child.text:GetText():starts_with("this page failed") then
				T(child.text:GetText())["=="]("")
			end
		end
	else
		gallery:Remove()
		gallery = nil
		theme_index = theme_index + 1

		if theme_index > #names then theme.LoadTheme(original) end
	end
end)

T.Test2D("ui gallery follows theme changes through its dropdown without being rebuilt", function()
	local first = theme.active:GetName()
	local other

	for _, name in ipairs(names) do
		if name ~= first then
			other = name

			break
		end
	end

	local window = Gallery{Size = Vec2(1000, 700), Position = Vec2(0, 0)}
	local sidebar = find_all(window, "panel_context_menu_item")
	local dropdown = find_all(window, "panel_dropdown")[1]
	local area = get_page_area(window)
	T(dropdown:GetValue())["=="](first)
	dropdown.OnSelect(other, other, 1, dropdown)
	react.Flush()
	T(window:IsValid())["=="](true)
	T(theme.active:GetName())["=="](other)
	T(dropdown:GetValue())["=="](other)
	T(find_all(window, "panel_context_menu_item")[1])["=="](sidebar[1])
	T(area:IsValid())["=="](false)
	T(get_page_area(window):GetViewport():HasChildren())["=="](true)
	theme.LoadTheme(first)
	react.Flush()
	window:Remove()
end)

T.Test2D("ui gallery shows an error for a page that throws and recovers on the next one", function()
	local window = Gallery{Size = Vec2(1000, 700), Position = Vec2(0, 0)}
	local items = find_all(window, "panel_context_menu_item")
	local target = items[3]
	local page

	for _, file in ipairs(vfs.Find("lua/gallery/%.lua$")) do
		local candidate = import("lua/gallery/" .. file)

		if candidate.Name == target.Text then page = candidate end
	end

	local view = page.View
	page.View = react.Component(function()
		error("page exploded", 0)
	end)
	target:CallLocalEvent("OnClick")
	react.Flush()
	page.View = view
	local message

	for _, child in ipairs(get_page_area(window):GetChildrenList()) do
		if child.text and child.text:GetText():starts_with("this page failed") then
			message = child.text:GetText()
		end
	end

	T(message)["=="]("this page failed: page exploded")
	items[2]:CallLocalEvent("OnClick")
	react.Flush()
	T(get_page_area(window):GetViewport():HasChildren())["=="](true)
	T(items[2].Selected)["=="](true)
	T(target.Selected)["=="](false)
	window:Remove()
end)
