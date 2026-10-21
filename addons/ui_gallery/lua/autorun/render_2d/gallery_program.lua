local desktop = import("goluwa/render2d/ui/desktop.lua")
desktop.RegisterProgram{
	Name = "UI Gallery",
	Icon = "grid",
	Create = function()
		return import("addons/ui_gallery/lua/gallery_browser.lua"){Key = "GalleryWindow"}
	end,
}
