# Linux full-F0 SSC handshake discriminator

This diagnostic is the next presence-sensing experiment after the X1E80100
Stage-C full-F0 owner hold succeeded twice.

It does **not** change the EC fan/profile driver and does **not** retry the
quarantined CPAS ownership register.

## Question

The Linux SSC client can already connect to QMI service 400 and discover the
machine's `camera_handshake`, `human_presence_detect`, and
`camera_face_detect` SUIDs. Normal HPD activation then stops at the CAMSS AON
ownership provider because direct access to `MAIN_CAM_AON_CAM_SEL_CTRL` reset
the platform in earlier experiments.

Stage C subsequently proved that Linux can represent and hold the named Windows
CAMP F0 resource state through legitimate owners:

- CCI0 / CCI1: 37.5 MHz;
- CAMNOC RT / NRT: 300 / 300 MHz;
- CPAS / Core / Fast AHB: 80 / 80 / 100 MHz;
- ICP AHB / ICP: 80 / 400 MHz;
- normal CAMSS runtime PM, genpd and ICC ownership.

The discriminator asks one narrow question:

> While that complete owner state is active, will SSC acknowledge the real
> camera-handshake INIT 576 even if Linux does not touch the CPAS ownership
> mux?

## Interpretation

### ACK 832 with `error_state=0`

This would prove that the SSC camera handshake can progress under the complete
F0 state without a Linux CPAS mux write. The next step would be to validate the
HPD configuration/event stream while keeping the same fail-safe ownership
boundary.

### ACK timeout or rejection

This would isolate the missing prerequisite more strongly to a genuine
ownership/protection transition rather than another named F0 clock, rail,
interconnect, CCI, or ICP resource. Work should then stay focused on the Windows
PEP/security/ownership path; raw CPAS access still must not be retried.

## Safety model

The diagnostic is intentionally split across independent gates:

1. a dedicated branch build defines `A14_SSC_UNROUTED_HANDSHAKE_DIAG`;
2. the HPD module still requires the root-only module parameter
   `allow_unrouted_handshake_probe=1`;
3. the CAMSS Stage-C owner diagnostic must be present in an isolated test boot;
4. the runner requires all CAMSS/CCI owners idle before starting;
5. the full-F0 hold is bounded to 3.5–5.0 seconds for this test;
6. the HPD client is torn down before the owner hold is released;
7. the test verifies owner runtime suspend and camera enumeration afterward.

The diagnostic bypass does not set `camss_aon_owned`, so its cleanup path cannot
pretend that the camera mux was switched.

## Explicitly prohibited

- no `/dev/mem`;
- no CPAS `readl` / `writel`;
- no raw `ioremap` of the ownership window;
- no guessed SCM/QSEE replacement;
- no direct GPIO or RPMh manipulation;
- no persistent production bypass;
- no automatic HPD activation at boot.

Production `qcom_camss_aon_acquire()` remains fail-closed.

## Build and install

From the repository on the A14:

```bash
git fetch origin
git switch agent/aos-f0-ssc-handshake-probe

bash ./scripts/a14-aos-f0-ssc-handshake-build.sh

stage="$HOME/Downloads/a14-aos-f0-icp-owner-diag-$(uname -r)/ssc-handshake-artifacts"
A14_AOS_F0_ICP_OWNER_STAGE="$stage" \
  bash ./scripts/a14-aos-f0-icp-owner-diag-install-test.sh
```

The existing Stage-C installer creates a non-default one-shot GRUB entry. It
still does not put the HPD probe module into initramfs and does not activate SSC.

Boot the isolated entry:

```bash
sudo grub-reboot a14-f0-icp-owner-test
sudo reboot
```

## Run

After the isolated boot returns:

```bash
cd ~/Downloads/asus-zenbook-a14-ec
bash ./scripts/a14-aos-f0-ssc-handshake-run.sh
```

The concise result is written to:

```text
~/Downloads/a14-aos-f0-ssc-handshake-report.txt
~/Downloads/a14-aos-f0-ssc-handshake-kernel.log
~/Downloads/a14-aos-f0-ssc-handshake-last-run.txt
```

The important final discriminator is one of:

```text
discriminator_result=handshake-ack-with-full-f0-no-mux
discriminator_result=handshake-timeout-full-f0-no-mux
discriminator_result=handshake-rejected-full-f0-no-mux
```
