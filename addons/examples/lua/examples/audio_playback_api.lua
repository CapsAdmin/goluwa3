local ffi = require("ffi")
local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
audio.Initialize()
local my_sound = audio.LoadSound(
	"https://github.com/Metastruct/garrysmod-chatsounds/raw/refs/heads/master/sound/chatsounds/autoadd/darkest_dungeon/slowly.ogg"
)
my_sound:Play()
my_sound:KeepApplicationAlive()
