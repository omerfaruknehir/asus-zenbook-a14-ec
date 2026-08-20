#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Stage the first real X1E80100 GPU clock/power hardware layer on A14 ACPI.

Prerequisites already proven on this machine:
  * QCOM0C36 ACPI platform enumeration
  * QCOM0C36 IORT path normalization
  * GPU IORT inputs 0x03030000/0x03030020 and GMU 0x03030060
  * no-MMIO GPU/GMU/GPUCC topology bridge
  * GPUCC child resource 0x03d90000 + 0xa000 is inside firmware GFX_REGS

This layer deliberately does NOT bind GMU or Adreno.  It makes the existing
X1E80100 GPUCC driver usable by the synthetic ACPI GPUCC child, supplies its
three external input clocks, registers the stock GPUCC clocks/resets/GDSCs,
and skips only OF-provider publication when no OF node exists.

The two GCC GPU parent clocks are real MMIO-backed gates at the native X1E80100
GCC register 0x52000 (physical 0x00152000), bits 15 and 16.  Their parent rates
are the fixed X1E80100 GPLL0 topology also measured on this exact machine under
the known-good DT kernel: 600 MHz main and 300 MHz /2.  bi_tcxo_div2 is 19.2 MHz.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_X1E80100_GPUCC_ACPI_HW_V1"
COMMON_MARKER = "A14_QCOM_CC_NON_OF_PROVIDER_V1"
GDSC_MARKER = "A14_GDSC_NON_OF_PROVIDER_V1"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPUCC hardware transform: {msg}")


def kernel_version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    return ".".join(vals.get(k, "?") for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"{label}=current")
        return
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected one anchor in {path}, found {count}")
    path.write_text(text.replace(old, new, 1))
    print(f"{label}=applied")


def replace_all(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if old not in text:
        if new in text:
            print(f"{label}=current")
            return
        fail(f"{label}: neither old nor new form found in {path}")
    count = text.count(old)
    path.write_text(text.replace(old, new))
    print(f"{label}=applied count={count}")


def verify_prereqs(root: Path) -> None:
    req = {
        root / "drivers/acpi/scan.c": ["A14_QCOM0C36_PLATFORM_ENUM_V1"],
        root / "drivers/acpi/arm64/iort.c": [
            "A14_IORT_NCOMP_NO_TRAILING_V1",
            "A14_IORT_NCOMP_MULTI_ID_INIT_ONCE_V1",
        ],
        root / "drivers/gpu/drm/msm/msm_drv.c": [
            "A14_QCOM0C36_TOPOLOGY_V3",
            'DEFINE_RES_MEM_NAMED(0x03d90000, 0x0000a000, "gpucc")',
            '"a14-gpucc-x1e80100-acpi-topology"',
        ],
        root / "drivers/pinctrl/qcom/pinctrl-msm.c": ["A14_GIO0_SAFE_REGISTRATION_V1"],
        root / "drivers/gpio/gpiolib-acpi-core.c": ["A14_QCOM_WOA_ACPI_GPIO_XLATE"],
        root / "drivers/firmware/qcom/qcom_scm.c": ["A14_QCOM_SCM_ACPI_QCOM04DD"],
    }
    for path, needles in req.items():
        if not path.is_file():
            fail(f"missing prerequisite source {path}")
        body = path.read_text()
        for needle in needles:
            if needle not in body:
                fail(f"working prerequisite missing from {path}: {needle}")


def verify(root: Path) -> None:
    gpucc = (root / "drivers/clk/qcom/gpucc-x1e80100.c").read_text()
    common = (root / "drivers/clk/qcom/common.c").read_text()
    gdsc = (root / "drivers/clk/qcom/gdsc.c").read_text()

    gpucc_req = [
        MARKER,
        '"a14-gpucc-x1e80100-acpi-topology"',
        "A14_GPUCC_GCC_GATE_PHYS",
        "0x00152000ULL",
        "A14_GPUCC_BI_TCXO_DIV2_RATE",
        "19200000UL",
        "A14_GPUCC_GPLL0_RATE",
        "600000000UL",
        '"a14_gcc_gpu_gpll0_cph_clk_src"',
        '"a14_gcc_gpu_gpll0_div_cph_clk_src"',
        "devm_clk_hw_register_gate_parent_hw",
        "device_create_managed_software_node",
        "A14GPUCC: READY",
    ]
    for x in gpucc_req:
        if x not in gpucc:
            fail(f"GPUCC verification missing: {x}")

    # Every external X1E80100 GPUCC parent must retain its DT index while also
    # gaining a global-name fallback for the no-OF ACPI path.
    if '.index = DT_BI_TCXO, .name = "a14_gpucc_bi_tcxo_div2"' not in gpucc:
        fail("BI_TCXO parent fallback missing")
    if '.index = DT_GPLL0_OUT_MAIN, .name = "a14_gcc_gpu_gpll0_cph_clk_src"' not in gpucc:
        fail("GPLL0 main parent fallback missing")
    if '.index = DT_GPLL0_OUT_MAIN_DIV, .name = "a14_gcc_gpu_gpll0_div_cph_clk_src"' not in gpucc:
        fail("GPLL0 div parent fallback missing")

    common_req = [
        COMMON_MARKER,
        "reset->rcdev.dev = dev;",
        "if (dev->of_node)",
        "A14QCOMCC: non-OF clock registration",
    ]
    for x in common_req:
        if x not in common:
            fail(f"common.c verification missing: {x}")

    gdsc_req = [
        GDSC_MARKER,
        "A14GDSC: initialized",
        "if (!dev->of_node)",
    ]
    for x in gdsc_req:
        if x not in gdsc:
            fail(f"gdsc.c verification missing: {x}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpucc-hw-v1.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = kernel_version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    verify_prereqs(root)

    gpucc = root / "drivers/clk/qcom/gpucc-x1e80100.c"
    common = root / "drivers/clk/qcom/common.c"
    gdsc = root / "drivers/clk/qcom/gdsc.c"
    for path in (gpucc, common, gdsc):
        if not path.is_file():
            fail(f"missing {path}")

    # GPUCC needs MMIO for the two native GCC branch gates and a managed
    # software-node fwnode so the reset framework can identify the provider.
    replace_once(
        gpucc,
        '#include <linux/clk-provider.h>\n#include <linux/mod_devicetable.h>\n',
        '#include <linux/clk-provider.h>\n#include <linux/io.h>\n#include <linux/mod_devicetable.h>\n#include <linux/property.h>\n',
        "gpucc_acpi_headers",
    )

    # Preserve the normal DT index and add the CCF global-name fallback used
    # only when there is no OF clock specifier.  Internal PLL parents remain
    # direct .hw references and are untouched.
    replace_all(
        gpucc,
        '{ .index = DT_BI_TCXO },',
        '{ .index = DT_BI_TCXO, .name = "a14_gpucc_bi_tcxo_div2" },',
        "gpucc_bi_tcxo_parent_fallback",
    )
    replace_all(
        gpucc,
        '{ .index = DT_GPLL0_OUT_MAIN },',
        '{ .index = DT_GPLL0_OUT_MAIN, .name = "a14_gcc_gpu_gpll0_cph_clk_src" },',
        "gpucc_gpll0_main_parent_fallback",
    )
    replace_all(
        gpucc,
        '{ .index = DT_GPLL0_OUT_MAIN_DIV },',
        '{ .index = DT_GPLL0_OUT_MAIN_DIV, .name = "a14_gcc_gpu_gpll0_div_cph_clk_src" },',
        "gpucc_gpll0_div_parent_fallback",
    )

    bridge = r'''
/*
 * A14_X1E80100_GPUCC_ACPI_HW_V1
 *
 * WoA ACPI exposes GPU0 as one QCOM0C36 device, not as GCC/GPUCC DT clock
 * providers.  The GPUCC register window is nevertheless a firmware-validated
 * subrange of GPU0 GFX_REGS.  Recreate only GPUCC's three external parents:
 *
 *   bi_tcxo_div2                         19.2 MHz
 *   GCC_GPU_GPLL0_CPH_CLK_SRC           600 MHz, GCC 0x52000 bit 15
 *   GCC_GPU_GPLL0_DIV_CPH_CLK_SRC       300 MHz, GCC 0x52000 bit 16
 *
 * The 600/300 MHz topology is native X1E80100 GPLL0 + /2 and is independently
 * measured on this exact machine under the known-good DT kernel.  The branch
 * clocks below are real MMIO gates, not fixed fake GPU clocks.  CLK_IGNORE_UNUSED
 * is staging-only protection while GMU/Adreno consumers are intentionally not
 * bound yet.
 */
#define A14_GPUCC_GCC_GATE_PHYS		0x00152000ULL
#define A14_GPUCC_BI_TCXO_DIV2_RATE	19200000UL
#define A14_GPUCC_GPLL0_RATE		600000000UL

struct a14_gpucc_parent_bridge {
	void __iomem *gcc_gate_reg;
	struct clk_hw *bi_tcxo_div2;
	struct clk_hw *gpll0;
	struct clk_hw *gpll0_div2;
	struct clk_hw *gpll0_gpu_gate;
	struct clk_hw *gpll0_div_gpu_gate;
};

static int a14_gpucc_register_parent_bridge(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct a14_gpucc_parent_bridge *b;
	u32 gate_state;

	b = devm_kzalloc(dev, sizeof(*b), GFP_KERNEL);
	if (!b)
		return -ENOMEM;

	/* GCC is not separately described by WoA ACPI.  Map only its GPU vote
	 * register, whose address/bit assignments come from the native X1E80100
	 * GCC driver.  No other GCC register is exposed by this bridge.
	 */
	b->gcc_gate_reg = devm_ioremap(dev, A14_GPUCC_GCC_GATE_PHYS, sizeof(u32));
	if (!b->gcc_gate_reg)
		return dev_err_probe(dev, -ENOMEM, "A14GPUCC: failed to map GCC GPU gate register\n");

	b->bi_tcxo_div2 = devm_clk_hw_register_fixed_rate(dev,
					"a14_gpucc_bi_tcxo_div2", NULL, 0,
					A14_GPUCC_BI_TCXO_DIV2_RATE);
	if (IS_ERR(b->bi_tcxo_div2))
		return dev_err_probe(dev, PTR_ERR(b->bi_tcxo_div2),
				     "A14GPUCC: failed to register bi_tcxo_div2\n");

	/* X1E80100 GPLL0 is a fixed PLL in the native GCC driver. */
	b->gpll0 = devm_clk_hw_register_fixed_rate(dev,
					   "a14_gpucc_gpll0", NULL, 0,
					   A14_GPUCC_GPLL0_RATE);
	if (IS_ERR(b->gpll0))
		return dev_err_probe(dev, PTR_ERR(b->gpll0),
				     "A14GPUCC: failed to register GPLL0 model\n");

	b->gpll0_div2 = devm_clk_hw_register_fixed_factor_parent_hw(dev,
						"a14_gpucc_gpll0_out_even",
						b->gpll0, 0, 1, 2);
	if (IS_ERR(b->gpll0_div2))
		return dev_err_probe(dev, PTR_ERR(b->gpll0_div2),
				     "A14GPUCC: failed to register GPLL0 /2\n");

	b->gpll0_gpu_gate = devm_clk_hw_register_gate_parent_hw(dev,
					"a14_gcc_gpu_gpll0_cph_clk_src",
					b->gpll0,
					CLK_SET_RATE_PARENT | CLK_IGNORE_UNUSED,
					b->gcc_gate_reg, 15, 0, NULL);
	if (IS_ERR(b->gpll0_gpu_gate))
		return dev_err_probe(dev, PTR_ERR(b->gpll0_gpu_gate),
				     "A14GPUCC: failed to register GPLL0 GPU gate\n");

	b->gpll0_div_gpu_gate = devm_clk_hw_register_gate_parent_hw(dev,
					"a14_gcc_gpu_gpll0_div_cph_clk_src",
					b->gpll0_div2,
					CLK_SET_RATE_PARENT | CLK_IGNORE_UNUSED,
					b->gcc_gate_reg, 16, 0, NULL);
	if (IS_ERR(b->gpll0_div_gpu_gate))
		return dev_err_probe(dev, PTR_ERR(b->gpll0_div_gpu_gate),
				     "A14GPUCC: failed to register GPLL0 /2 GPU gate\n");

	gate_state = readl(b->gcc_gate_reg);
	dev_info(dev,
		 "A14GPUCC: parent bridge READY xo=%lu gpll0=%lu div2=%lu gcc_0x52000=0x%08x\n",
		 A14_GPUCC_BI_TCXO_DIV2_RATE, A14_GPUCC_GPLL0_RATE,
		 A14_GPUCC_GPLL0_RATE / 2, gate_state);

	return 0;
}

'''
    replace_once(
        gpucc,
        'static const struct of_device_id gpu_cc_x1e80100_match_table[] = {\n',
        bridge + 'static const struct of_device_id gpu_cc_x1e80100_match_table[] = {\n',
        "gpucc_acpi_parent_bridge",
    )

    replace_once(
        gpucc,
        '''MODULE_DEVICE_TABLE(of, gpu_cc_x1e80100_match_table);\n\nstatic int gpu_cc_x1e80100_probe(struct platform_device *pdev)\n''',
        '''MODULE_DEVICE_TABLE(of, gpu_cc_x1e80100_match_table);\n\nstatic const struct platform_device_id gpu_cc_x1e80100_platform_ids[] = {\n\t{ "a14-gpucc-x1e80100-acpi-topology", 1 },\n\t{ }\n};\nMODULE_DEVICE_TABLE(platform, gpu_cc_x1e80100_platform_ids);\n\nstatic int gpu_cc_x1e80100_probe(struct platform_device *pdev)\n''',
        "gpucc_acpi_platform_id",
    )

    replace_once(
        gpucc,
        '''static int gpu_cc_x1e80100_probe(struct platform_device *pdev)\n{\n\tstruct regmap *regmap;\n\n\tregmap = qcom_cc_map(pdev, &gpu_cc_x1e80100_desc);\n\tif (IS_ERR(regmap))\n\t\treturn PTR_ERR(regmap);\n\n\tclk_zonda_pll_configure(&gpu_cc_pll0, regmap, &gpu_cc_pll0_config);\n\tclk_lucid_evo_pll_configure(&gpu_cc_pll1, regmap, &gpu_cc_pll1_config);\n\n\t/* Keep clocks always enabled */\n\tqcom_branch_set_clk_en(regmap, 0x93a4); /* GPU_CC_CB_CLK */\n\n\treturn qcom_cc_really_probe(&pdev->dev, &gpu_cc_x1e80100_desc, regmap);\n}\n''',
        '''static int gpu_cc_x1e80100_probe(struct platform_device *pdev)\n{\n\tconst struct platform_device_id *id = platform_get_device_id(pdev);\n\tbool a14_acpi = !pdev->dev.of_node && id && id->driver_data == 1;\n\tstruct regmap *regmap;\n\tint ret;\n\n\tif (a14_acpi) {\n\t\t/* Give the no-OF child a real fwnode for reset-controller identity. */\n\t\tret = device_create_managed_software_node(&pdev->dev, NULL, NULL);\n\t\tif (ret)\n\t\t\treturn dev_err_probe(&pdev->dev, ret,\n\t\t\t\t\t     "A14GPUCC: failed to create software node\\n");\n\n\t\tret = a14_gpucc_register_parent_bridge(pdev);\n\t\tif (ret)\n\t\t\treturn ret;\n\t}\n\n\tregmap = qcom_cc_map(pdev, &gpu_cc_x1e80100_desc);\n\tif (IS_ERR(regmap))\n\t\treturn PTR_ERR(regmap);\n\n\tclk_zonda_pll_configure(&gpu_cc_pll0, regmap, &gpu_cc_pll0_config);\n\tclk_lucid_evo_pll_configure(&gpu_cc_pll1, regmap, &gpu_cc_pll1_config);\n\n\t/* Keep clocks always enabled */\n\tqcom_branch_set_clk_en(regmap, 0x93a4); /* GPU_CC_CB_CLK */\n\n\tret = qcom_cc_really_probe(&pdev->dev, &gpu_cc_x1e80100_desc, regmap);\n\tif (!ret && a14_acpi)\n\t\tdev_info(&pdev->dev,\n\t\t\t "A14GPUCC: READY pll1=%lu gmu_src=%lu hub_src=%lu real_mmio=true gmu_bound=false adreno_bound=false\\n",\n\t\t\t clk_hw_get_rate(&gpu_cc_pll1.clkr.hw),\n\t\t\t clk_hw_get_rate(&gpu_cc_gmu_clk_src.clkr.hw),\n\t\t\t clk_hw_get_rate(&gpu_cc_hub_clk_src.clkr.hw));\n\n\treturn ret;\n}\n''',
        "gpucc_acpi_probe",
    )

    replace_once(
        gpucc,
        '''static struct platform_driver gpu_cc_x1e80100_driver = {\n\t.probe = gpu_cc_x1e80100_probe,\n\t.driver = {\n''',
        '''static struct platform_driver gpu_cc_x1e80100_driver = {\n\t.probe = gpu_cc_x1e80100_probe,\n\t.id_table = gpu_cc_x1e80100_platform_ids,\n\t.driver = {\n''',
        "gpucc_acpi_driver_id_table",
    )

    # qcom_cc_really_probe(): DT behavior is byte-for-byte preserved in the DT
    # branch.  A no-OF clock controller has no firmware parent-PD list and no OF
    # clock provider to publish, but its CCF clocks/resets/GDSCs are still real.
    replace_once(
        common,
        '''\tret = devm_pm_domain_attach_list(dev, NULL, &cc->pd_list);\n\tif (ret < 0 && ret != -EEXIST)\n\t\treturn ret;\n''',
        '''\t/* A14_QCOM_CC_NON_OF_PROVIDER_V1 */\n\tif (dev->of_node) {\n\t\tret = devm_pm_domain_attach_list(dev, NULL, &cc->pd_list);\n\t\tif (ret < 0 && ret != -EEXIST)\n\t\t\treturn ret;\n\t}\n''',
        "qcom_cc_non_of_parent_pd",
    )

    replace_once(
        common,
        '''\treset = &cc->reset;\n\treset->rcdev.of_node = dev->of_node;\n''',
        '''\treset = &cc->reset;\n\treset->rcdev.dev = dev;\n\treset->rcdev.of_node = dev->of_node;\n''',
        "qcom_cc_reset_fwnode_identity",
    )

    replace_once(
        common,
        '''\tqcom_cc_drop_protected(dev, cc);\n''',
        '''\tif (dev->of_node)\n\t\tqcom_cc_drop_protected(dev, cc);\n''',
        "qcom_cc_non_of_protected_clocks",
    )

    replace_once(
        common,
        '''\tret = devm_of_clk_add_hw_provider(dev, qcom_cc_clk_hw_get, cc);\n\tif (ret)\n\t\tgoto put_rpm;\n\n\tret = qcom_cc_icc_register(dev, desc);\n''',
        '''\tif (dev->of_node) {\n\t\tret = devm_of_clk_add_hw_provider(dev, qcom_cc_clk_hw_get, cc);\n\t\tif (ret)\n\t\t\tgoto put_rpm;\n\t} else {\n\t\tdev_info(dev, "A14QCOMCC: non-OF clock registration; OF provider skipped\\n");\n\t}\n\n\tret = qcom_cc_icc_register(dev, desc);\n''',
        "qcom_cc_non_of_clock_provider",
    )

    # GDSCs are fully initialized and retain their real regmap/reset operations;
    # only OF provider publication is skipped for a no-OF device.  Later GMU
    # ACPI adaptation can attach these already-live domains directly.
    replace_once(
        gdsc,
        '''\treturn of_genpd_add_provider_onecell(dev->of_node, data);\n\nerr_pm_subdomain_remove:\n''',
        '''\t/* A14_GDSC_NON_OF_PROVIDER_V1 */\n\tif (!dev->of_node) {\n\t\tdev_info(dev, "A14GDSC: initialized %zu GDSCs without OF provider\\n", num);\n\t\treturn 0;\n\t}\n\n\treturn of_genpd_add_provider_onecell(dev->of_node, data);\n\nerr_pm_subdomain_remove:\n''',
        "gdsc_non_of_provider",
    )

    replace_once(
        gdsc,
        '''\tgdsc_pm_subdomain_remove(desc, num);\n\tof_genpd_del_provider(dev->of_node);\n''',
        '''\tgdsc_pm_subdomain_remove(desc, num);\n\tif (dev->of_node)\n\t\tof_genpd_del_provider(dev->of_node);\n''',
        "gdsc_non_of_unregister",
    )

    verify(root)
    print("A14_X1E80100_GPUCC_ACPI_HW_V1=APPLIED")
    print("gpucc_mmio=0x03d90000+0x0000a000_firmware_validated_subrange")
    print("gcc_gpu_gate_mmio=0x00152000_bits_15_16_native_x1e80100")
    print("parent_rates=19.2MHz_600MHz_300MHz_dt_baseline")
    print("stock_gpucc_pll_clock_setup=enabled")
    print("stock_gpucc_gdsc_init=enabled")
    print("of_provider_for_acpi=skipped")
    print("gmu_binding=disabled")
    print("adreno_binding=disabled")
    print("msm_source_change=none")
    print("keyboard_source_change=none")


if __name__ == "__main__":
    main()
