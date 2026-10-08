local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Gallery = import("addons/ui_gallery/lua/gallery_browser.lua")

T.Test2D("ui gallery builds every page in every theme", function()
	local original = theme.active:GetName()

	for _, name in ipairs(theme.GetAvailable()) do
		theme.LoadTheme(name)
		local gallery = Gallery{Size = Vec2(1000, 700), Position = Vec2(0, 0)}
		T(#gallery._pages)[">"](10)

		for _, page in ipairs(gallery._pages) do
			gallery:SelectPage(page)
			T(gallery._page_scroll:GetViewport():HasChildren())["=="](true)
		end

		gallery:Remove()
	end

	theme.LoadTheme(original)
end)
