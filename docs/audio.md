# Audio

Physically based by default: sound travels at `audio.speed_of_sound` through a delay line per voice, doppler is the derivative of that delay, and a traced environment drives occlusion, reflections and reverb. World units are meters.

## Mixer (`goluwa/audio/mix.lua`, audio thread)

- Block based. Each spatial voice writes its emitted mono signal (volume and pitch applied, source sample rate honored) into a history ring; the ears, the reflection taps and the reverb sends are fractional reads from that ring at their delays. Nothing else in the mixer knows about geometry.
- The main thread (`spatial.lua`, every Update) writes per path: delay, delay rate (seconds per second) and 3 band gains, stamped with `audio.clock()`. The mixer evaluates `delay + rate * (block_time - stamp)` and ramps across the block, so frame jitter and low update rates do not wobble the pitch. Delays use the retarded (emission time) source position; velocities are estimated from motion, there is no velocity API.
- `doppler_factor` scales the effective speed of sound (0 = instant, no doppler).
- Ears are `audio.ear_distance` apart: interaural time difference falls out of the per ear delays; head shadow is a band gain (`spatial.HeadShadow`).
- A voice's first block takes its send and tap gains at once instead of ramping in from silence; a transient that falls inside the ramp loses several dB of reverb.
- Stopping a spatial sound stops emission; what is already in flight still arrives (`slot.draining`). `Sound:Cut()` and `audio.StopAll()` cut hard.
- `Sound:SetSpatial(false)` for UI, music and anything not in the world: plays the buffer directly in stereo. Spatial sounds are downmixed to mono.
- `Sound:SetBandGains(Vec3(low, mid, high))` shapes what a spatial sound emits (direct path and reflections, not the reverb send). The shallow crossovers limit it to gentle tilts, about 10% accurate at the band centers; a steep cut next to a band at 1 bottoms out near -11 dB.
- `Sound:SetNormalized(true)` makes volume 1 play at `audio.reference_loudness` (LUFS at the reference distance): the gain comes from `Sound:GetLoudness()`, the loudest 400 ms of the buffer K-weighted (BS.1770 momentary, `dsp.MeasureLoudness`), measured once when the buffer is ready and capped at +30 dB. Normalize game sounds so their volumes compare: Source files of one kind differ by 20 dB or more. `GetMixVolume()` is what reaches the mixer. Short clicky files have a high crest factor, so normalized peaks can exceed 0 dBFS at volume 1; there is no limiter.
- 32 voices (`audio.SLOT_COUNT`). When all are busy, a new sound takes the voice of the quietest non-looping spatial sound at the listener (slot volume times its mid band ear gain) if it is louder there, otherwise it is dropped; loops are never taken, non-spatial sounds outrank everything.
- Two reverb buses (`dsp.ProcessReverb`, 16 line FDN with per line 3 band absorption, Hadamard feedback, input diffusion). A bus is normalized so a unit send gives an impulse response with energy 1 per channel in the mid band; sends carry the physical energy. Buses sleep when silent.
- A bus has a delay `scale` (line lengths times the scale, so echo spacing follows the space's mean free path: dense in rooms, distinct echoes outdoors) and a `diffusion` (input diffuser amount). The scale snaps to whole sample steps (interpolated reads would dull every pass) and glides between them at most 2% pitch.
- The FDN only reaches its envelope after its mean line delay (about 30 ms at scale 1, more at larger scales), so the diffused input is also emitted directly as a burst holding the energy share `1 - exp(-13.82 * onset / T60)`; without it short rooms lose their early reverb.
- In the feedback loop a small per pass gain error is a large T60 error. Line gains are fitted so the loop response at each band center equals its target (`dsp.FitBandGains`), and only shrunk when the true response peak (`dsp.BandGainPeak`) rings past 1.5 times the longest band. A loose bound instead (summing band differences) shortens long, uneven decays by half.
- Bands: crossovers at 500 Hz and 4 kHz (two cascaded one poles each), centers 250/1500/8000 Hz. Gains are given at the band centers and converted with `dsp.WarpBandGains`, otherwise the shallow crossovers leak neighbouring bands. They cannot make a steep step between bands (12 s mid next to 3 s high comes out around 8 s mid).

## Environment (`goluwa/audio/acoustics.lua`)

A tracer (`acoustics_gpu.lua`: ray queries on the scene TLAS in a PreRenderPass compute pass, results read back one swapchain cycle later; `acoustics_cpu.lua`: `physics.RayCast`, static bodies only) runs the same jobs. Pvar `audio_acoustics` = auto, gpu, cpu or off.

- Listener path tracing (Fibonacci directions, cosine bounces) accumulates statistics: hits, escapes, mean free path, log reflectance per band, first hit volume. T60 per band comes from per segment survival (escape counts as absorption, air absorption included), so it matches Eyring in closed rooms and drops outdoors.
- Statistics, per source sums and reflectors fade with time (`STATS_MEMORY`) and with how far the listener (or source) moved relative to the mean free path (`STATS_DISTANCE`), so standing still averages and walking through a door switches rooms within half a mean free path. Old stats from a closed room carry about 8 hits per ray against 1 or 2 outdoors, so time alone keeps them dominant for seconds.
- Next event estimation from every bounce to each source gives the reverberant energy at the listener relative to the direct sound at 1 m. Only energy arriving after the split time (`1.5 * mean free path / c`, also the bus predelay) feeds the reverb; first order diffuse energy is early, not tail. Energy past the last traced bounce is completed analytically with the per bounce survival.
- The listener bus scale is `mean free path / (c * dsp.REVERB_MEAN_DELAY)`; its diffusion falls from 1 at `DIFFUSE_ESCAPING` (10% of segments escaping) to 0 at `SPARSE_ESCAPING` (35%).
- A source whose energy centroid decays much slower than the listener's room (another space) sends to the second bus, which takes the energy weighted T60 of such sources.
- Direct occlusion samples 0.6 of the first Fresnel zone per band, so low frequencies bend around edges; fully blocked paths keep `acoustics.TRANSMISSION`.
- First hits are clustered into planes; image sources validated with two rays become reflection taps (early reflections, distinct echoes).
- New sounds are probed synchronously on Play (CPU physics) so a one-shot behind a wall does not start unoccluded; before NEE converges the send uses the diffuse field estimate (`acoustics.DiffuseEnergy`).
- Absorption is the render material param `AcousticAbsorption` (energy coefficients per band). Source materials get it from their surfaceprop class.
- Listener rays start `LISTENER_CLEARANCE` out (the player's own body); rays toward a source stop `SOURCE_CLEARANCE` short (the emitter's own mesh).

## Impacts, contacts and footsteps (`addons/game/lua/impacts.lua`)

- `impacts.Fire(entity, part, kind, hit, speed)` calls the `Impact` event with `{Entity, Part, Kind, Surface, Material, Other, Position, Normal, Speed}`: `hit` is a physics hit on `Other`, `Speed` the impact speed in m/s. Sounds listen to the event; whatever detects an impact only fires it. Kinds: `footstep`, `physics`.
- `Surface` is the material param `SurfaceType` of `physics.GetHitMaterial(hit)` (the hit polygon's or brush side's material, else the entity's model or first visual, also on a direct child). Source materials take the model's physics surfaceprop, else the vmt `$surfaceprop`, else keyword families; untyped is `default`. BSP collision polygons and brush sides carry their render materials only when rendering.
- Footsteps come from the foot IK ground rays. `source_pose` works in animation space (immune to slopes and render jitter): a foot lifts 4 cm above its stance height, and fires when it stops descending in the lower half of its swing; airborne arms both feet and the body's fall speed is the landing speed. Thresholds against a running minimum alone miss steps, because blends dip the ankle below the stance height. `eye_pose` fires when a step plants.
- Physics impacts come from the core `PhysicsImpact` event (see physics.md). `impacts.FirePhysics` turns one into an `Impact` per side, each with the surface of the other body, so a crate on concrete plays both the crate and the concrete. Static bodies get their surface from a short ray toward them from the contact (materials are per primitive there); dynamic bodies from their entity. A ragdoll part reports its character and limb (`Part` is the ragdoll group) and is flesh; collisions inside one character and character capsules are skipped (characters sound through their feet).
- Sliding and rolling come from the core `PhysicsContact` event. `impacts.FireContact` turns one into a `Contact` per side (`{Entity, Part, Other, Surface, Material, Position, Normal, Slip, Roll, Rolling}`), with the same skipping and surfaces as impacts; surfaces are resolved at most every 0.25 s per pair. `Rolling` is true on the side of the body that rolls, so its `Surface` is the ground it rolls on.
- `Impact` and `Contact` from physics carry `Mass`, the reduced mass of the two bodies (a static side counts as infinite), so a can and a barrel at the same speed differ.
- `lua/sounds.lua` creates every game sound normalized with a 2 m reference distance (`sounds.CreateSource`) and drops a play whose level at the listener (`sounds.GetLevel`: volume over distance past the reference) is under -45 dB; there is no fixed range, loud events carry further.
- `autorun/audio/footsteps.lua` and `autorun/audio/physics_sounds.lua` map surface names to wav sets in hardcoded tables (Source names; an unknown name falls back to its prefix before `_`). Levels are dB relative to the reference loudness: footsteps sit at `LEVEL` (-20) plus a per surface offset, scaled by foot speed; impacts by speed, mass (6 dB per tenfold mass around 20 kg) and a per material offset; scrapes, rolls and grains a fixed amount below impacts. Impacts pick a hard or soft set by speed and are rate limited per pair. Contacts drive looping voices per pair and layer that fade in and out (at most 8, the quietest at the listener is replaced):
  - slip plays the smooth or rough scrape loop of the touched surface;
  - rolling has two layers, the ground's smooth scrape loop pitched and brightened (`BandGains`) with speed on the roller's side, and the roller's own sound on the ground's side: its roll loop where Source has one (canisters, barrels, cans, grenades), else its soft impact samples as grains every 0.3 m rolled.

## Debugging

`perf audio` (or `h`, AUDIO tab, `addons/debug/lua/autorun/render_3d/audio_acoustics.lua`) shows what the system thinks the listener is in: tracer and cost, the listener room (T60 per band, volume, mean free path, escaping rays, predelay), every spatial sound (delay, doppler, direct level and occlusion, reverb send and which bus, reflections), a top down map of first hits, reflecting planes, reflection paths and direct paths, and the decay curves. `audio_debug` draws the same in the world; `audio_stats` prints the rows.

## Measuring

You cannot listen, so render offline and measure: swap `audio.state` for `audio.CreateMixerState()`, create `mix.CreateMixer(state, 44100, 512)`, point `mixer.clock` and `audio.clock` at a virtual time, then alternate `audio.Update()` (frame rate) and `mix.MixOutputBuffer` (block rate). See `test/tests/other/audio_acoustics.lua`, which also has an analytic box tracer for checking the statistics against Eyring.

- Delay: peak index of an impulse. Doppler: zero crossings of a sine. Decay: Schroeder backward integration, T20 range.
- Measure per band decay with a narrow band pass at the band centers; a wide band's late tail is dominated by its slowest frequencies.
- Write a 16 bit wav to hand the user something to listen to.
- `goluwa/audio/signals.lua` builds deterministic test signals: `Clap` (a hand clap, broad peak around 1.5 kHz, 10 ms) and `Boom` (40 to 90 Hz, about 1 s). In game the `Sound test` weapon (slot 9) plays them, clap on primary and boom on secondary, at -6 and +6 dB on the game's level scale.
