local desktop = import("goluwa/render2d/ui/desktop.lua")
desktop.RegisterProgram{
	Name = "Assets",
	Icon = "folder",
	Create = function()
		return import("lua/asset_browser.lua"){Key = "AssetBrowserWindow"}
	end,
}
