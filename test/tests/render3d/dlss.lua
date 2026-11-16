local T = import("test/environment.lua")
local vfs = import("goluwa/vfs.lua")
local dlss = import("goluwa/render3d/dlss.lua")
local ngx = import("goluwa/bindings/ngx.lua")

T.Test3D("Graphics render3d dlss features are available on nvidia gpus with the sdk libraries", function()
	if
		not vfs.IsDirectory(vfs.GetStorageDirectory("root") .. dlss.library_directory:Get())
	then
		return T.Unavailable("the dlss sdk libraries are not in " .. dlss.library_directory:Get())
	end

	T(dlss.IsAvailable(ngx.Feature.SuperSampling))["=="](true)
	T(dlss.IsAvailable(ngx.Feature.RayReconstruction))["=="](true)
end)
