#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add the minimal X1E80100 ACPI PDC irqdomain bootstrap to Linux v7.1.5.

This transform deliberately does not make any ACPI SPMI/PMIC consumer use the
PDC domain yet.  It only lets the already-working X1E80100 GIO0/TLMM ACPI
probe instantiate the PDC hierarchy from the Qualcomm WoA firmware contract.

Safety properties of the resulting kernel path:
  * QCOM0C0C/GIO0 remains owned by the X1E80100 pinctrl driver.
  * PDC init is best-effort after the normal pinctrl probe; failure does not
    fail GIO0.
  * The ACPI path preserves existing PDC enable/configuration state at init;
    unlike the DT probe it does not disable every mapped PDC line.
  * No SPMI/PMIC IRQ is allocated by this transform.
"""

from pathlib import Path
import sys

KERNEL_VERSION = "7.1.5"
MARKER = "A14_ROOT16_PDC_ACPI_DOMAIN"


def fail(msg: str) -> None:
    raise SystemExit(f"A14 ROOT16 PDC transform: {msg}")


def version(root: Path) -> str:
    vals = {}
    for line in (root / "Makefile").read_text().splitlines():
        for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
            if line.startswith(key + " ="):
                vals[key] = line.split("=", 1)[1].strip()
    try:
        return ".".join(vals[k] for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL"))
    except KeyError as exc:
        fail(f"cannot determine kernel version: {exc}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        print(f"{label}=current")
        return text
    n = text.count(old)
    if n != 1:
        fail(f"{label}: expected one anchor, found {n}")
    print(f"{label}=applied")
    return text.replace(old, new, 1)


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".root16.tmp")
    tmp.write_text(text)
    tmp.replace(path)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: apply-a14-acpi-root16-pdc-domain.py /path/to/linux-7.1.5")

    root = Path(sys.argv[1]).resolve()
    if not (root / "Makefile").is_file():
        fail(f"not a kernel source tree: {root}")
    found = version(root)
    if found != KERNEL_VERSION:
        fail(f"targets exactly {KERNEL_VERSION}; found {found}")

    pdc = root / "drivers/irqchip/qcom-pdc.c"
    irqh = root / "include/linux/soc/qcom/irq.h"
    x1 = root / "drivers/pinctrl/qcom/pinctrl-x1e80100.c"
    for path in (pdc, irqh, x1):
        if not path.is_file():
            fail(f"missing source: {path}")

    originals = {path: path.read_text() for path in (pdc, irqh, x1)}
    out = dict(originals)

    # Public declaration.  The stub avoids a built-in -> module dependency
    # when QCOM_PDC is not reachable from the X1E pinctrl driver.
    irq_old = '''#include <linux/irqdomain.h>\n\n#define GPIO_NO_WAKE_IRQ\t~0U\n'''
    irq_new = '''#include <linux/irqdomain.h>\n\nstruct platform_device;\n\n#define GPIO_NO_WAKE_IRQ\t~0U\n'''
    out[irqh] = replace_once(out[irqh], irq_old, irq_new, "irq_header_platform_fwd")

    irq_tail_old = '''static inline bool irq_domain_qcom_handle_wakeup(const struct irq_domain *d)\n{\n\treturn (d->flags & IRQ_DOMAIN_FLAG_QCOM_PDC_WAKEUP);\n}\n\n#endif\n'''
    irq_tail_new = '''static inline bool irq_domain_qcom_handle_wakeup(const struct irq_domain *d)\n{\n\treturn (d->flags & IRQ_DOMAIN_FLAG_QCOM_PDC_WAKEUP);\n}\n\n/* A14_ROOT16_PDC_ACPI_DOMAIN\n * QCOM0C0C is the X1E80100 TLMM device in the audited Windows-on-ARM ACPI\n * namespace.  ACPI exposes the PDC register contract through that device's\n * vendor _DSM rather than as a standalone PDC platform device.\n */\n#if IS_REACHABLE(CONFIG_QCOM_PDC) && IS_ENABLED(CONFIG_ACPI)\nint qcom_pdc_acpi_init(struct platform_device *pdev);\n#else\nstatic inline int qcom_pdc_acpi_init(struct platform_device *pdev)\n{\n\treturn 0;\n}\n#endif\n\n#endif\n'''
    out[irqh] = replace_once(out[irqh], irq_tail_old, irq_tail_new, "irq_header_pdc_acpi_api")

    # Explicit dependencies for the new ACPI/platform helper path.
    pdc_inc_old = '''#include <linux/err.h>\n#include <linux/init.h>\n'''
    pdc_inc_new = '''#include <linux/acpi.h>\n#include <linux/err.h>\n#include <linux/init.h>\n'''
    out[pdc] = replace_once(out[pdc], pdc_inc_old, pdc_inc_new, "pdc_acpi_include")

    pdc_inc2_old = '''#include <linux/of_irq.h>\n#include <linux/soc/qcom/irq.h>\n'''
    pdc_inc2_new = '''#include <linux/of_irq.h>\n#include <linux/platform_device.h>\n#include <linux/soc/qcom/irq.h>\n'''
    out[pdc] = replace_once(out[pdc], pdc_inc2_old, pdc_inc2_new, "pdc_platform_include")

    # The stock PDC allocator emits a DT-style 3-cell parent GIC fwspec.
    # An ACPI-created GICv3 irqdomain accepts exactly 2 cells: [GSI, type].
    # Keep DT behavior unchanged and translate the SoC DT-SPI number to the
    # architected ACPI GSI (SPI + 32) only for non-OF irqchip parents.
    pdc_parent_old = '''\tparent_fwspec.fwnode      = domain->parent->fwnode;\n\tparent_fwspec.param_count = 3;\n\tparent_fwspec.param[0]    = 0;\n\tparent_fwspec.param[1]    = pin_to_hwirq(region, hwirq);\n\tparent_fwspec.param[2]    = type;\n\n\treturn irq_domain_alloc_irqs_parent(domain, virq, nr_irqs,\n\t\t\t\t\t    &parent_fwspec);\n'''
    pdc_parent_new = '''\tparent_fwspec.fwnode = domain->parent->fwnode;\n\tif (is_of_node(parent_fwspec.fwnode)) {\n\t\tparent_fwspec.param_count = 3;\n\t\tparent_fwspec.param[0] = 0;\n\t\tparent_fwspec.param[1] = pin_to_hwirq(region, hwirq);\n\t\tparent_fwspec.param[2] = type;\n\t} else if (is_fwnode_irqchip(parent_fwspec.fwnode)) {\n\t\t/* ACPI GIC domains use full GSIs rather than DT SPI numbers. */\n\t\tparent_fwspec.param_count = 2;\n\t\tparent_fwspec.param[0] = pin_to_hwirq(region, hwirq) + 32;\n\t\tparent_fwspec.param[1] = type;\n\t} else {\n\t\treturn -EINVAL;\n\t}\n\n\treturn irq_domain_alloc_irqs_parent(domain, virq, nr_irqs,\n\t\t\t\t\t    &parent_fwspec);\n'''
    out[pdc] = replace_once(out[pdc], pdc_parent_old, pdc_parent_new, "pdc_parent_fwspec_acpi")

    pdc_globals_old = '''static unsigned int pdc_version;\nstatic bool pdc_x1e_quirk;\n'''
    pdc_globals_new = r'''static unsigned int pdc_version;
static bool pdc_x1e_quirk;

#ifdef CONFIG_ACPI
/* A14_ROOT16_PDC_ACPI_DOMAIN
 *
 * X1E80100 WoA firmware exposes the PDC programming contract through GIO0's
 * _DSM (UUID 921b0fd4-567c-43a0-bb14-2648f7b2a18c).  The PDC pin -> parent
 * SPI topology itself is SoC data and is identical to qcom,pdc-ranges in the
 * X1E80100 DT.
 */
static const guid_t qcom_pdc_acpi_dsm_guid =
	GUID_INIT(0x921b0fd4, 0x567c, 0x43a0,
		  0xbb, 0x14, 0x26, 0x48, 0xf7, 0xb2, 0xa1, 0x8c);

static const struct acpi_device_id qcom_pdc_acpi_gio0_ids[] = {
	{ "QCOM0C0C", 0 },
	{ "QCOMFFEB", 0 },
	{ }
};

#define X1E80100_PDC_ACPI_BASE	0x0b220000ULL

static const struct pdc_pin_region x1e80100_acpi_pdc_regions[] = {
	{ 0,   480, 42 },
	{ 42,  251, 5  },
	{ 47,  522, 52 },
	{ 99,  609, 32 },
	{ 131, 717, 12 },
	{ 143, 816, 19 },
};

static struct irq_domain *pdc_acpi_domain;
static struct fwnode_handle *pdc_acpi_fwnode;
#endif
'''
    out[pdc] = replace_once(out[pdc], pdc_globals_old, pdc_globals_new, "pdc_acpi_globals")

    pdc_helper_anchor = '''#define QCOM_PDC_SIZE 0x30000\n\nstatic int qcom_pdc_probe(struct platform_device *pdev, struct device_node *parent)\n'''
    pdc_helper = r'''#ifdef CONFIG_ACPI
static int qcom_pdc_acpi_dsm_u64(struct device *dev, u64 function, u64 *value)
{
	union acpi_object *obj;
	int ret = 0;

	obj = acpi_evaluate_dsm(ACPI_HANDLE(dev), &qcom_pdc_acpi_dsm_guid,
				0, function, NULL);
	if (!obj)
		return -ENODEV;

	if (obj->type != ACPI_TYPE_INTEGER)
		ret = -EINVAL;
	else
		*value = obj->integer.value;

	ACPI_FREE(obj);
	return ret;
}

static int pdc_setup_pin_mapping_acpi(void)
{
	pdc_region_cnt = ARRAY_SIZE(x1e80100_acpi_pdc_regions);
	pdc_region = kmemdup(x1e80100_acpi_pdc_regions,
			     sizeof(x1e80100_acpi_pdc_regions), GFP_KERNEL);
	if (!pdc_region) {
		pdc_region_cnt = 0;
		return -ENOMEM;
	}

	/* Preserve firmware state.  ACPI devices may already be using PDC-routed
	 * interrupts before this late platform probe.  Individual child IRQs will
	 * be programmed only when a consumer explicitly allocates them.
	 */
	return 0;
}

int qcom_pdc_acpi_init(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct irq_domain *parent_domain;
	struct irq_data *parent_data;
	resource_size_t base;
	u64 pdcv, pdce, pdcc, pdcm, gicb, gics;
	int parent_irq;
	int ret;

	if (!has_acpi_companion(dev) ||
	    !acpi_match_device(qcom_pdc_acpi_gio0_ids, dev))
		return -ENODEV;

	if (pdc_acpi_domain)
		return 0;
	if (pdc_region || pdc_base || pdc_prev_base)
		return -EBUSY;

	ret = qcom_pdc_acpi_dsm_u64(dev, 1, &pdcv);
	if (ret)
		goto dsm_fail;
	ret = qcom_pdc_acpi_dsm_u64(dev, 3, &pdce);
	if (ret)
		goto dsm_fail;
	ret = qcom_pdc_acpi_dsm_u64(dev, 4, &pdcc);
	if (ret)
		goto dsm_fail;
	ret = qcom_pdc_acpi_dsm_u64(dev, 5, &pdcm);
	if (ret)
		goto dsm_fail;
	ret = qcom_pdc_acpi_dsm_u64(dev, 6, &gicb);
	if (ret)
		goto dsm_fail;
	ret = qcom_pdc_acpi_dsm_u64(dev, 7, &gics);
	if (ret)
		goto dsm_fail;

	if (pdcv != 1 || pdce < IRQ_ENABLE_BANK ||
	    (pdce & (PDC_DRV_OFFSET - 1)) != IRQ_ENABLE_BANK) {
		dev_err(dev, "A14ROOT16_PDC_ACPI: invalid PDC DSM version/register 0x%llx/0x%llx\n",
		(unsigned long long)pdcv, (unsigned long long)pdce);
		return -EINVAL;
	}

	base = (resource_size_t)(pdce - IRQ_ENABLE_BANK);
	if (base != X1E80100_PDC_ACPI_BASE) {
		dev_err(dev, "A14ROOT16_PDC_ACPI: unexpected X1E PDC base %pa\n", &base);
		return -EINVAL;
	}
	if (pdcc != base + IRQ_i_CFG) {
		dev_err(dev, "A14ROOT16_PDC_ACPI: PDCC 0x%llx does not match base+0x%x\n",
			(unsigned long long)pdcc, IRQ_i_CFG);
		return -EINVAL;
	}

	parent_irq = platform_get_irq(pdev, 0);
	if (parent_irq < 0)
		return parent_irq;
	parent_data = irq_get_irq_data(parent_irq);
	if (!parent_data || !parent_data->domain)
		return -EPROBE_DEFER;
	parent_domain = parent_data->domain;

	pdc_prev_base = ioremap(base - PDC_DRV_OFFSET, IRQ_ENABLE_BANK_MAX);
	if (!pdc_prev_base)
		return -ENOMEM;

	pdc_base = ioremap(base, PDC_DRV_OFFSET);
	if (!pdc_base) {
		ret = -ENOMEM;
		goto err_unmap_prev;
	}

	pdc_x1e_quirk = true;
	pdc_version = pdc_reg_read(PDC_VERSION_REG, 0);
	if (!pdc_version || pdc_version == ~0U) {
		dev_err(dev, "A14ROOT16_PDC_ACPI: invalid hardware version 0x%x\n",
			pdc_version);
		ret = -ENODEV;
		goto err_unmap_base;
	}

	ret = pdc_setup_pin_mapping_acpi();
	if (ret)
		goto err_unmap_base;

	pdc_acpi_fwnode = irq_domain_alloc_named_parented_fwnode(
				"qcom-x1e80100-pdc-acpi", dev_fwnode(dev));
	if (!pdc_acpi_fwnode) {
		ret = -ENOMEM;
		goto err_free_regions;
	}

	pdc_acpi_domain = irq_domain_create_hierarchy(parent_domain,
					IRQ_DOMAIN_FLAG_QCOM_PDC_WAKEUP,
					PDC_MAX_GPIO_IRQS,
					pdc_acpi_fwnode,
					&qcom_pdc_ops, NULL);
	if (!pdc_acpi_domain) {
		ret = -ENOMEM;
		goto err_free_fwnode;
	}

	irq_domain_update_bus_token(pdc_acpi_domain, DOMAIN_BUS_WAKEUP);

	dev_info(dev,
		 "A14ROOT16_PDC_ACPI: domain-ready base=%pa hwver=0x%x pdcv=%llu pdcm=0x%llx gic=0x%llx/0x%llx parent_irq=%d parent_hwirq=%lu ranges=%zu preserve_state=1\n",
		 &base, pdc_version, (unsigned long long)pdcv,
		 (unsigned long long)pdcm, (unsigned long long)gicb,
		 (unsigned long long)gics, parent_irq,
		 (unsigned long)parent_data->hwirq,
		 ARRAY_SIZE(x1e80100_acpi_pdc_regions));
	return 0;

err_free_fwnode:
	irq_domain_free_fwnode(pdc_acpi_fwnode);
	pdc_acpi_fwnode = NULL;
err_free_regions:
	kfree(pdc_region);
	pdc_region = NULL;
	pdc_region_cnt = 0;
err_unmap_base:
	iounmap(pdc_base);
	pdc_base = NULL;
err_unmap_prev:
	iounmap(pdc_prev_base);
	pdc_prev_base = NULL;
	pdc_x1e_quirk = false;
	return ret;

dsm_fail:
	dev_err(dev, "A14ROOT16_PDC_ACPI: DSM function read failed: %d\n", ret);
	return ret;
}
EXPORT_SYMBOL_GPL(qcom_pdc_acpi_init);
#endif

#define QCOM_PDC_SIZE 0x30000

static int qcom_pdc_probe(struct platform_device *pdev, struct device_node *parent)
'''
    # QCOM_PDC_SIZE is needed by the ACPI helper too, so move it before helper.
    pdc_helper = pdc_helper.replace(
        '#ifdef CONFIG_ACPI\n',
        '#define QCOM_PDC_SIZE 0x30000\n\n#ifdef CONFIG_ACPI\n',
        1,
    ).replace('\n#define QCOM_PDC_SIZE 0x30000\n\nstatic int qcom_pdc_probe',
              '\nstatic int qcom_pdc_probe', 1)
    out[pdc] = replace_once(out[pdc], pdc_helper_anchor, pdc_helper, "pdc_acpi_helper")

    # X1E TLMM owns QCOM0C0C.  Keep its normal probe authoritative and make
    # PDC setup best-effort so a failed experiment never removes GIO0.
    if "#include <linux/acpi.h>" not in out[x1]:
        out[x1] = replace_once(
            out[x1],
            "#include <linux/module.h>\n",
            "#include <linux/acpi.h>\n#include <linux/module.h>\n",
            "x1_acpi_include",
        )
    else:
        print("x1_acpi_include=current")

    x1_inc_old = '''#include <linux/platform_device.h>\n\n#include "pinctrl-msm.h"\n'''
    x1_inc_new = '''#include <linux/platform_device.h>\n#include <linux/soc/qcom/irq.h>\n\n#include "pinctrl-msm.h"\n'''
    out[x1] = replace_once(out[x1], x1_inc_old, x1_inc_new, "x1_pdc_header")

    x1_probe_old = '''static int x1e80100_pinctrl_probe(struct platform_device *pdev)\n{\n\treturn msm_pinctrl_probe(pdev, &x1e80100_pinctrl);\n}\n'''
    x1_probe_new = '''static int x1e80100_pinctrl_probe(struct platform_device *pdev)\n{\n\tint ret;\n\n\tret = msm_pinctrl_probe(pdev, &x1e80100_pinctrl);\n\tif (ret)\n\t\treturn ret;\n\n\tif (has_acpi_companion(&pdev->dev)) {\n\t\tret = qcom_pdc_acpi_init(pdev);\n\t\tif (ret)\n\t\t\tdev_warn(&pdev->dev,\n\t\t\t\t "A14ROOT16_PDC_ACPI: best-effort init failed: %d\\n",\n\t\t\t\t ret);\n\t}\n\n\treturn 0;\n}\n'''
    out[x1] = replace_once(out[x1], x1_probe_old, x1_probe_new, "x1_best_effort_pdc_init")

    # Validate every file before making any write, then atomically replace.
    checks = {
        irqh: [MARKER, "qcom_pdc_acpi_init"],
        pdc: [MARKER, "qcom_pdc_acpi_dsm_guid", "x1e80100_acpi_pdc_regions",
              "preserve_state=1", "irq_domain_alloc_named_parented_fwnode",
              "ACPI GIC domains use full GSIs", "pin_to_hwirq(region, hwirq) + 32",
              "X1E80100_PDC_ACPI_BASE"],
        x1: ["qcom_pdc_acpi_init", "A14ROOT16_PDC_ACPI: best-effort init failed"],
    }
    for path, tokens in checks.items():
        missing = [tok for tok in tokens if tok not in out[path]]
        if missing:
            fail(f"post-transform check failed for {path}: {missing}")

    for path in (irqh, pdc, x1):
        if out[path] != originals[path]:
            write_atomic(path, out[path])

    print(f"{MARKER}=APPLIED")
    print("acpi_owner=QCOM0C0C_GIO0")
    print("pdc_ranges_source=X1E80100_SOC_DATA")
    print("register_contract_source=GIO0_DSM")
    print("parent_irqdomain_source=GIO0_platform_irq")
    print("probe_state_policy=preserve")
    print("spmi_irq_allocation=false")


if __name__ == "__main__":
    main()
