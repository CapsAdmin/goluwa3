HOTRELOAD = false
local ffi = require("ffi")
local audio = require("audio")
local event = require("event")
local system = require("system")
local my_sound = audio.LoadSound(
	"https://github.com/Metastruct/garrysmod-chatsounds/raw/refs/heads/master/sound/chatsounds/autoadd/3kliksphillip/caboosing.ogg"
)
my_sound:Play()

if system.IsRunning() then return end

local unref = system.KeepAlive("audio test")

event.AddListener("Update", "test", function()
	if not my_sound:IsPlaying() then
		print("Sound finished playing!")
		unref()
	end
end)