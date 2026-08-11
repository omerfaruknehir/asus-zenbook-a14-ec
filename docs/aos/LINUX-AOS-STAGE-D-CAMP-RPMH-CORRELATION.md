# Stage D CAMP RPMh / Linux framework correlation

This note records the corrected interpretation of the focused Windows CAMP
activation trace and the Linux X1E80100 Command DB audit. It supersedes the
earlier provisional interpretations that (a) CAMCC device-level
`required-opps` might be ignored and (b) the CAMP ICB burst only partially
matched Linux camera-path BCMs.

## Safety boundary

Nothing in this note authorizes direct CPAS access.

- no `/dev/mem`;
- no raw CPAS `ioremap`;
- no diagnostic `readl` / `writel` of the ownership mux;
- no guessed SCM replacement;
- no SSC INIT 576;
- production AOS acquire remains fail-closed before ownership access.

## 1. CAMCC MXC/MMCX `required-opps` are handled by genpd

The live X1E80100 CAMCC node has two RPMh parent domains:

- MXC, required OPP `64` (`LOW_SVS`);
- MMCX, required OPP `64` (`LOW_SVS`).

This directly matches the Windows CAMP `/arc/client/rail_mmcx = 0x40` resource
class.

The earlier concern that Qualcomm's common clock probe attaches the two parent
power domains without `PD_FLAG_REQUIRED_OPP` was based on the wrong generic-OPP
path. Linux v7.0 has a separate device-level `required-opps` path in genpd.
During `__genpd_dev_pm_attach()` it calls `genpd_set_required_opp(dev, index)`
for each attached PM-domain virtual device. The resulting performance state is
the attached domain's default state. Runtime suspend drops that vote to zero;
runtime resume restores it before the provider is powered for use.

Therefore an idle CAMCC virtual genpd client showing `performance=0` is expected
and is not evidence that the LOW_SVS dependency is missing.

Conclusion: the Windows CAMP MMCX ARC vote is represented by Linux's existing
CAMCC/genpd topology. No new direct rail-control diagnostic is justified.

## 2. Exact focused Windows CAMP ICB sequence

For the sustained CAMP component-0 activation:

```text
08:54:25.6813981  CAMP PowerRequired=true
08:54:25.6816451  vdd_arc_hlos begins
08:54:25.6817301  first ICB TCS group begins
08:54:25.6819198  vdd_arc_hlos completion/result
08:54:25.6819363  CAMP Active=true
```

Linux v7.0's `enum rpmh_state` defines:

```text
0 = RPMH_SLEEP_STATE
1 = RPMH_WAKE_ONLY_STATE
2 = RPMH_ACTIVE_ONLY_STATE
```

The private qcpep raw packet inside this interval decodes as follows.

### State 0 / sleep batch

One five-command ICB request:

```text
0x50000  MC0
0x50008  SH1
0x50004  SH0
0x50028  MM1
0x50068  ACV
```

The Linux Command DB resolves all five names exactly. These are normal BCM
resources on the camera-to-memory fabric: MM1 covers camera/MNOC traffic,
SH1/SH0 cover the GEM/LLCC portion, and MC0/ACV cover the memory-controller
tail.

`MM0` is also a Linux camera-path BCM (`0x50024`) but did not need to appear in
this particular Windows command group. Command DB address absence from one RPMh
transaction does not imply absence from the topology; BCM voters only emit
resources whose aggregate state needs updating, and other clients can already
hold a shared BCM.

### State 2 / active-only aggregate updates

The trace then emits individual active-only commands for:

```text
0x50000  MC0
0x50004  SH0
0x5000c  PC0
0x50010  SN0
0x50068  ACV
```

### State 1 / wake-only aggregate updates

The same address set is then mirrored for wake-only state.

The Linux Command DB identifies the two names that caused the earlier
"partial" report:

- `PC0` -> PCIe-memory BCM (`qns_pcie_mem_noc`);
- `SN0` -> system-NoC SF BCM (`qns_gemnoc_sf`).

They are valid X1E BCMs, but they are not camera-route dependencies. Qualcomm's
RPMh/ICC voter can flush multiple dirty aggregate BCM states in the same short
TCS activity window; their temporal proximity to CAMP activation is therefore
not evidence that CAMP requires PCIe or system-NoC resources.

## 3. Linux ICC comparison

The X1E CAMSS DT already exposes four ICC paths:

- `ahb`;
- `hf_mnoc`;
- `sf_mnoc`;
- `sf_icp_mnoc`.

The three data paths originate at the X1E camera MNOC masters and terminate at
memory. Linux's X1E interconnect provider represents their shared BCM chain,
including MM1/MM0, SH1/SH0 and MC0/ACV. CAMSS runtime PM issues framework ICC
bandwidth requests on these existing paths; Stage C retained CAMSS runtime PM
while reproducing the named CAMP F0 clock state.

The focused Windows state-0 camera ICB group therefore does not reveal a new
unrepresented bus resource.

## 4. Remaining Windows CLOCK aliases are already represented by Linux

The A14-selected `CAMP_RES_QRD.bin` encodes three previously unmatched F0 names
as `CLOCK` resources with enable value `1`:

```text
gcc_camera_xo_clk
gcc_camera_ahb_clk
cam_cc_gdsc_clk
```

They were absent from the earlier Linux `clk_summary` name search, but source
inspection shows why.

### GCC camera AHB/XO

The X1E GCC binding contains `GCC_CAMERA_AHB_CLK` and `GCC_CAMERA_XO_CLK`, but
the driver intentionally does not expose normal `clk_branch` objects for them.
Instead GCC probe forces both hardware branches on directly:

```c
qcom_branch_set_clk_en(regmap, 0x26004); /* GCC_CAMERA_AHB_CLK */
qcom_branch_set_clk_en(regmap, 0x26028); /* GCC_CAMERA_XO_CLK */
```

Therefore `clk_summary` reporting `gcc_camera_ahb_clk` / `gcc_camera_xo_clk` as
not found was expected. The corresponding X1E hardware gates are provider-owned
and kept enabled by Linux independently of a CAMSS consumer clock request.

### CAM_CC_GDSC_CLK

The X1E CAMCC binding defines `CAM_CC_GDSC_CLK`. The driver does not register it
as a normal consumer-visible clock either; it places its CBCR (`0x13a9c`) in the
provider's critical CBCR list:

```c
static u32 cam_cc_x1e80100_critical_cbcrs[] = {
        0x13a9c, /* CAM_CC_GDSC_CLK */
        0x13ab8, /* CAM_CC_SLEEP_CLK */
};
```

Qualcomm common-clock probe processes that list through
`qcom_cc_clk_regs_configure()`, which calls `qcom_branch_set_clk_en()` for every
critical CBCR before GDSC/clock registration. Thus `cam_cc_gdsc_clk` is also a
provider-owned always-enabled prerequisite rather than a missing CAMSS clock.

The actual `cam_cc_titan_top_gdsc` is separately modeled as a Linux genpd object
and was already part of the Stage C framework-managed power-domain path.

Conclusion: the three previously unmatched Windows F0 `CLOCK` names do not
identify omitted Linux clock gates.

## 5. Revised Stage D conclusion

The strongest named resource classes observed or reconstructed for Windows
`PoFxActivateComponent(CAMP)` are now accounted for by Linux framework/provider
state:

1. `vdd_arc_hlos` / MMCX LOW_SVS: CAMCC MXC/MMCX genpd `required-opps`;
2. camera ICB/BCM activity: X1E CAMSS ICC paths and Command DB BCM resources;
3. `gcc_camera_ahb_clk`: X1E GCC provider-forced always-on branch;
4. `gcc_camera_xo_clk`: X1E GCC provider-forced always-on branch;
5. `cam_cc_gdsc_clk`: X1E CAMCC critical CBCR forced on by common-clock probe;
6. `cam_cc_titan_top_gdsc`: Linux CAMCC genpd object;
7. the directly named CAMNOC/CPAS/Core/GCC HF/SF clocks and CCI/ICP resources:
   explicitly reproduced by the Stage C full-F0 owner diagnostic.

This substantially exhausts the hypothesis that the retired direct Linux CPAS
access reset merely because a named CAMP F0 clock, rail, power-domain or camera
bandwidth resource was missing.

The unresolved classes are now narrower:

- a PEP-internal ownership/protection transition not represented by ordinary
  clock/genpd/ICC state;
- platform firewall/XPU/security state established elsewhere in the Windows
  dependency graph;
- host-access semantics for the CPAS ownership window that differ from merely
  having its resources powered;
- another dependency not represented in the reconstructed CAMP F0 resource
  graph or the captured qcpep RPMh classes.

None of those classes should be tested by retrying raw CPAS access. The next
step must remain evidence-first and framework-owned/read-only unless a concrete
new dependency is identified.
