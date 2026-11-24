local model_loader = import("goluwa/render3d/model_loader.lua")
local chr = import("lua/crysis_loader/chr.lua")
model_loader.AddModelDecoder("chr", chr.Decode)
