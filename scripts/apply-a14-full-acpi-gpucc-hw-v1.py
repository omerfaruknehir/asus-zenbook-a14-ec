#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Stage the first real X1E80100 GPU clock/power hardware layer on A14 ACPI.

Prerequisites already proven on this machine:
  * QCOM0C36 ACPI platform enumeration
  * QCOM0C36 IORT path normalization
  * GPU IORT inputs 0x03030000/0x03030020 and GMU 0x03030060
  * no-MMIO GPU/GMU/GPUCC topology bridge
  * GPUCC child resource 0x03d90000 + 0xa000 is inside firmware GFX_REGS

This layer deliberately does NOT bind GMU or Adreno. It makes the existing
X1E80100 GPUCC driver usable by the synthetic ACPI GPUCC child, supplies its
three external input clocks, registers the stock GPUCC clocks/resets/GDSCs,
and skips only OF-provider publication when no OF node exists.

The GCC-side bridge is hardware-backed: it maps only GCC 0x00100000..0x00152fff,
registers the native fixed Lucid-OLE GPLL0, its native /2 post-divider, and the
two native GPU branch gates at GCC register 0x52000 bits 15/16. The only fixed
external model is bi_tcxo_div2 at 19.2 MHz, which is itself a fixed-factor clock
in the X1E80100 DT. The bridge refuses GPUCC bring-up unless hardware GPLL0
recalculates to the exact 600 MHz / 300 MHz rates independently measured on
this machine's known-good DT kernel.
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
        "A14_GPUCC_GCC_BASE",
        "0x00100000ULL",
        "A14_GPUCC_GCC_MAP_SIZE",
        "0x00053000ULL",
        "clk_alpha_pll_fixed_lucid_ole_ops",
        "clk_alpha_pll_postdiv_lucid_ole_ops",
        '"a14_gcc_gpu_gpll0_cph_clk_src"',
        '"a14_gcc_gpu_gpll0_div_cph_clk_src"',
        "A14_GPUCC_EXPECTED_GPLL0_RATE",
        "600000000UL",
        "device_create_managed_software_node",
        "A14GPUCC: READY",
    ]
    for x in gpucc_req:
        if x not in gpucc:
            fail(f"GPUCC verification missing: {x}")

    if '.index = DT_BI_TCXO, .name = "a14_gpucc_bi_tcxo_div2"' not in gpucc:
        fail("BI_TCXO parent fallback missing")
    if '.index = DT_GPLL0_OUT_MAIN, .name = "a14_gcc_gpu_gpll0_cph_clk_src"' not in gpucc:
        fail("GPLL0 main parent fallback missing")
    if '.index = DT_GPLL0_OUT_MAIN_DIV, .name = "a14_gcc_gpu_gpll0_div_cph_clk_src"' not in gpucc:
        fail("GPLL0 div parent fallback missing")

    common_req = [
        COMMON_MARKER,
        "reset->rcdev.dev = dev;",
        "A14QCOMCC: non-OF clock registration",
    ]
    for x in common_req:
        if x not in common:
            fail(f"common.c verification missing: {x}")

    gdsc_req = [GDSC_MARKER, "A14GDSC: initialized", "if (!dev->of_node)"]
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

    replace_once(
        gpucc,
        '#include <linux/clk-provider.h>\n#include <linux/mod_devicetable.h>\n',
        '#include <linux/clk-provider.h>\n#include <linux/io.h>\n#include <linux/mod_devicetable.h>\n#include <linux/property.h>\n',
        "gpucc_acpi_headers",
    )

    # Keep the normal DT index and add the CCF global-name fallback used when
    # there is no OF clock specifier. Internal PLL parents remain direct .hw.
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
 * providers. Recreate only the real X1E80100 GCC pieces GPUCC consumes.
 *
 * The mini GCC resource covers GPLL0 at +0x0000, its enable vote at +0x52030,
 * and the two GPU branch bits at +0x52000. GPLL0 and its /2 output use the
 * exact native qcom clock ops; only bi_tcxo_div2 is represented as the fixed
 * 19.2 MHz external clock it is in the X1E80100 DT.
 */
#define A14_GPUCC_GCC_BASE			0x00100000ULL
#define A14_GPUCC_GCC_MAP_SIZE			0x00053000ULL
#define A14_GPUCC_BI_TCXO_DIV2_RATE		19200000UL
#define A14_GPUCC_EXPECTED_GPLL0_RATE		600000000UL
#define A14_GPUCC_EXPECTED_GPLL0_DIV2_RATE	300000000UL

static struct clk_alpha_pll a14_gcc_gpll0 = {
	.offset = 0x0,
	.regs = clk_alpha_pll_regs[CLK_ALPHA_PLL_TYPE_LUCID_OLE],
	.clkr = {
		.enable_reg = 0x52030,
		.enable_mask = BIT(0),
		.hw.init = &(const struct clk_init_data) {
			.name = "a14_gpucc_gpll0",
			.parent_data = &(const struct clk_parent_data) {
				.name = "a14_gpucc_bi_tcxo_div2",
			},
			.num_parents = 1,
			.ops = &clk_alpha_pll_fixed_lucid_ole_ops,
		},
	},
};

static const struct clk_div_table a14_gpll0_even_table[] = {
	{ 0x1, 2 },
	{ }
};

static struct clk_alpha_pll_postdiv a14_gcc_gpll0_out_even = {
	.offset = 0x0,
	.post_div_shift = 10,
	.post_div_table = a14_gpll0_even_table,
	.num_post_div = ARRAY_SIZE(a14_gpll0_even_table),
	.width = 4,
	.regs = clk_alpha_pll_regs[CLK_ALPHA_PLL_TYPE_LUCID_OLE],
	.clkr.hw.init = &(const struct clk_init_data) {
		.name = "a14_gpucc_gpll0_out_even",
		.parent_hws = (const struct clk_hw *[]) {
			&a14_gcc_gpll0.clkr.hw,
		},
		.num_parents = 1,
		.ops = &clk_alpha_pll_postdiv_lucid_ole_ops,
	},
};

static struct clk_branch a14_gcc_gpu_gpll0_cph_clk_src = {
	.halt_reg = 0x52000,
	.halt_check = BRANCH_HALT_DELAY,
	.clkr = {
		.enable_reg = 0x52000,
		.enable_mask = BIT(15),
		.hw.init = &(const struct clk_init_data) {
			.name = "a14_gcc_gpu_gpll0_cph_clk_src",
			.parent_hws = (const struct clk_hw *[]) {
				&a14_gcc_gpll0.clkr.hw,
			},
			.num_parents = 1,
			.flags = CLK_SET_RATE_PARENT | CLK_IGNORE_UNUSED,
			.ops = &clk_branch2_ops,
		},
	},
};

static struct clk_branch a14_gcc_gpu_gpll0_div_cph_clk_src = {
	.halt_reg = 0x52000,
	.halt_check = BRANCH_HALT_DELAY,
	.clkr = {
		.enable_reg = 0x52000,
		.enable_mask = BIT(16),
		.hw.init = &(const struct clk_init_data) {
			.name = "a14_gcc_gpu_gpll0_div_cph_clk_src",
			.parent_hws = (const struct clk_hw *[]) {
				&a14_gcc_gpll0_out_even.clkr.hw,
			},
			.num_parents = 1,
			.flags = CLK_SET_RATE_PARENT | CLK_IGNORE_UNUSED,
			.ops = &clk_branch2_ops,
		},
	},
};

static const struct regmap_config a14_gcc_gpu_parent_regmap_config = {
	.reg_bits = 32,
	.reg_stride = 4,
	.val_bits = 32,
	.max_register = 0x52030,
	.fast_io = true,
};

struct a14_gpucc_parent_bridge {
	struct platform_device *pdev;
};

static void a14_gpucc_unregister_gcc_bridge(void *data)
{
	platform_device_unregister(data);
}

static int a14_gpucc_register_parent_bridge(struct platform_device *gpucc_pdev)
{
	struct device *dev = &gpucc_pdev->dev;
	struct a14_gpucc_parent_bridge *bridge;
	struct platform_device *pdev;
	struct resource res = DEFINE_RES_MEM(A14_GPUCC_GCC_BASE,
					     A14_GPUCC_GCC_MAP_SIZE);
	void __iomem *base;
	struct regmap *regmap;
	struct clk_hw *xo;
	unsigned long main_rate, div_rate;
	u32 gate_state, pll_vote_state;
	int ret;

	bridge = devm_kzalloc(dev, sizeof(*bridge), GFP_KERNEL);
	if (!bridge)
		return -ENOMEM;

	pdev = platform_device_alloc("a14-gcc-gpu-parent-bridge", PLATFORM_DEVID_NONE);
	if (!pdev)
		return -ENOMEM;
	pdev->dev.parent = dev;

	ret = platform_device_add_resources(pdev, &res, 1);
	if (ret)
		goto err_put;
	ret = platform_device_add(pdev);
	if (ret)
		goto err_put;

	bridge->pdev = pdev;
	ret = devm_add_action_or_reset(dev, a14_gpucc_unregister_gcc_bridge, pdev);
	if (ret)
		return ret;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return dev_err_probe(dev, PTR_ERR(base),
				     "A14GPUCC: failed to map mini GCC resource\n");

	regmap = devm_regmap_init_mmio(&pdev->dev, base,
					&a14_gcc_gpu_parent_regmap_config);
	if (IS_ERR(regmap))
		return dev_err_probe(dev, PTR_ERR(regmap),
				     "A14GPUCC: failed to create mini GCC regmap\n");

	xo = devm_clk_hw_register_fixed_rate(&pdev->dev,
					     "a14_gpucc_bi_tcxo_div2", NULL, 0,
					     A14_GPUCC_BI_TCXO_DIV2_RATE);
	if (IS_ERR(xo))
		return dev_err_probe(dev, PTR_ERR(xo),
				     "A14GPUCC: failed to register bi_tcxo_div2\n");

	ret = devm_clk_register_regmap(&pdev->dev, &a14_gcc_gpll0.clkr);
	if (ret)
		return dev_err_probe(dev, ret, "A14GPUCC: failed to register GPLL0\n");
	ret = devm_clk_register_regmap(&pdev->dev, &a14_gcc_gpll0_out_even.clkr);
	if (ret)
		return dev_err_probe(dev, ret, "A14GPUCC: failed to register GPLL0 /2\n");
	ret = devm_clk_register_regmap(&pdev->dev, &a14_gcc_gpu_gpll0_cph_clk_src.clkr);
	if (ret)
		return dev_err_probe(dev, ret, "A14GPUCC: failed to register GPLL0 GPU gate\n");
	ret = devm_clk_register_regmap(&pdev->dev, &a14_gcc_gpu_gpll0_div_cph_clk_src.clkr);
	if (ret)
		return dev_err_probe(dev, ret, "A14GPUCC: failed to register GPLL0 /2 GPU gate\n");

	main_rate = clk_hw_get_rate(&a14_gcc_gpll0.clkr.hw);
	div_rate = clk_hw_get_rate(&a14_gcc_gpll0_out_even.clkr.hw);
	if (main_rate != A14_GPUCC_EXPECTED_GPLL0_RATE ||
	    div_rate != A14_GPUCC_EXPECTED_GPLL0_DIV2_RATE)
		return dev_err_probe(dev, -EINVAL,
				     "A14GPUCC: refusing GPUCC: GPLL0 rates %lu/%lu, expected %lu/%lu\n",
				     main_rate, div_rate,
				     A14_GPUCC_EXPECTED_GPLL0_RATE,
				     A14_GPUCC_EXPECTED_GPLL0_DIV2_RATE);

	ret = regmap_read(regmap, 0x52000, &gate_state);
	if (ret)
		return ret;
	ret = regmap_read(regmap, 0x52030, &pll_vote_state);
	if (ret)
		return ret;

	dev_info(dev,
		 "A14GPUCC: native GCC parent bridge READY xo=%lu gpll0=%lu div2=%lu gate=0x%08x pll_vote=0x%08x\n",
		 A14_GPUCC_BI_TCXO_DIV2_RATE, main_rate, div_rate,
		 gate_state, pll_vote_state);
	return 0;

err_put:
	platform_device_put(pdev);
	return ret;
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

    # Preserve DT behavior. A no-OF clock controller has no firmware parent-PD
    # list and no OF clock provider to publish, but its CCF clocks/resets/GDSCs
    # remain real kernel objects.
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

    # Fully initialize real GDSCs; only OF publication is absent for the ACPI
    # staging child. Later GMU ACPI adaptation can attach these domains directly.
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
    print("gcc_mini_mmio=0x00100000+0x00053000_native_x1e80100")
    print("gcc_gpll0=native_lucid_ole_hardware_model")
    print("gcc_gpll0_div2=native_lucid_ole_postdiv")
    print("gcc_gpu_gates=real_regmap_branches_bits_15_16")
    print("gpll0_runtime_rate_guard=600MHz_300MHz")
    print("stock_gpucc_pll_clock_setup=enabled")
    print("stock_gpucc_gdsc_init=enabled")
    print("of_provider_for_acpi=skipped")
    print("gmu_binding=disabled")
    print("adreno_binding=disabled")
    print("msm_source_change=none")
    print("keyboard_source_change=none")


if __name__ == "__main__":
    main()
