local pvars = import("goluwa/cli/pvars.lua")
local indirect_look = {}
pvars.StartGroup("Lighting", "Indirect look", {store = false, prefix = "gi_"})
indirect_look.bounce_gain = pvars.Setup2{
	key = "gi_bounce_gain",
	default = 1,
	help = "scales the albedo of surfaces that gi rays hit, so only light that has bounced off something gets brighter, the sky's light does not. It compounds per bounce, enclosed spaces gain more than open ones. 1 is physical",
}
indirect_look.bounce_saturation = pvars.Setup2{
	key = "gi_bounce_saturation",
	default = 1,
	help = "colourfulness of the albedo of surfaces that gi rays hit, 0 is grey bounce light and 2 twice the colour. It compounds per bounce like gi_bounce_gain. 1 is physical",
}
indirect_look.sky_gain = pvars.Setup2{
	key = "gi_sky_gain",
	default = 1,
	help = "scales the sky's light that gi rays bring back (probe and screen gi rays that miss), not the sky itself or the direct sun. 1 is physical",
}
pvars.EndGroup()
return indirect_look
