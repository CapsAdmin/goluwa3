local model_loader = import("goluwa/render3d/model_loader.lua")
local cgf = import("addons/crysis_loader/lua/crysis_loader/model_decoders/cgf.lua")
import("addons/crysis_loader/lua/crysis_loader/crysis_loader.lua")
model_loader.AddThreadedDecoder("cgf", cgf.Decoder)
