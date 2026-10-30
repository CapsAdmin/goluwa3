local voices = {}

local function numbered(format, first, last)
	local paths = {}

	for i = first, last do
		paths[#paths + 1] = format:format(i)
	end

	return paths
end

local function set(paths, gain, pitch)
	return {Paths = paths, Gain = gain, Pitch = pitch}
end

local function derive(base, overrides)
	local out = table.shallow_copy(base)

	for key, value in pairs(overrides) do
		out[key] = value
	end

	return out
end

local function foot(format, count, length, gain)
	return {Paths = numbered(format, 1, count), Length = length, Gain = gain}
end

voices.zombie = {
	Foot = foot("npc/zombie/foot%d.wav", 3, nil, 0.3),
	Idle = set(numbered("npc/zombie/zombie_voice_idle%d.wav", 1, 14), 0.45),
	Alert = set(numbered("npc/zombie/zombie_alert%d.wav", 1, 3), 0.7),
	Pain = set(numbered("npc/zombie/zombie_pain%d.wav", 1, 6), 0.7),
	Death = set(numbered("npc/zombie/zombie_die%d.wav", 1, 3), 0.8),
	Attack = set(numbered("npc/zombie/claw_miss%d.wav", 1, 2), 0.6),
	Hit = set(numbered("npc/zombie/claw_strike%d.wav", 1, 3), 0.7),
}
voices.zombie_soldier = voices.zombie
voices.zombie_torso = derive(voices.zombie, {Foot = foot("npc/zombie/foot_slide%d.wav", 3, 0.5, 0.25)})
voices.zombie_fast = derive(
	voices.zombie,
	{
		Foot = foot("npc/fast_zombie/foot%d.wav", 4, nil, 0.35),
		Idle = set(numbered("npc/fast_zombie/idle%d.wav", 1, 3), 0.45),
		Alert = set({"npc/fast_zombie/fz_alert_close1.wav", "npc/fast_zombie/fz_scream1.wav"}, 0.8),
		Attack = set(numbered("npc/fast_zombie/claw_miss%d.wav", 1, 2), 0.6),
		Hit = set(numbered("npc/fast_zombie/claw_strike%d.wav", 1, 3), 0.7),
	}
)
voices.zombie_poison = derive(
	voices.zombie,
	{
		Foot = foot("npc/zombie/foot%d.wav", 3, nil, 0.35),
		Idle = set({"npc/zombie_poison/pz_idle2.wav", "npc/zombie_poison/pz_idle3.wav", "npc/zombie_poison/pz_idle4.wav"}, 0.45),
		Alert = set({"npc/zombie_poison/pz_alert1.wav", "npc/zombie_poison/pz_alert2.wav", "npc/zombie_poison/pz_warn1.wav"}, 0.7),
		Pain = set(numbered("npc/zombie_poison/pz_pain%d.wav", 1, 3), 0.7),
		Death = set(numbered("npc/zombie_poison/pz_die%d.wav", 1, 2), 0.8),
	}
)
voices.antlion = {
	Foot = foot("npc/antlion/foot%d.wav", 4, nil, 0.25),
	Idle = set(numbered("npc/antlion/idle%d.wav", 1, 5), 0.45),
	Alert = set({"npc/antlion/distract1.wav"}, 0.7),
	Pain = set(numbered("npc/antlion/pain%d.wav", 1, 2), 0.7),
	Death = set(numbered("npc/antlion/antlion_burst%d.wav", 1, 2), 0.7),
	Attack = set(numbered("npc/antlion/attack_single%d.wav", 1, 3), 0.7),
}
voices.antlion_worker = voices.antlion
voices.antlion_guard = {
	Foot = foot("npc/antlion_guard/foot_heavy%d.wav", 2, nil, 0.6),
	Idle = set({"npc/antlion_guard/growl_idle.wav"}, 0.7),
	Alert = set(numbered("npc/antlion_guard/angry%d.wav", 1, 3), 1),
	Charge = set({"npc/antlion_guard/growl_high.wav"}, 1),
	Pain = set(numbered("npc/antlion_guard/antlion_guard_pain%d.wav", 1, 2), 1),
	Death = set(numbered("npc/antlion_guard/antlion_guard_die%d.wav", 1, 2), 1),
	Attack = set({"npc/antlion_guard/shove1.wav"}, 0.9),
	Hit = set(numbered("npc/antlion_guard/antlion_guard_shellcrack%d.wav", 1, 2), 1),
}
voices.headcrab = {
	Idle = set(numbered("npc/headcrab/idle%d.wav", 1, 3), 0.4),
	Alert = set({"npc/headcrab/alert1.wav"}, 0.6),
	Pain = set(numbered("npc/headcrab/pain%d.wav", 1, 3), 0.6),
	Death = set(numbered("npc/headcrab/die%d.wav", 1, 2), 0.6),
	Attack = set(numbered("npc/headcrab/attack%d.wav", 1, 3), 0.6),
	Hit = set({"npc/headcrab/headbite.wav"}, 0.6),
}
voices.headcrab_black = {
	Foot = foot("npc/headcrab_poison/ph_step%d.wav", 4, 0.4, 0.25),
	Idle = set(numbered("npc/headcrab_poison/ph_idle%d.wav", 1, 3), 0.4),
	Alert = set(numbered("npc/headcrab_poison/ph_warning%d.wav", 1, 3), 0.6),
	Pain = set(numbered("npc/headcrab_poison/ph_pain%d.wav", 1, 3), 0.6),
	Death = set(numbered("npc/headcrab_poison/ph_scream%d.wav", 1, 3), 0.6),
	Attack = set(numbered("npc/headcrab_poison/ph_jump%d.wav", 1, 3), 0.6),
	Hit = set(numbered("npc/headcrab_poison/ph_poisonbite%d.wav", 1, 3), 0.6),
}
voices.hunter = {
	Foot = foot("npc/ministrider/ministrider_footstep%d.wav", 5, nil, 0.5),
	Idle = set(numbered("npc/ministrider/hunter_angry%d.wav", 1, 3), 0.6),
	Alert = set(numbered("npc/ministrider/hunter_alert%d.wav", 1, 3), 0.9),
	Pain = set({"npc/ministrider/hunter_pain2.wav", "npc/ministrider/hunter_pain4.wav"}, 0.9),
	Death = set({"npc/ministrider/hunter_die2.wav", "npc/ministrider/hunter_die3.wav"}, 1),
	Attack = set(numbered("npc/ministrider/hunter_angry%d.wav", 1, 3), 0.9),
	Hit = set(numbered("npc/ministrider/body_medium_impact_hard%d.wav", 1, 6), 0.8),
}
voices.vortigaunt = {
	Foot = foot("npc/vort/vort_foot%d.wav", 4, 0.9, 0.4),
	Pain = set({"npc/vort/vort_pain3.wav"}, 0.8),
	Attack = set(numbered("npc/vort/vort_attack_shoot%d.wav", 1, 4), 0.7),
}
voices.vortigaunt_slave = voices.vortigaunt
voices.metrocop = {
	Pain = set(numbered("npc/metropolice/pain%d.wav", 1, 4), 0.8),
	Death = set(numbered("npc/metropolice/die%d.wav", 1, 4), 0.9),
}
voices.combine_soldier = {
	Pain = set(numbered("npc/combine_soldier/pain%d.wav", 1, 3), 0.8),
	Death = set(numbered("npc/combine_soldier/die%d.wav", 1, 3), 0.9),
}
voices.combine_elite = voices.combine_soldier
voices.combine_guard = voices.combine_soldier
voices.citizen = {
	Pain = set(numbered("vo/npc/male01/pain%02d.wav", 1, 6), 0.8),
	Death = set(numbered("vo/npc/male01/pain%02d.wav", 7, 9), 0.9),
}
voices.rebel = voices.citizen
voices.monk = voices.citizen
voices.kleiner = voices.citizen
voices.eli = voices.citizen
voices.odessa = voices.citizen
voices.citizen_female = {
	Pain = set(numbered("vo/npc/female01/pain%02d.wav", 1, 6), 0.8),
	Death = set(numbered("vo/npc/female01/pain%02d.wav", 7, 9), 0.9),
}
voices.mossman = voices.citizen_female
voices.barney = {
	Pain = set(numbered("vo/npc/barney/ba_pain%02d.wav", 1, 7), 0.8),
	Death = set(numbered("vo/npc/barney/ba_pain%02d.wav", 8, 10), 0.9),
}
voices.alyx = {
	Pain = set({"vo/npc/alyx/hurt04.wav", "vo/npc/alyx/hurt05.wav", "vo/npc/alyx/hurt06.wav", "vo/npc/alyx/hurt08.wav"}, 0.8),
}
return voices
