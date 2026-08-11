# Linux full-F0 + GPIO97/98 MCLK SSC result

Date: 2026-08-11
Machine: ASUS Zenbook A14 UX3407RA / X1E80100
Kernel: `7.0.0-32-qcom-x1e`
Branch: `agent/aos-f0-ssc-handshake-probe`

## Result

The reversible GPIO97/98 MCLK discriminator completed successfully and produced a negative result.

Before the SSC attempt, Linux verified the observed baseline:

```text
pin 97 (GPIO_97): UNCLAIMED
pin 98 (GPIO_98): UNCLAIMED
97 (gpio97): input bias pull down ... drive strength (2 mA)
98 (gpio98): input bias pull down ... drive strength (2 mA)
```

The diagnostic then selected only GPIO97 and GPIO98 through the Linux pinctrl framework:

```text
pin 97 (GPIO_97): device a14-aos-f0-mclk-diag function cam_mclk group gpio97
pin 98 (GPIO_98): device a14-aos-f0-mclk-diag function cam_mclk group gpio98
97 (gpio97): input bias disabled, output drive strength (6 mA)
98 (gpio98): input bias disabled, output drive strength (6 mA)
mclk97_98_active_state=validated
gpio99_untouched=true
```

With that state held, the existing complete Stage-C owner state was established and the real SSC camera-handshake request was attempted without touching the CPAS ownership mux.

The handshake still timed out:

```text
AON-F0-ICP-OWNER-DIAG targets-ok hold-ms=4500 ... direct-mmio=false ssc-external-only=true
DIAGNOSTIC: attempting SSC handshake under external full-F0 hold; AON mux not switched
camera handshake ACK 832 timed out
presence activation failed: -110; recycling SSC client
```

Final classification:

```text
result=handshake-timeout-with-mclk97-98
handshake_runner_status=0
```

No kernel fault was detected.

## Cleanup validation

The full-F0 owner state released successfully. CAMSS and both CCI devices returned to runtime suspend.

GPIO97/98 were explicitly returned to the observed baseline state before the MCLK diagnostic module was unloaded:

```text
pin 97 (GPIO_97): device a14-aos-f0-mclk-diag function gpio group gpio97
pin 98 (GPIO_98): device a14-aos-f0-mclk-diag function gpio group gpio98
97 (gpio97): input bias pull down ... drive strength (2 mA)
98 (gpio98): input bias pull down ... drive strength (2 mA)
pin 97 (GPIO_97): UNCLAIMED
pin 98 (GPIO_98): UNCLAIMED
mclk97_98_restore=validated
```

Both cameras enumerated successfully after cleanup.

## Interpretation

This closes GPIO97/98 as the missing ordinary CAMP F0 prerequisite for the SSC camera-handshake on this ASUS machine.

GPIO99 should not be tested merely because it appears in the generic CAMP resource payload. Its Windows resource record is distinct from the MCLK group, while GPIO97/98 were the strongest unrepresented camera-MCLK candidates and changing them produced no effect on ACK 832.

The result joins the already-validated Stage-C evidence:

- CCI0/CCI1 at 37.5 MHz;
- CAMNOC RT/NRT at 300/300 MHz;
- CPAS/Core/Fast AHB at 80/80/100 MHz;
- ICP AHB/ICP at 80/400 MHz;
- CAMSS runtime PM / Titan-top genpd and normal camera ICC ownership;
- successful SSC QMI service discovery;
- successful discovery of all three SSC SUIDs;
- GPIO97/98 reproduced as `cam_mclk`, no-pull, 6 mA;
- no direct CPAS MMIO.

## CAMNOC 300 vs 400 MHz closure

A final offline check of the ASUS `CAMP_RES_QRD.bin` resolves the apparent discrepancy between the PoFx performance-state registration values and Stage-C's 300 MHz target.

Windows registers four performance states for each CAMNOC clock with values:

```text
400 MHz, 400 MHz, 400 MHz, 300 MHz
```

However, CAMP component F0 contains `PSTATE_ADJUST` entries selecting performance-state set 4, state 3 for `cam_cc_camnoc_axi_rt_clk`, and set 5, state 3 for `cam_cc_camnoc_axi_nrt_clk`. State 3 is the 300 MHz entry.

Therefore Stage C's 300/300 MHz CAMNOC targets match the CAMP F0 resource description. A 400 MHz retry is not justified by the Windows resource data.

## Next boundary

Do not repeat the full-F0/no-mux handshake with GPIO97/98 and do not escalate to GPIO99 without new machine-specific evidence.

The remaining boundary is the actual camera-platform ownership/protection transition that Windows performs after `PoFxActivateComponent(component 0)` and before SSC can control the AOS camera path.

The confirmed Windows control flow remains:

```text
PoFxActivateComponent(CAMP component 0)
  -> PlatformPowerState = ON
  -> write 0x101 to CPAS_TOP_CPAS_0_MAIN_CAM_AON_CAM_SEL_CTRL
  -> successful AOS route
```

No direct SCM/QSEE call is visible in `qccamplatform8380.sys`, but an additional PEP/platform protection effect cannot be excluded.

Direct CPAS `+0x1e0` access remains quarantined because prior Linux reads/writes caused abrupt resets. Any future hardware experiment involving that register must be isolated, write-only, have the validated complete F0 state active first, use persistent pre-write markers, perform no readback, and assume a cold power cycle may be required.
