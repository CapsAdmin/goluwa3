# Audio

Physically based by default: sound travels at `audio.speed_of_sound` through a delay line per voice, doppler is the derivative of that delay, and a traced environment drives occlusion, reflections and reverb. World units are meters.

## Mixer (`goluwa/audio/mix.lua`, audio thread)

- Block based. Each spatial voice writes its emitted mono signal (volume and pitch applied, source sample rate honored) into a history ring; the ears, the reflection taps and the reverb sends are fractional reads from that ring at their delays. Nothing else in the mixer knows about geometry.
- The main thread (`spatial.lua`, every Update) writes per path: delay, delay rate (seconds per second) and 3 band gains, stamped with `audio.clock()`. The mixer evaluates `delay + rate * (block_time - stamp)` and ramps across the block, so frame jitter and low update rates do not wobble the pitch. Delays use the retarded (emission time) source position; velocities are estimated from motion, there is no velocity API.
- `doppler_factor` scales the effective speed of sound (0 = instant, no doppler).
- Ears are `audio.ear_distance` apart: interaural time difference falls out of the per ear delays; head shadow is a band gain (`spatial.HeadShadow`).
- Stopping a spatial sound stops emission; what is already in flight still arrives (`slot.draining`). `Sound:Cut()` and `audio.StopAll()` cut hard.
- `Sound:SetSpatial(false)` for UI, music and anything not in the world: plays the buffer directly in stereo. Spatial sounds are downmixed to mono.
- Two reverb buses (`dsp.ProcessReverb`, 16 line FDN with per line 3 band absorption, Hadamard feedback, input diffusion). A bus is normalized so a unit send gives an impulse response with energy 1 per channel; sends carry the physical energy. Buses sleep when silent.
- Bands: crossovers at 500 Hz and 4 kHz (two cascaded one poles each), centers 250/1500/8000 Hz. Gains are given at the band centers and converted with `dsp.WarpBandGains`, otherwise the shallow crossovers leak neighbouring bands.

## Environment (`goluwa/audio/acoustics.lua`)

A tracer (`acoustics_gpu.lua`: ray queries on the scene TLAS in a PreRenderPass compute pass, results read back one swapchain cycle later; `acoustics_cpu.lua`: `physics.RayCast`, static bodies only) runs the same jobs. Pvar `audio_acoustics` = auto, gpu, cpu or off.

- Listener path tracing (Fibonacci directions, cosine bounces) accumulates statistics: hits, escapes, mean free path, log reflectance per band, first hit volume. T60 per band comes from per segment survival (escape counts as absorption, air absorption included), so it matches Eyring in closed rooms and drops outdoors.
- Next event estimation from every bounce to each source gives the reverberant energy at the listener relative to the direct sound at 1 m. Only energy arriving after the split time (`1.5 * mean free path / c`, also the bus predelay) feeds the reverb; first order diffuse energy is early, not tail. Energy past the last traced bounce is completed analytically with the per bounce survival.
- A source whose energy centroid decays much slower than the listener's room (another space) sends to the second bus, which takes the energy weighted T60 of such sources.
- Direct occlusion samples 0.6 of the first Fresnel zone per band, so low frequencies bend around edges; fully blocked paths keep `acoustics.TRANSMISSION`.
- First hits are clustered into planes; image sources validated with two rays become reflection taps (early reflections, distinct echoes).
- New sounds are probed synchronously on Play (CPU physics) so a one-shot behind a wall does not start unoccluded; before NEE converges the send uses the diffuse field estimate (`acoustics.DiffuseEnergy`).
- Absorption is the render material param `AcousticAbsorption` (energy coefficients per band). Source materials get it from their surfaceprop class.
- Listener rays start `LISTENER_CLEARANCE` out (the player's own body); rays toward a source stop `SOURCE_CLEARANCE` short (the emitter's own mesh).

## Debugging

`perf audio` (or `h`, AUDIO tab, `addons/debug/lua/autorun/render_3d/audio_acoustics.lua`) shows what the system thinks the listener is in: tracer and cost, the listener room (T60 per band, volume, mean free path, escaping rays, predelay), every spatial sound (delay, doppler, direct level and occlusion, reverb send and which bus, reflections), a top down map of first hits, reflecting planes, reflection paths and direct paths, and the decay curves. `audio_debug` draws the same in the world; `audio_stats` prints the rows.

## Measuring

You cannot listen, so render offline and measure: swap `audio.state` for `audio.CreateMixerState()`, create `mix.CreateMixer(state, 44100, 512)`, point `mixer.clock` and `audio.clock` at a virtual time, then alternate `audio.Update()` (frame rate) and `mix.MixOutputBuffer` (block rate). See `test/tests/other/audio_acoustics.lua`, which also has an analytic box tracer for checking the statistics against Eyring.

- Delay: peak index of an impulse. Doppler: zero crossings of a sine. Decay: Schroeder backward integration, T20 range.
- Measure per band decay with a narrow band pass at the band centers; a wide band's late tail is dominated by its slowest frequencies.
- Write a 16 bit wav to hand the user something to listen to.
