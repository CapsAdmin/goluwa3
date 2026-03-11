local ffi = require("ffi")
local audio = require("audio")
local event = require("event")
local system = require("system")
audio.Initialize()
local my_sound = audio.LoadSound(
	"https://github.com/Metastruct/garrysmod-chatsounds/raw/refs/heads/master/sound/chatsounds/autoadd/darkest_dungeon/slowly.ogg"
)
my_sound:Play()
my_sound:KeepApplicationAlive()
