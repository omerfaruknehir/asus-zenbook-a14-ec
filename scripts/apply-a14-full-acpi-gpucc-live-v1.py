#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
'''
Stage the first live X1E80100 GPUCC provider under A14 ACPI.

Prerequisite: GPU topology V3 is already applied.

This stage deliberately keeps GPU and GMU unbound. It makes only GPUCC live:
- firmware-validated MMIO: 0x03d90000 + 0xa000, inside GPU0 GFX_REGS
- temporary fixed-rate parent proxies measured on this exact A14
- global-name parent fallback for gpucc-x1e80100 with no OF node
- non-OF-safe Qualcomm clock/GDSC registration

The GCC proxy clocks are RATE PROXIES ONLY. They do not program GCC hardware.
'''

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
TOPOLOGY_MARKER = "A14_QCOM0C36_TOPOLOGY_V1"
IORT_V3_MARKER = "A14_ACPI_DMA_IORT_IDS_V1"
MARKER = "A14_GPUCC_LIVE_V1"
QCOM_MARKER = "A14_QCOM_CC_NON_OF_PROVIDER_V1"
GDSC_MARKER = "A14_GDSC_NON_OF_PROVIDER_V1"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 GPUCC live V1 transform: {msg}")


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


def replace_count(path: Path, old: str, new: str, expected: int, label: str) -> None:
    text = path.read_text()
    if new in text and old not in text:
        print(f"{label}=current")
        return
    count = text.count(old)
    if count != expected:
        fail(f"{label}: expected {expected} anchors in {path}, found {count}")
    path.write_text(text.replace(old, new))
    print(f"{label}=applied({count})")


def verify(root: Path) -> None:
    scan = (root / "drivers/acpi/scan.c").read_text()
    msm = (root / "drivers/gpu/drm/msm/msm_drv.c").read_text()
    gpucc = (root / "drivers/clk/qcom/gpucc-x1e80100.c").read_text()
    common = (root / "drivers/clk/qcom/common.c").read_text()
    gdsc = (root / "drivers/clk/qcom/gdsc.c").read_text()

    if IORT_V3_MARKER not in scan:
        fail("topology V3 strict IORT helper missing")
    if TOPOLOGY_MARKER not in msm:
        fail("QCOM0C36 topology bridge missing")

    for token in (
        MARKER,
        '"bi-tcxo-div2-clk", 19200000',
        '"gcc_gpu_gpll0_cph_clk_src",',
        '"gcc_gpu_gpll0_div_cph_clk_src",',
        'a14_gpu0_add_child(pdev, "gpucc-x1e80100"',
        "gpucc_live=true",
        "gpu_gmu_unbound=true",
    ):
        if token not in msm:
            fail(f"MSM verification missing {token}")

    for token in (
        'a14_gpu0_add_child(pdev, "a14-adreno-x185-acpi-topology"',
        'a14_gpu0_add_child(pdev, "a14-gmu-x185-acpi-topology"',
    ):
        if token not in msm:
            fail(f"safety verification missing {token}")

    if 'a14_gpu0_add_child(pdev, "adreno"' in msm:
        fail("safety violation: real Adreno child enabled")
    if 'a14_gpu0_add_child(pdev, "adreno-gmu"' in msm:
        fail("safety violation: real GMU child enabled")

    for token in (
        MARKER,
        '"bi-tcxo-div2-clk"',
        '"gcc_gpu_gpll0_cph_clk_src"',
        '"gcc_gpu_gpll0_div_cph_clk_src"',
        "res->start != 0x03d90000",
        "resource_size(res) != 0x0000a000",
        "A14GPUCC-LIVE: provider registered",
        'MODULE_ALIAS("platform:gpucc-x1e80100")',
    ):
        if token not in gpucc:
            fail(f"GPUCC verification missing {token}")

    if QCOM_MARKER not in common:
        fail("Qualcomm non-OF clock-provider guard missing")
    if GDSC_MARKER not in gdsc:
        fail("GDSC non-OF provider guard missing")

    print("A14_GPUCC_LIVE_V1=VERIFIED")
    print("gpucc_mmio=0x03d90000+0xa000")
    print("gpu_live=false")
    print("gmu_live=false")
    print("gcc_live=false")
    print("rpmh_synthesized=false")
    print("of_clock_provider_for_acpi=false")
    print("of_genpd_provider_for_acpi=false")
    print("temporary_parent_proxies=19.2MHz,600MHz,300MHz")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-full-acpi-gpucc-live-v1.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"{root} is not a kernel source tree")
    if kernel_version(root) != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {kernel_version(root)}")

    scan = root / "drivers/acpi/scan.c"
    msm = root / "drivers/gpu/drm/msm/msm_drv.c"
    gpucc = root / "drivers/clk/qcom/gpucc-x1e80100.c"
    common = root / "drivers/clk/qcom/common.c"
    gdsc = root / "drivers/clk/qcom/gdsc.c"

    for path in (scan, msm, gpucc, common, gdsc):
        if not path.is_file():
            fail(f"missing {path}")

    if IORT_V3_MARKER not in scan.read_text():
        fail("apply the proven GPU topology V3 stage first")
    if TOPOLOGY_MARKER not in msm.read_text():
        fail("QCOM0C36 topology prerequisite missing")

    if all(marker in body for marker, body in (
        (MARKER, msm.read_text()),
        (MARKER, gpucc.read_text()),
        (QCOM_MARKER, common.read_text()),
        (GDSC_MARKER, gdsc.read_text()),
    )):
        verify(root)
        print("gpucc_live_v1=current")
        return

    replace_once(
        msm,
        '#include <linux/acpi_iort.h>\n#include <linux/dma-mapping.h>\n',
        '#include <linux/acpi_iort.h>\n'
        '#include <linux/clk-provider.h>\n'
        '#include <linux/dma-mapping.h>\n',
        "msm_clk_provider_header",
    )

    helper = r'''
/*
 * A14_GPUCC_LIVE_V1
 *
 * Temporary parent-rate proxies for the first live ACPI GPUCC stage.
 * The rates come from this exact A14's working DT boot. The two GCC-named
 * clocks do NOT control GCC hardware.
 */
static int a14_gpu0_register_fixed_parent(struct device *dev,
                                          const char *name,
                                          unsigned long rate)
{
    struct clk_hw *hw;
    long err;

    hw = devm_clk_hw_register_fixed_rate(dev, name, NULL, 0, rate);
    if (!IS_ERR(hw)) {
        dev_info(dev, "A14GPUCC-LIVE: parent proxy %s=%lu Hz registered\n",
                 name, rate);
        return 0;
    }

    err = PTR_ERR(hw);
    if (err == -EEXIST) {
        dev_info(dev, "A14GPUCC-LIVE: parent %s already exists; using it\n",
                 name);
        return 0;
    }

    dev_err(dev, "A14GPUCC-LIVE: parent proxy %s failed: %ld\n", name, err);
    return (int)err;
}

static int a14_gpu0_register_gpucc_parent_proxies(struct device *dev)
{
    int ret;

    ret = a14_gpu0_register_fixed_parent(dev, "bi-tcxo-div2-clk", 19200000);
    if (ret)
        return ret;

    ret = a14_gpu0_register_fixed_parent(dev,
                                         "gcc_gpu_gpll0_cph_clk_src",
                                         600000000);
    if (ret)
        return ret;

    return a14_gpu0_register_fixed_parent(dev,
                                          "gcc_gpu_gpll0_div_cph_clk_src",
                                          300000000);
}

'''
    replace_once(
        msm,
        "static int a14_gpu0_topology_probe(struct platform_device *pdev)\n{\n",
        helper + "static int a14_gpu0_topology_probe(struct platform_device *pdev)\n{\n",
        "msm_gpucc_parent_proxy_helper",
    )

    replace_once(
        msm,
        "\tplatform_set_drvdata(pdev, topo);\n\n"
        "\ttopo->gpu = a14_gpu0_add_child",
        "\tplatform_set_drvdata(pdev, topo);\n\n"
        "\tret = a14_gpu0_register_gpucc_parent_proxies(&pdev->dev);\n"
        "\tif (ret)\n"
        "\t\treturn ret;\n\n"
        "\ttopo->gpu = a14_gpu0_add_child",
        "msm_gpucc_parent_proxy_register",
    )

    replace_once(
        msm,
        'topo->gpucc = a14_gpu0_add_child(pdev, "a14-gpucc-x1e80100-acpi-topology",\n',
        'topo->gpucc = a14_gpu0_add_child(pdev, "gpucc-x1e80100",\n',
        "msm_gpucc_real_child_name",
    )

    replace_once(
        msm,
        '"A14GPU-TOPOLOGY: READY gpu_irq=%d hfi_irq=%d '
        'gmu_watchdog_irq=firmware-unexposed no_mmio=true\\n",\n',
        '"A14GPU-TOPOLOGY: READY gpu_irq=%d hfi_irq=%d '
        'gmu_watchdog_irq=firmware-unexposed gpucc_live=true '
        'gpu_gmu_unbound=true\\n",\n',
        "msm_gpucc_live_ready_log",
    )

    replace_count(
        gpucc,
        '''\t\t\t.parent_data = &(const struct clk_parent_data) {
\t\t\t\t.index = DT_BI_TCXO,
\t\t\t},''',
        '''\t\t\t.parent_data = &(const struct clk_parent_data) {
\t\t\t\t.index = DT_BI_TCXO,
\t\t\t\t.name = "bi-tcxo-div2-clk",
\t\t\t},''',
        2,
        "gpucc_pll_tcxo_fallbacks",
    )

    replacements = [
        (
'''static const struct clk_parent_data gpu_cc_parent_data_0[] = {
\t{ .index = DT_BI_TCXO },
\t{ .index = DT_GPLL0_OUT_MAIN },
\t{ .index = DT_GPLL0_OUT_MAIN_DIV },
};''',
'''static const struct clk_parent_data gpu_cc_parent_data_0[] = {
\t{ .index = DT_BI_TCXO, .name = "bi-tcxo-div2-clk" },
\t{ .index = DT_GPLL0_OUT_MAIN, .name = "gcc_gpu_gpll0_cph_clk_src" },
\t{ .index = DT_GPLL0_OUT_MAIN_DIV, .name = "gcc_gpu_gpll0_div_cph_clk_src" },
};''',
"gpucc_parent_data_0_fallbacks"),
        (
'''static const struct clk_parent_data gpu_cc_parent_data_1[] = {
\t{ .index = DT_BI_TCXO },
\t{ .hw = &gpu_cc_pll0.clkr.hw },
\t{ .hw = &gpu_cc_pll1.clkr.hw },
\t{ .index = DT_GPLL0_OUT_MAIN },
\t{ .index = DT_GPLL0_OUT_MAIN_DIV },
};''',
'''static const struct clk_parent_data gpu_cc_parent_data_1[] = {
\t{ .index = DT_BI_TCXO, .name = "bi-tcxo-div2-clk" },
\t{ .hw = &gpu_cc_pll0.clkr.hw },
\t{ .hw = &gpu_cc_pll1.clkr.hw },
\t{ .index = DT_GPLL0_OUT_MAIN, .name = "gcc_gpu_gpll0_cph_clk_src" },
\t{ .index = DT_GPLL0_OUT_MAIN_DIV, .name = "gcc_gpu_gpll0_div_cph_clk_src" },
};''',
"gpucc_parent_data_1_fallbacks"),
        (
'''static const struct clk_parent_data gpu_cc_parent_data_2[] = {
\t{ .index = DT_BI_TCXO },
\t{ .hw = &gpu_cc_pll1.clkr.hw },
\t{ .index = DT_GPLL0_OUT_MAIN },
\t{ .index = DT_GPLL0_OUT_MAIN_DIV },
};''',
'''static const struct clk_parent_data gpu_cc_parent_data_2[] = {
\t{ .index = DT_BI_TCXO, .name = "bi-tcxo-div2-clk" },
\t{ .hw = &gpu_cc_pll1.clkr.hw },
\t{ .index = DT_GPLL0_OUT_MAIN, .name = "gcc_gpu_gpll0_cph_clk_src" },
\t{ .index = DT_GPLL0_OUT_MAIN_DIV, .name = "gcc_gpu_gpll0_div_cph_clk_src" },
};''',
"gpucc_parent_data_2_fallbacks"),
        (
'''static const struct clk_parent_data gpu_cc_parent_data_3[] = {
\t{ .index = DT_BI_TCXO },
};''',
'''static const struct clk_parent_data gpu_cc_parent_data_3[] = {
\t{ .index = DT_BI_TCXO, .name = "bi-tcxo-div2-clk" },
};''',
"gpucc_parent_data_3_fallback"),
    ]
    for old, new, label in replacements:
        replace_once(gpucc, old, new, label)

    replace_once(
        gpucc,
        '''static int gpu_cc_x1e80100_probe(struct platform_device *pdev)
{
\tstruct regmap *regmap;

\tregmap = qcom_cc_map(pdev, &gpu_cc_x1e80100_desc);''',
        '''static int gpu_cc_x1e80100_probe(struct platform_device *pdev)
{
\tstruct resource *res;
\tstruct regmap *regmap;
\tint ret;

\t/* A14_GPUCC_LIVE_V1: hard gate before any non-DT GPUCC MMIO. */
\tif (!pdev->dev.of_node) {
\t\tres = platform_get_resource(pdev, IORESOURCE_MEM, 0);
\t\tif (!res || res->start != 0x03d90000 ||
\t\t    resource_size(res) != 0x0000a000) {
\t\t\tdev_err(&pdev->dev,
\t\t\t\t"A14GPUCC-LIVE: refusing unexpected non-DT resource\\n");
\t\t\treturn -EINVAL;
\t\t}

\t\tdev_info(&pdev->dev,
\t\t\t "A14GPUCC-LIVE: validated firmware-derived MMIO %pr\\n",
\t\t\t res);
\t}

\tregmap = qcom_cc_map(pdev, &gpu_cc_x1e80100_desc);''',
        "gpucc_non_dt_resource_gate",
    )

    replace_once(
        gpucc,
        '''\t/* Keep clocks always enabled */
\tqcom_branch_set_clk_en(regmap, 0x93a4); /* GPU_CC_CB_CLK */

\treturn qcom_cc_really_probe(&pdev->dev, &gpu_cc_x1e80100_desc, regmap);
}''',
        '''\t/* Keep clocks always enabled */
\tqcom_branch_set_clk_en(regmap, 0x93a4); /* GPU_CC_CB_CLK */

\tret = qcom_cc_really_probe(&pdev->dev, &gpu_cc_x1e80100_desc, regmap);
\tif (!ret && !pdev->dev.of_node)
\t\tdev_info(&pdev->dev,
\t\t\t "A14GPUCC-LIVE: provider registered; GPU/GMU remain unbound\\n");

\treturn ret;
}''',
        "gpucc_live_success_log",
    )

    replace_once(
        gpucc,
        '''module_platform_driver(gpu_cc_x1e80100_driver);

MODULE_DESCRIPTION("QTI GPU Clock Controller X1E80100 Driver");''',
        '''module_platform_driver(gpu_cc_x1e80100_driver);

MODULE_ALIAS("platform:gpucc-x1e80100");

MODULE_DESCRIPTION("QTI GPU Clock Controller X1E80100 Driver");''',
        "gpucc_platform_alias",
    )

    replace_once(
        common,
        '''static void qcom_cc_drop_protected(struct device *dev, struct qcom_cc *cc)
{
\tstruct device_node *np = dev->of_node;''',
        '''static void qcom_cc_drop_protected(struct device *dev, struct qcom_cc *cc)
{
\tstruct device_node *np = dev->of_node;

\t/* A14_QCOM_CC_NON_OF_PROVIDER_V1 */
\tif (!np)
\t\treturn;''',
        "qcom_cc_drop_protected_non_of_guard",
    )

    replace_once(
        common,
        '''\tret = devm_of_clk_add_hw_provider(dev, qcom_cc_clk_hw_get, cc);
\tif (ret)
\t\tgoto put_rpm;

\tret = qcom_cc_icc_register(dev, desc);''',
        '''\t/*
\t * A14_QCOM_CC_NON_OF_PROVIDER_V1
\t * Non-DT Qualcomm clock-controller children have no OF provider node.
\t * Their clocks are already registered with CCF above; skip only OF export.
\t */
\tif (dev->of_node) {
\t\tret = devm_of_clk_add_hw_provider(dev, qcom_cc_clk_hw_get, cc);
\t\tif (ret)
\t\t\tgoto put_rpm;
\t}

\tret = qcom_cc_icc_register(dev, desc);''',
        "qcom_cc_non_of_provider_guard",
    )

    replace_once(
        gdsc,
        '''\treturn of_genpd_add_provider_onecell(dev->of_node, data);

err_pm_subdomain_remove:''',
        '''\t/*
\t * A14_GDSC_NON_OF_PROVIDER_V1
\t * Domains are initialized above. A synthetic ACPI child has no OF node,
\t * so keep them internal and skip only OF provider publication.
\t */
\tif (!dev->of_node)
\t\treturn 0;

\treturn of_genpd_add_provider_onecell(dev->of_node, data);

err_pm_subdomain_remove:''',
        "gdsc_non_of_provider_add_guard",
    )

    replace_once(
        gdsc,
        '''\tgdsc_pm_subdomain_remove(desc, num);
\tof_genpd_del_provider(dev->of_node);
}''',
        '''\tgdsc_pm_subdomain_remove(desc, num);
\tif (dev->of_node)
\t\tof_genpd_del_provider(dev->of_node);
}''',
        "gdsc_non_of_provider_del_guard",
    )

    verify(root)
    print("A14_GPUCC_LIVE_V1=APPLIED")


if __name__ == "__main__":
    main()
