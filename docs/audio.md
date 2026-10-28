# Audio

Physically based by default: sound travels at `audio.speed_of_sound` through a delay line per voice, and doppler is the derivative of that delay. World units are meters.

## Mixer (`goluwa/audio/mix.lua`, audio thread)

- Block based. Each spatial voice writes its emitted mono signal (volume and pitch applied, source sample rate honored) into a history ring; the ears, the reflection taps and the reverb sends are fractional reads from that ring at their delays. Nothing else in the mixer knows about geometry.
- The main thread (`spatial.lua`, every Update) writes per path: delay, delay rate (seconds per second) and 3 band gains, stamped with `audio.clock()`. The mixer evaluates `delay + rate * (block_time - stamp)` and ramps across the block, so frame jitter and low update rates do not wobble the pitch. Delays use the retarded (emission time) source position; velocities are estimated from motion, there is no velocity API.
- `doppler_factor` scales the effective speed of sound (0 = instant, no doppler).
- Ears are `audio.ear_distance` apart: interaural time difference falls out of the per ear delays; head shadow is a band gain (`spatial.HeadShadow`).
- Stopping a spatial sound stops emission; what is already in flight still arrives (`slot.draining`). `Sound:Cut()` and `audio.StopAll()` cut hard.
- `Sound:SetSpatial(false)` for UI, music and anything not in the world: plays the buffer directly in stereo. Spatial sounds are downmixed to mono.
- Two reverb buses (`dsp.ProcessReverb`, 16 line FDN with per line 3 band absorption, Hadamard feedback, input diffusion). A bus is normalized so a unit send gives an impulse response with energy 1 per channel; sends carry the physical energy. Buses sleep when silent.
- Bands: crossovers at 500 Hz and 4 kHz (two cascaded one poles each), centers 250/1500/8000 Hz. Gains are given at the band centers and converted with `dsp.WarpBandGains`, otherwise the shallow crossovers leak neighbouring bands.

## Measuring

You cannot listen, so render offline and measure: swap `audio.state` for `audio.CreateMixerState()`, create `mix.CreateMixer(state, 44100, 512)`, point `mixer.clock` and `audio.clock` at a virtual time, then alternate `audio.Update()` (frame rate) and `mix.MixOutputBuffer` (block rate). See `test/tests/other/audio_acoustics.lua`.

- Delay: peak index of an impulse. Doppler: zero crossings of a sine. Decay: Schroeder backward integration, T20 range.
- Measure per band decay with a narrow band pass at the band centers; a wide band's late tail is dominated by its slowest frequencies.
- Write a 16 bit wav to hand the user something to listen to.
