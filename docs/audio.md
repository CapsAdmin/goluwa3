# Audio

Physically based by default: sound travels at `audio.speed_of_sound` through a delay line per voice, doppler is the derivative of that delay, and a traced environment drives occlusion, reflections and reverb. World units are meters, levels are dB SPL.

Module map (`goluwa/audio/`):

- `runtime.lua`, `sound.lua`, `state.lua`: the `audio.*` API, the `Sound` object, voices (`audio.SLOT_COUNT`) and the mixer state shared with the audio thread.
- `mix.lua`: the mixer on the audio thread.
- `spatial.lua`: per path delay, rate and band gains computed on the main thread; motion tracking, head shadow, pinna cues, air absorption, atmosphere.
- `dsp.lua`: reverb buses (FDN), band filters, the ear/limiter output stage, loudness measurement.
- `acoustics.lua` (+ `acoustics_gpu.lua`, `acoustics_cpu.lua`): the traced environment.
- `ground.lua`: ground reflection (impedance plane). `explosion.lua`: synthesized blast signatures. `signals.lua`: deterministic test signals (`Clap`, `Boom`).

## Mixer

- Block based. Each spatial voice writes its emitted mono signal (volume, pitch, source sample rate applied) into a history ring; the ears, reflection taps and reverb sends are fractional reads from that ring at their delays. Nothing else in the mixer knows about geometry. History length grows with the longest path a voice needs; a path past the history clamps to it.
- The main thread (`spatial.lua`, every `audio.Update`) writes per path a delay, its rate of change and 3 band gains, stamped with `audio.clock()`. The mixer reads at the reported rate and corrects the remaining delay error slowly. Do not chase each block's target delay within the block: any noise in the targets becomes audible pitch jitter, because the ear hears every step of a delay as pitch.
- Delays use the retarded (emission time) source position, solved in closed form for short paths and against the source's recorded trajectory for long ones (`spatial.PathTiming`). Positions and velocities come from a critically damped tracker of each source and the listener (`spatial.UpdateMotion`); there is no velocity API. Direction, distance and air loss come from where the sound was emitted, not where the source is now; occlusion and reverb tracing use the current position.
- Paths are solved relative to the air: `audio.SetWind` moves the medium, scaled by how open the listener's space is (indoor air stands still). Sources are held below `spatial.MAX_SOURCE_MACH`: past the speed of sound there are two arrivals, which one delay line cannot play. `doppler_factor` scales the effective speed of sound (0 = instant).
- Ears are `audio.ear_distance` apart, so interaural time difference falls out of the per ear delays; head shadow is a band gain. Pinna cues (pvar `audio_pinna`) are peaking filters per ear from the direction in head space, since the 3 bands cannot express the narrow high frequency notches that give up/down and front/back. Reflection taps are read per ear too and grouped by direction for their pinna filtering.
- Non-spatial sounds (`Sound:SetSpatial(false)`: UI, music) play the buffer directly in stereo. Spatial stereo sounds keep a mid and a side history (left = mid + side, right = mid - side); taps and reverb sends use the mid. Never sum L and R into one signal: channels that differ in phase comb-filter.
- Every start and non looping end is ramped (declick). `SetFadeIn`, `SetFadeInFraction`, `SetFadeOut` lengthen it. Stopping a spatial sound stops emission; what is in flight still arrives. `Sound:Cut()` and `audio.StopAll()` cut hard.
- `audio.CreateStream(fill, seconds, sample_rate, channels)` makes live, generated audio: a looping buffer that `audio.Update` refills through `fill(data, from, count)` behind the play position. The buffer length is the latency; use the shortest that survives a frame hitch. Frozen noise that repeats every few seconds is audible, generate it continuously.
- `Sound:SetBandGains(Vec3(low, mid, high))` shapes what a spatial sound emits. The crossovers are shallow, so it only gives gentle tilts.
- When all voices are busy, a new sound steals the quietest non-looping spatial voice (level at the listener) if it is louder there; loops are never stolen, non-spatial sounds outrank everything.
- Bands: crossovers at 500 Hz and 4 kHz, centers 250/1500/8000 Hz. Gains are given at band centers and converted with `dsp.WarpBandGains`; they cannot make steep steps between bands.

### Levels and the output stage

- `Sound:SetNormalized(true)` makes volume 1 play at `audio.reference_loudness`, using `Sound:GetLoudness()` (BS.1770 momentary loudness of the buffer). Normalize game sounds so volumes compare across files. `Sound:SetLevel(spl)` sets the level in dB SPL at the reference distance (`audio.SPLToVolume`, `VolumeToSPL`; `audio.reference_spl` is what plays at the reference loudness). Give sounds their real levels and let distance and the output stage handle the rest. `audio.SetListenerGain` is the user's volume.
- The output stage after the master gain (`dsp.ProcessEar`, then `dsp.ProcessLimiter`) models the acoustic reflex: a separate low band compressor (bass carries most of a blast's energy and is the least audible), then a loudness weighted compressor, then a lookahead peak limiter that only catches what the ear stage has not reacted to yet. Pvars `audio_ear`, `audio_limiter` (`on`, `clip`, `soft`) and `audio_gain` turn stages off or move the operating point to tell which one shapes what you hear. The limiter adds latency of its lookahead.

### Reverb buses

- Two buses (`dsp.ProcessReverb`: 16 line FDN, per line 3 band absorption, Hadamard feedback, input diffusion), normalized so sends carry physical energy. The listener bus is the room you are in and stays diffuse; the second bus carries sounds in another space (much longer decay than the listener's) and can be directed toward where their energy arrives from.
- A bus's `scale` (line lengths) follows the space's mean free path, and `diffusion` falls in open spaces. Scale changes crossfade between read positions; never move a read position in a feedback loop, it pitches the tail again on every pass. Rescale stored energy when the output gain changes with the scale.
- Outputs are coherent between the ears at low frequencies and uncorrelated above (`dsp.REVERB_COHERENT_BELOW`), like a diffuse field.
- The FDN needs about its mean line delay to build up, so the diffused input is also emitted as an onset burst holding the matching energy share.
- In a feedback loop a small per pass gain error is a large T60 error: line gains are fitted per band (`dsp.FitBandGains`). Air absorption is not flat over the high band, so each line runs through the air filter cascade for its physical length instead of folding air into the band T60.

## Environment (`acoustics.lua`)

A tracer runs the same jobs on the GPU (`acoustics_gpu.lua`: ray queries on the scene TLAS in a compute pass, read back a swapchain cycle later) or the CPU (`acoustics_cpu.lua`: `physics.RayCast` against static, kinematic and large dynamic bodies; bodies with `CollisionMask == 0` are trace-only proxies and never occlude). Pvar `audio_acoustics` = auto, gpu, cpu or off. Both must give the same results: the GLSL mirrors the Lua in `acoustics.lua` (`PathTrace`, `Transmit`, `ChainTransmission`), so change both.

- `tracer:Trace` returns distance, the normal facing the ray, an acoustic material record (`acoustics.NewMaterial`), front facing, and for convex solids the exit distance. Physics meshes are wound counterclockwise seen from outside, render meshes clockwise (`render3d/scene/hit.lua`).
- Listener path tracing (mirror or diffuse bounces chosen by the material's scattering, bands reweighted so they share rays without bias) gathers statistics: hits, escapes, mean free path, reflectance per band. T60 per band comes from per segment survival (escape counts as absorption), so it matches Eyring in closed rooms and drops outdoors. Statistics fade with time and with distance moved relative to the mean free path, so walking through a door switches rooms quickly.
- Next event estimation from every bounce to each source gives the reverberant energy relative to the direct sound. Only energy after the split time and at least two bounces feeds the reverb; first order energy is the reflection taps' job. Energy past the last traced bounce is completed analytically from the settled bounces. Estimators bound their outliers (`MIN_SOURCE_DISTANCE`, `MAX_TAIL_DELAY_PATHS`).
- The listener position itself is traced as one more source (the environment's `ambient` sums); a new or moved sound starts from a copy of it scaled by the decay over its distance (`ScaleSourceSums`), so one-shots are never dry. Sounds near a traced one share its trace (`CLUSTER_DISTANCE`). Far sounds beyond `GetEmitterReach` are also traced from their own position (`BuildEmitterJob`), since listener rays rarely reach the space around them; by reciprocity both estimates agree where both see it.
- The listener bus T60 is energy weighted from the arrival time centroid, not the statistical (early slope) T60; the second moment of arrival times tells a dense tail from a few discrete echoes. The predelay is the split time, moved earlier for spaces smaller than the shortest bus scale.
- Direct occlusion: while the line is clear, the visible share of the first Fresnel zone per band; while blocked, diffraction over the shortest detour found around the obstacle (Kurze-Anderson barrier loss, capped per ISO 9613-2), held and followed across frames so moving sources do not cut in and out. The blocked share also transmits through walls (`Transmit`). A sealed room gets no diffraction at all.
- Transmission is the limp panel mass law per leaf, averaged inside each band, with double leaf coupling bounded (Sharp). A leaf is a solid crossed by the ray (`AcousticDensity * length`) or an unpaired face (`AcousticSurfaceMass`).
- First hits are clustered into planes; image sources validated with rays become reflection taps. On Play, recently seen planes become taps at once (a one-shot ends before a validation returns). Escaping rays cluster into openings (`GetOpenings`).
- New sounds are probed synchronously on Play (CPU, a few dozen rays with a precollected candidate list) so a one-shot behind a wall does not start unoccluded; this is the cost of every impact sound. `Sound:SetTraced(false)` keeps a spatial sound out of acoustics.
- Snow (`audio.SetSnowDepth`) blends upward, sky exposed hits toward `acoustics.SNOW` by depth over wavelength.
- The listener's own gear is not in the acoustic scene: instances under a `character_movement` or `weapon_holder` entity get `instances.MASK_SELF` (`render3d/scene/bridge.lua`) and the trace shader (`hit.GetTraceGLSL(tlas, skip_mask)`) skips them. Rays starting inside the player's own body or a held item corrupt every statistic.
- Listener rays start `LISTENER_CLEARANCE` out; rays toward a source stop `SOURCE_CLEARANCE` short.

### Acoustic materials

Material params (`render3d/features/acoustics.lua`): `AcousticAbsorption` (energy not reflected, per band, includes transmission), `AcousticScattering` (ISO 17497 per band), `AcousticDensity` (average of the construction behind the surface, not the facing material), `AcousticSurfaceMass` (one panel), `AcousticRainEmission`, `AcousticWindEmission`. A surface cannot absorb less than it transmits: `vmt_material.lua` errors at load otherwise.

Source materials resolve an acoustic class separately from the render class (`ACOUSTIC_*` tables in `vmt_material.lua`): `$surfaceprop` up the base chain, then keywords in the material name and textures, then the model's physics surfaceprop, then directory keywords. Collision-only tool faces and fake skies are `open` (fully absorbing). Real facades are diffuse (balconies, reveals), so facade classes have high scattering; flat parallel walls with low scattering trap energy in specular flutter. Pvar `audio_scattering` scales every material's scattering.

## Ground, air and atmosphere

- Ground (`ground.lua`): a reflection off soft ground at grazing incidence comes back inverted and partly absorbed, cancelling lows and mids at distance. An upward facing soft reflector is a ground tap; `ground.Coefficient` is the exact spherical wave reflection coefficient on an impedance plane (Delany Bazley, including the surface wave). For a few far sounds the mixer convolves the voice with a FIR designed from it (`GetGroundFilter`, two sided, so the tap reads ahead); other ground taps use a signed gain. Compare results as levels with deep nulls floored, not as coefficients: a cancellation's depth is a difference of two nearly equal numbers.
- Air absorption follows ISO 9613-1 through a cascade of one pole filters per ear and path (`spatial.GetAirFilter`), since a flat band gain cannot follow a loss that grows with f^2. Taps and reverb lines run their own cascades. `audio.SetAir(celsius, humidity, pressure)` updates absorption and the speed of sound; the ambience addon drives it from the weather. The traced statistics use a per meter fit (`AIR_ABSORPTION_DB`).
- Atmosphere (`spatial.lua`, `mix.lua`): turbulence (`audio.SetTurbulence`, plus wind) gives scintillation of the direct path's mid and high bands and reduces ground reflection coherence. Refraction from a linear sound speed gradient (`audio.SetTemperatureGradient`, wind along the path) gives a shadow zone past the horizon or ducting gain; only the direct path and ground tap are affected. Not modelled: arrival time spread, nonlinear N wave lengthening, refraction beyond a linear profile.

## Explosions (`explosion.lua`)

`explosion.Generate(charge_kg, distance, sample_rate, seed)` returns a dry pressure signature at `distance` from a TNT equivalent charge (Friedlander shock with negative phase, fireball crackle, thump, debris), peak normalized, plus the shock overpressure in Pa (`GetBlast`, Kinney and Graham). Set its level from the overpressure with `SetNormalized(false)` and `SetReferenceDistance(distance)`. It contains no reverb or propagation; air, ground and room come from the engine.

## Game sounds (`addons/game/lua/`)

- `impacts.lua`: `impacts.Fire` calls the `Impact` event; sounds listen to it, detectors only fire it. Footsteps come from foot plants (`source_pose`, `eye_pose`), with per model foot surface overrides in `foot_surfaces.lua`. Physics impacts come from the core `PhysicsImpact` event (`impacts.FirePhysics`, one event per side with the other body's surface), sliding and rolling from `PhysicsContact` (`impacts.FireContact`, the `Contact` event). Physics events carry reduced `Mass` and the sounding body's `Size`. See physics.md.
- `Surface` is the material's `SurfaceType`, always one of the fixed engine set in `goluwa/surface_types.lua`. Each content loader translates its own names (`source_loader/surface_types.lua`, `crysis_loader/surface_types.lua`). Sound profiles (`sound_profiles.lua`, `sound_profiles/source1.lua`, `source2.lua` once Alyx surface properties are mounted) map engine surfaces to footstep, impact, scrape and roll sets; adding a surface means adding it to the list and both profiles (`addons/game/tests/entities/sound_profiles.lua` checks it). Terrain reads the surface of the layer under the hit.
- `autorun/audio/footsteps.lua`, `physics_sounds.lua`: level from speed, mass and material; soft hits start later in the sample to drop the attack; pitch comes from body size (a resonance scales with length, not mass), never random. Contacts drive per pair scrape and roll loops.
- `sounds.lua`: `sounds.CreateSource` makes every game sound normalized with a 2 m reference distance and drops plays too quiet at the listener; no fixed range. `sounds.Play`'s `keep` fades out a recorded sound's own room tail so the traced reverb replaces it.
- Generated ambience: `autorun/audio/ear_wind.lua` (wind in your ears, non-spatial stream from air speed relative to the head, pvar `audio_ear_wind`), `world_wind.lua` (the world wind as an ambience stream with rumble, body, whistle and rustle layers, pvars `audio_wind_rumble`, `audio_wind_whistle`, `audio_wind_rustle`), `wind_whistles.lua` (thin static bodies whistling at the Strouhal frequency, pvar `audio_wind_whistles`), `surf_sounds.lua` (synthesized wave breaks; rotate variants, since overlapping copies of one noise buffer comb-filter), `foliage_sounds.lua` (rustle of bodies moving through cover from `goluwa/foliage_field.lua`).
- `goluwa/shelter.lua`: how much of the air arriving from a direction is blocked at a point (a cached ray fan; call it at a few Hz). Whether the listener's space is open at all comes from the acoustics trace (`audio.medium_velocity` uses its openness).
- Voices: `event.Call("ClientVoiceOrigin", client)` gives where a client speaks from (`autorun/audio/voice.lua`); chatsounds play spatially from it with a voice cone.

## Ambience (`acoustics.lua` gather, `addons/game/lua/ambience.lua`)

Rain and wind are sound emitted by surfaces, not by the sky. Listener paths gather it by reciprocity (`audio.SetAmbienceTracing(rain_up, upwind)`): a path reaching an exposed surface brings its `AcousticRainEmission` / `AcousticWindEmission` radiance times its throughput, reflections and transmission through roofs and windows included. `GetAmbience()` returns radiance per band and in direction bins; the addon plays the strongest bins as untraced spatial voices at their direction and the rest as a bed, with no reverb send (the gather already contains the room). `ambience.SetSource` swaps a kind's sound. Indoor levels come only from geometry.

## Debugging

- `perf audio` (AUDIO tab, `addons/debug/lua/autorun/render_3d/audio_acoustics.lua`): tracer, listener room (T60 per band, mean free path, predelay, openings), gathered ambience, every spatial sound (delay, doppler, occlusion, transmission, send and bus, reflections), a top down map of hits, planes and paths, decay curves and the output stage with a level history.
- `audio_record <seconds>` records what the mixer renders to `storage/logs/audio_capture/` (`_out.wav` after the output stage, `_dry.wav` and `_rev.wav` before it) plus room, bus and sound state over time in `_info.txt`. Prefer recording in the real game over an offline harness when chasing something the user heard.
- `audio_debug` draws the same in the world; `audio_stats` prints the rows.
- Examples: `addons/examples/lua/examples/render3d/audio_rooms.lua` (rooms against Eyring) and `audio_showcase.lua` (`audio_showcase <f1|canyon|flyover|wall|shelter|city>`). Keep debug markers out of the traced scene (`visual:SetInSceneBVH(false)`), or they occlude and reflect.
- In game, the `Sound test` weapon (`addons/game/lua/weapons/sound_test.lua`) plays `signals.Clap` and `signals.Boom`.

## Measuring

You cannot listen, so render offline and measure: swap `audio.state` for `audio.CreateMixerState()`, create `mix.CreateMixer(state, 44100, 512)`, point `mixer.clock` and `audio.clock` at a virtual time, then alternate `audio.Update()` (frame rate) and `mix.MixOutputBuffer` (block rate). See `with_offline_mixer` in `test/tests/other/audio_acoustics.lua`, which also has an analytic box tracer for checking the statistics against Eyring. The offline mixer makes the output stage transparent and zeroes turbulence, temperature gradient and wind coupling; set them back to test those.

- Delay: peak index of an impulse. Doppler and pitch jitter: per cycle zero crossings of a sine. Decay: Schroeder backward integration, T20 range.
- Per band decay: a narrow band pass at band centers. For steep spectra (air at 8 kHz and up) use a windowed STFT at the frequency and fit the level slope; filter skirts pick up louder lower frequencies and show a slower decay. Fit only over bins that have energy.
- Generated noisy sounds: measure band energies, not zero crossings.
- Calibrate the environment in controlled rooms (axis aligned boxes with per face materials, openings, a ground plane outdoors) against a source ray reference with a receiver sphere. Compare the reverberant energy and the direct window separately against the dry direct sound, and compare energy per time bin against the full direct burst.
- Write a 16 bit wav to hand the user something to listen to.
