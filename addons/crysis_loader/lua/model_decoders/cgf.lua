local model_loader = import("goluwa/render3d/model_loader.lua")
local cgf = import("lua/crysis_loader/cgf.lua")
model_loader.AddThreadedDecoder("cgf", cgf.Decoder)
