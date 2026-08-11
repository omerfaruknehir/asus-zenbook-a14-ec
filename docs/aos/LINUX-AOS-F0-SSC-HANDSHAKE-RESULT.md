# Linux full-F0 SSC handshake result

Date: 2026-08-11
Machine: ASUS Zenbook A14 UX3407RA / X1E80100
Kernel: 7.0.0-32-qcom-x1e
Branch: `agent/aos-f0-ssc-handshake-probe`

## Result

The isolated full-F0/no-mux discriminator completed its actual hardware test.
SSC QMI service discovery and all three relevant SUID lookups succeeded, the
complete Stage-C owner state was established, and the real camera-handshake INIT
576 was sent while that state remained held.

The expected handshake ACK 832 did not arrive within the three-second driver
timeout:

```text
AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=4500 ... direct-mmio=false ssc-external-only=true
DIAGNOSTIC: attempting SSC handshake under external full-F0 hold; AON mux not switched
camera handshake ACK 832 timed out
presence activation failed: -110; recycling SSC client
```

The discriminator outcome is therefore:

```text
handshake-timeout-full-f0-no-mux
```

## Timing

Relevant monotonic timestamps from the test:

```text
76.644628  full F0 targets established
77.172121  SSC handshake attempt starts
80.224222  ACK 832 timeout
81.376147  Stage-C cleanup/restore begins
```

The complete F0 owner state therefore remained active for the entire handshake
attempt. The timeout cannot be explained by the 4.5-second diagnostic hold
expiring before SSC answered.

## What succeeded

Before the handshake:

- CAMSS diagnostic ready;
- no AP streams active;
- CCI0 = 37.5 MHz;
- CCI1 = 37.5 MHz;
- CAMNOC RT/NRT = 300/300 MHz;
- CPAS/Core/Fast AHB = 80/80/100 MHz;
- ICP AHB = 80 MHz;
- ICP = 400 MHz;
- `camera_handshake` SUID discovered;
- `human_presence_detect` SUID discovered;
- `camera_face_detect` SUID discovered;
- no CPAS ownership-mux access occurred.

The Stage-C cleanup also completed with `ret=0`. ICP and CCI state restored
successfully. The known CAMNOC 19.2 -> 240 MHz restore limitation remained the
same as in earlier Stage-C testing.

## Interpretation

This closes the hypothesis that the missing handshake ACK is caused solely by
one of the named Windows CAMP F0 clock/rate prerequisites already represented by
the Stage-C owner model.

The result does **not** by itself prove that the literal CPAS mux write is the
only remaining prerequisite. It does, however, move the boundary to the
ownership/protection transition that Windows performs after CAMP component F0
activation.

The existing Windows static/runtime evidence remains consistent with this:

```text
PoFxActivateComponent(CAMP component 0)
  -> PlatformPowerState = ON
  -> write 0x101 to CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL
  -> successful route-to-AOS
```

Linux reproduced the F0 resource state but deliberately omitted that ownership
transition, and SSC did not acknowledge camera control.

## False fault report in runner

The runner ended with:

```text
ERROR: kernel fault marker detected during discriminator
```

This was a diagnostic-script false positive, not a kernel fault. The captured
log included normal boot-time watchdog lines such as:

```text
watchdog: NMI not fully supported
watchdog: Hard watchdog permanently disabled
sbsa-gwdt ... Initialized ...
```

The old fault regex treated any occurrence of the word `watchdog` as a failure.
There was no panic, SError, Oops, call trace or watchdog lockup associated with
the AOS experiment.

## Next boundary

Do not repeat the same full-F0/no-mux handshake test; it has answered its
question.

The next work should distinguish between:

1. the CPAS ownership mux store itself becoming safe once the complete F0 owner
   state is active; and
2. an additional Windows PEP/platform protection transition that is not
   represented by the current Linux owner model and is required before the CPAS
   window is safely accessible.

A direct CPAS read remains unjustified. Any future MMIO experiment must be a
single isolated write-only operation in a one-shot boot, with the complete
validated F0 state already active, persistent pre-write markers, and no
readback. A safer offline/Windows PEP analysis should be preferred first if it
can resolve the remaining protection dependency without another reset-risking
hardware access.
