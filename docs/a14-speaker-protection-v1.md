# ASUS Zenbook A14 speaker protection — V1

Target: ASUS Zenbook A14 UX3407RA / X1E80100 / two WSA8845 (WSA884x) smart amps.

## Why this exists

Linux v7.1.5 intentionally limits X1E80100 speakers to:

- `WSA WSA_RX0/1 Digital Volume <= 81` (`-3 dB`)
- `SpkrLeft/Right PA Volume <= 6` (`0 dB`)

in `sound/soc/qcom/x1e80100.c`.  The upstream comment says this is to reduce the
risk of speaker damage until active speaker protection is available.

Windows can operate louder because its Qualcomm/OEM audio stack uses additional
speaker-protection and tuning logic.  Raising Linux mixer limits without
reconstructing that protection is not an acceptable fix.

## V1 scope

V1 adds only the physical WSA884x voltage/current-sense transport needed by a
future AudioReach SP/SPVI protection graph.

The A14 device tree already gives us the key hardware mapping:

- left WSA8845: `qcom,port-mapping = <1 2 3 7 10 13>`
- right WSA8845: `qcom,port-mapping = <4 5 6 7 11 13>`

Therefore the two VISENSE paths use SoundWire master ports 10 and 11.

V1 adds a render-coupled backend:

```
left/right WSA8845 VISENSE
        |
        v
SoundWire source ports 10 / 11
        |
        v
SWR0 DIN0 (DAI 9)
        |
        v
LPASS WSA macro AIF_VI
        |
        v
WSA_CODEC_DMA_TX_0
        |
        v
AudioReach
```

Format: **8 kHz, S32_LE, 2 channels**.

## Hard V1 safety invariant

The transform and build script both fail if the upstream gain-limit statements
are no longer present.  A V1 kernel must still expose:

```
WSA digital max = 81  (-3 dB)
WSA PA max      = 6   ( 0 dB)
```

No Surface/other-machine PA operating point or calibration is imported.

## Runtime routing

The generic X1E UCM profile leaves WSA884x VISENSE disabled.  For a transport
test, enable the two physical VISENSE sources and the two WSA-macro VI mixer
channels before reopening speaker playback:

```bash
amixer -c 0 cset "name='SpkrLeft VISENSE Switch'" 1
amixer -c 0 cset "name='SpkrRight VISENSE Switch'" 1
amixer -c 0 cset "name='WSA WSA_AIF_VI Mixer WSA_SPKR_VI_1'" 1
amixer -c 0 cset "name='WSA WSA_AIF_VI Mixer WSA_SPKR_VI_2'" 1
```

These controls enable feedback routing; they do not raise speaker gain.

## V1 success criterion

V1 is successful only when speaker rendering causes both WSA8845 VISENSE
sources and WSA TX0 to prepare as one stable 8 kHz/S32 two-channel feedback
transport, with no SoundWire bus clash and with the upstream gain caps still
present.

A successful V1 transport is **not** proof that the DSP is actively protecting
the speakers.  It only clears the physical-feedback prerequisite.

## Next stage: SP/SPVI

After V1 is proven, the next stage is an A14-specific AudioReach protected
speaker graph containing Qualcomm speaker-protection render (`SP`) and
voltage/current feedback (`SPVI`) modules.  That stage needs A14-specific
calibration/tuning evidence.  Calibration and safe gain values from another
X1E laptop must not be copied to the A14.
