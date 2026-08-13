# Plain-mainline X1E camera base

For Linux 7.1.5 on the ASUS Zenbook A14 UX3407RA, the source tree already contains the X1E80100 CAMCC driver/bindings, CAMSS driver/binding, and Qualcomm CCI driver, but does not contain the external X1E CSI2 PHY implementation or the Hamoa camera nodes.

The pinned integration chain for the first 7.1.5 backport is:

1. `20260708-x1e-csi2-phy-v9-0-0210b90c04cf@linaro.org` — Qualcomm X1E CSI2 PHY v9, patches 1-2.
2. `20260708-b4-linux-next-25-03-13-dtsi-x1e80100-camss-v12-0-f8588da41f16@linaro.org` — X1E CAMSS PHY-API v12.
3. `20260708-x1e-camss-csi2-phy-dtsi-v4-0-572348ad1b2a@linaro.org` — Hamoa camera DTSI v4, only generic patches 1-3 (CAMCC node, CCI nodes, CAMSS/CSI2-PHY block).
4. Apply this repository's A14-specific camera series under `kernel-patches/camera/`.
5. Apply AOS/HPD only after the normal camera stack builds and validates.

Do not require `include/dt-bindings/phy/phy-qcom-mipi-csi2.h` for this chain. The July v9 PHY design uses the media graph and its own PHY binding instead of the earlier mode-constant header used by older revisions.

Do not substitute Ubuntu downstream source as the canonical base. Downloaded source trees are disposable; this repository records the A14 integration and the exact upstream series used to construct it.
