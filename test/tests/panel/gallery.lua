local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local vfs = import("goluwa/vfs.lua")
local Gallery = import("addons/ui_gallery/lua/gallery_browser.lua")
local names = theme.GetAvailable()
local original
local theme_index = 1
local page_index = 0
local gallery

T.Test2DFrames(
	"ui gallery builds every page in every theme",
	#names * (#vfs.Find("lua/gallery/%.lua$") + 2),
	function()
		if theme_index > #names then return end

		if not gallery then
			original = original or theme.active:GetName()
			theme.LoadTheme(names[theme_index])
			gallery = Gallery{Size = Vec2(1000, 700), Position = Vec2(0, 0)}
			T(#gallery._pages)[">"](10)
			page_index = 0
		elseif page_index < #gallery._pages then
			page_index = page_index + 1
			gallery:SelectPage(gallery._pages[page_index])
			T(gallery._page_scroll:GetViewport():HasChildren())["=="](true)
		else
			gallery:Remove()
			gallery = nil
			theme_index = theme_index + 1

			if theme_index > #names then theme.LoadTheme(original) end
		end
	end
)
