#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ACPI ROOT16: QCOM0C0B SPMI controller bootstrap, no PMIC IRQ domain.
#
# Stage goal:
#   * bind the factory ACPI QCOM0C0B SPMI device
#   * evaluate CONF at probe time and validate its two-record X1E contract
#   * map the v7 PMIC-arbiter subregions from the single ACPI _CRS window
#   * register the two SPMI controllers and read the APID/PPID ownership maps
#   * deliberately DO NOT request periph_irq, create PMIC IRQ domains, touch PDC,
#     enumerate PMIC devices, or enable flash hardware in this stage
#
# Safety invariants:
#   * prepare NEVER arms a boot and leaves GRUB next_entry unset
#   * arm ONLY sets a one-shot GRUB entry; it NEVER reboots
#   * experimental command line contains panic=0
#   * Image-only build: no modules, modules_install, DKMS or initramfs rebuild
#   * the only kernel source mutation is drivers/spmi/spmi-pmic-arb.c, performed
#     transactionally after all expected source patterns have been verified
set -euo pipefail

ACTION="${1:-}"
OWNER="${SUDO_USER:-}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ "$ACTION" == prepare || "$ACTION" == arm || "$ACTION" == status ]] ||
    die "usage: $0 {prepare|arm|status}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
[[ -n "$OWNER" && "$OWNER" != root ]] || die "run with sudo from your normal login"

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[[ -n "$OWNER_HOME" && -d "$OWNER_HOME" ]] || die "cannot resolve owner home"

WORK="${A14_74C9_WORK:-$OWNER_HOME/Downloads/a14-full-acpi-kernel}"
SRC="${A14_KERNEL_SRC:-$WORK/linux-7.1.5}"
OUT="${A14_KERNEL_OUT:-$WORK/root16-build}"
ROOT14_KREL="${A14_ROOT14_KREL:-7.1.5-a14-acpi-root14}"
ROOT16_KREL="${A14_ROOT16_KREL:-7.1.5-a14-acpi-root16}"
ROOT14_CONFIG="${A14_ROOT14_CONFIG:-/boot/config-$ROOT14_KREL}"
ROOT11_INITRD="${A14_ROOT11_INITRD:-/boot/initrd.img-7.1.5-a14-acpi-root11}"
ROOT14_FRAGMENT="${A14_ROOT14_GRUB_FRAGMENT:-/etc/grub.d/42_a14_acpi_root14}"
ROOT16_FRAGMENT="${A14_ROOT16_GRUB_FRAGMENT:-/etc/grub.d/43_a14_acpi_root16}"
ROOT16_IMAGE="/boot/vmlinuz-$ROOT16_KREL"
ROOT16_CONFIG="/boot/config-$ROOT16_KREL"
ROOT16_SYSTEM_MAP="/boot/System.map-$ROOT16_KREL"
ENTRY_TITLE="${A14_ROOT16_ENTRY_TITLE:-ASUS Zenbook A14 ACPI ROOT16 ($ROOT16_KREL)}"
GRUB_CFG="${A14_GRUB_CFG:-/boot/grub/grub.cfg}"
GRUBENV="${A14_GRUBENV:-/boot/grub/grubenv}"
ARCH_NAME="${A14_ARCH:-arm64}"
JOBS="${A14_JOBS:-$(nproc)}"
SRC_FILE="$SRC/drivers/spmi/spmi-pmic-arb.c"
BACKUP_DIR="$WORK/root16-source-backup"
BACKUP_FILE="$BACKUP_DIR/spmi-pmic-arb.c.before-root16"
SOURCE_PATCH_REPORT="$OWNER_HOME/Downloads/a14-acpi-root16-source.patch"
PREP_REPORT="$OWNER_HOME/Downloads/a14-acpi-root16-prepare.txt"
STATUS_REPORT="$OWNER_HOME/Downloads/a14-acpi-root16-status.txt"

# Avoid the SCM "-dirty" suffix while preserving CONFIG_LOCALVERSION.
export LOCALVERSION=

cfg_val(){
    local cfg="$1" sym="$2"
    grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$cfg" | tail -n1 || true
}

assert_cfg(){
    local cfg="$1" sym="$2" expected="$3" got
    got="$(cfg_val "$cfg" "$sym")"
    case "$expected" in
        y|m)
            [[ "$got" == "CONFIG_${sym}=${expected}" ]] ||
                die "Kconfig assertion failed: $sym expected=$expected got=${got:-MISSING}"
            ;;
        n)
            [[ "$got" == "# CONFIG_${sym} is not set" ]] ||
                die "Kconfig assertion failed: $sym expected=n got=${got:-MISSING}"
            ;;
        *) die "bad expected Kconfig state: $expected" ;;
    esac
    say "ASSERT_CONFIG_${sym}=$expected"
}

clear_next_entry(){
    [[ -f "$GRUBENV" ]] || return 0
    grub-editenv "$GRUBENV" unset next_entry >/dev/null 2>&1 || true
}

assert_unarmed(){
    local envtxt=""
    [[ -f "$GRUBENV" ]] && envtxt="$(grub-editenv "$GRUBENV" list 2>/dev/null || true)"
    if grep -q '^next_entry=.' <<<"$envtxt"; then
        printf '%s\n' "$envtxt" >&2
        die "GRUB next_entry is still armed"
    fi
    say "A14_ACPI_ROOT16_GRUB_NEXT_ENTRY=UNARMED"
}

patch_spmi_source(){
    [[ -f "$SRC_FILE" ]] || die "SPMI source missing: $SRC_FILE"

    if grep -q 'A14_ACPI_SPMI_BOOTSTRAP' "$SRC_FILE"; then
        say "A14_ACPI_ROOT16_SOURCE_PATCH=ALREADY_PRESENT"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    if [[ ! -e "$BACKUP_FILE" ]]; then
        cp -a -- "$SRC_FILE" "$BACKUP_FILE"
        chown "$OWNER:$OWNER" "$BACKUP_FILE" 2>/dev/null || true
    fi

    python3 - "$SRC_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
original = path.read_text()
if "A14_ACPI_SPMI_BOOTSTRAP" in original:
    print("A14_ACPI_ROOT16_SOURCE_PATCH=ALREADY_PRESENT")
    raise SystemExit(0)

text = original

def replace_once(old: str, new: str, label: str):
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"source precondition failed for {label}: matches={n}")
    text = text.replace(old, new, 1)

replace_once(
    "#include <linux/bitfield.h>\n",
    "#include <linux/acpi.h>\n#include <linux/bitfield.h>\n",
    "acpi include",
)

replace_once(
    "#define PMIC_ARB_MAX_BUSES\t\t4\n",
    """#define PMIC_ARB_MAX_BUSES\t\t4

/* A14_ACPI_SPMI_BOOTSTRAP: validated Windows-on-Arm QCOM0C0B/X1E layout. */
#define PMIC_ARB_ACPI_CONF_SIZE\t\t0x34
#define PMIC_ARB_ACPI_CONF_RECORD_SIZE\t0x1a
#define PMIC_ARB_X1E_ACPI_BUS_COUNT\t2
#define PMIC_ARB_X1E_ACPI_WINDOW_SIZE\t0x00500000
#define PMIC_ARB_X1E_CORE_OFFSET\t0x000000
#define PMIC_ARB_X1E_CORE_SIZE\t\t0x003000
#define PMIC_ARB_X1E_OBSRVR_OFFSET\t0x040000
#define PMIC_ARB_X1E_OBSRVR_SIZE\t0x080000
#define PMIC_ARB_X1E_CHNLS_OFFSET\t0x100000
#define PMIC_ARB_X1E_CHNLS_SIZE\t\t0x400000
#define PMIC_ARB_X1E_BUS0_CNFG_OFFSET\t0x02d000
#define PMIC_ARB_X1E_BUS0_INTR_OFFSET\t0x0c0000
#define PMIC_ARB_X1E_BUS1_CNFG_OFFSET\t0x032000
#define PMIC_ARB_X1E_BUS1_INTR_OFFSET\t0x0d0000
#define PMIC_ARB_X1E_BUS_CNFG_SIZE\t0x004000
#define PMIC_ARB_X1E_BUS_INTR_SIZE\t0x010000
""",
    "ACPI constants",
)

replace_once(
    "\tvoid __iomem\t\t*apid_map;\n\tu8\t\t\tchannel;\n",
    "\tvoid __iomem\t\t*apid_map;\n\tvoid __iomem\t\t*acpi_base;\n\tresource_size_t\t\tacpi_size;\n\tbool\t\t\tacpi_bootstrap;\n\tu8\t\t\tchannel;\n",
    "arbiter ACPI state",
)

helper = r'''
#ifdef CONFIG_ACPI
static u32 pmic_arb_acpi_be32(const u8 *p)
{
	return ((u32)p[0] << 24) | ((u32)p[1] << 16) |
	       ((u32)p[2] << 8) | p[3];
}

static int pmic_arb_acpi_validate_conf(struct platform_device *pdev,
					       struct resource *res)
{
	struct device *dev = &pdev->dev;
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *obj;
	const u8 *conf;
	acpi_status status;
	u32 base0, size0, base1, size1;
	int ret = -EINVAL;

	if (!ACPI_HANDLE(dev))
		return -ENODEV;

	status = acpi_evaluate_object(ACPI_HANDLE(dev), "CONF", NULL, &output);
	if (ACPI_FAILURE(status)) {
		dev_err(dev, "A14 ACPI SPMI bootstrap: CONF evaluation failed: %s\n",
			acpi_format_exception(status));
		return -ENODEV;
	}

	obj = output.pointer;
	if (!obj || obj->type != ACPI_TYPE_BUFFER ||
	    obj->buffer.length != PMIC_ARB_ACPI_CONF_SIZE) {
		dev_err(dev, "A14 ACPI SPMI bootstrap: unexpected CONF object/length\n");
		goto out;
	}

	conf = obj->buffer.pointer;
	if (!conf)
		goto out;

	/* Both observed X1E records start with 00 01 01. */
	if (conf[0] != 0x00 || conf[1] != 0x01 || conf[2] != 0x01 ||
	    conf[PMIC_ARB_ACPI_CONF_RECORD_SIZE + 0] != 0x00 ||
	    conf[PMIC_ARB_ACPI_CONF_RECORD_SIZE + 1] != 0x01 ||
	    conf[PMIC_ARB_ACPI_CONF_RECORD_SIZE + 2] != 0x01) {
		dev_err(dev, "A14 ACPI SPMI bootstrap: CONF record headers do not match X1E contract\n");
		goto out;
	}

	base0 = pmic_arb_acpi_be32(conf + 18);
	size0 = pmic_arb_acpi_be32(conf + 22);
	base1 = pmic_arb_acpi_be32(conf + PMIC_ARB_ACPI_CONF_RECORD_SIZE + 18);
	size1 = pmic_arb_acpi_be32(conf + PMIC_ARB_ACPI_CONF_RECORD_SIZE + 22);

	if (resource_size(res) != PMIC_ARB_X1E_ACPI_WINDOW_SIZE ||
	    res->start != (resource_size_t)(u32)res->start ||
	    base0 != (u32)res->start || base1 != (u32)res->start ||
	    size0 != resource_size(res) || size1 != resource_size(res)) {
		dev_err(dev,
			"A14 ACPI SPMI bootstrap: CONF/_CRS mismatch: _CRS=%#llx+%#llx CONF0=%#x+%#x CONF1=%#x+%#x\n",
			(unsigned long long)res->start,
			(unsigned long long)resource_size(res),
			base0, size0, base1, size1);
		goto out;
	}

	dev_info(dev,
		 "A14 ACPI SPMI bootstrap: CONF validated, 2 records, window=%#llx+%#llx\n",
		 (unsigned long long)res->start,
		 (unsigned long long)resource_size(res));
	ret = 0;
out:
	kfree(output.pointer);
	return ret;
}
#endif

'''
replace_once(
    "static int pmic_arb_get_obsrvr_chnls_v2(struct platform_device *pdev)\n",
    helper + "static int pmic_arb_get_obsrvr_chnls_v2(struct platform_device *pdev)\n",
    "ACPI CONF helper insertion",
)

old_obs = '''static int pmic_arb_get_obsrvr_chnls_v2(struct platform_device *pdev)
{
	struct spmi_pmic_arb *pmic_arb = platform_get_drvdata(pdev);

	pmic_arb->rd_base = devm_platform_ioremap_resource_byname(pdev, "obsrvr");
	if (IS_ERR(pmic_arb->rd_base))
		return PTR_ERR(pmic_arb->rd_base);

	pmic_arb->wr_base = devm_platform_ioremap_resource_byname(pdev, "chnls");
	if (IS_ERR(pmic_arb->wr_base))
		return PTR_ERR(pmic_arb->wr_base);

	return 0;
}
'''
new_obs = '''static int pmic_arb_get_obsrvr_chnls_v2(struct platform_device *pdev)
{
	struct spmi_pmic_arb *pmic_arb = platform_get_drvdata(pdev);

	if (pmic_arb->acpi_bootstrap) {
		pmic_arb->rd_base = pmic_arb->acpi_base + PMIC_ARB_X1E_OBSRVR_OFFSET;
		pmic_arb->wr_base = pmic_arb->acpi_base + PMIC_ARB_X1E_CHNLS_OFFSET;
		return 0;
	}

	pmic_arb->rd_base = devm_platform_ioremap_resource_byname(pdev, "obsrvr");
	if (IS_ERR(pmic_arb->rd_base))
		return PTR_ERR(pmic_arb->rd_base);

	pmic_arb->wr_base = devm_platform_ioremap_resource_byname(pdev, "chnls");
	if (IS_ERR(pmic_arb->wr_base))
		return PTR_ERR(pmic_arb->wr_base);

	return 0;
}
'''
replace_once(old_obs, new_obs, "observer/channel ACPI mapping")

old_bus_resources = '''	index = of_property_match_string(node, "reg-names", "cnfg");
	if (index < 0) {
		dev_err(dev, "cnfg reg region missing\\n");
		return -EINVAL;
	}

	cnfg = devm_of_iomap(dev, node, index, NULL);
	if (IS_ERR(cnfg))
		return PTR_ERR(cnfg);

	index = of_property_match_string(node, "reg-names", "intr");
	if (index < 0) {
		dev_err(dev, "intr reg region missing\\n");
		return -EINVAL;
	}

	intr = devm_of_iomap(dev, node, index, NULL);
	if (IS_ERR(intr))
		return PTR_ERR(intr);

	irq = of_irq_get_byname(node, "periph_irq");
	if (irq <= 0)
		return irq ?: -ENXIO;
'''
new_bus_resources = '''	if (pmic_arb->acpi_bootstrap) {
		static const u32 cnfg_offset[PMIC_ARB_X1E_ACPI_BUS_COUNT] = {
			PMIC_ARB_X1E_BUS0_CNFG_OFFSET,
			PMIC_ARB_X1E_BUS1_CNFG_OFFSET,
		};
		static const u32 intr_offset[PMIC_ARB_X1E_ACPI_BUS_COUNT] = {
			PMIC_ARB_X1E_BUS0_INTR_OFFSET,
			PMIC_ARB_X1E_BUS1_INTR_OFFSET,
		};

		if (bus_index >= PMIC_ARB_X1E_ACPI_BUS_COUNT)
			return -EINVAL;

		cnfg = pmic_arb->acpi_base + cnfg_offset[bus_index];
		intr = pmic_arb->acpi_base + intr_offset[bus_index];
		/* ROOT16 intentionally leaves the PDC/peripheral IRQ path inert. */
		irq = 0;
	} else {
		index = of_property_match_string(node, "reg-names", "cnfg");
		if (index < 0) {
			dev_err(dev, "cnfg reg region missing\\n");
			return -EINVAL;
		}

		cnfg = devm_of_iomap(dev, node, index, NULL);
		if (IS_ERR(cnfg))
			return PTR_ERR(cnfg);

		index = of_property_match_string(node, "reg-names", "intr");
		if (index < 0) {
			dev_err(dev, "intr reg region missing\\n");
			return -EINVAL;
		}

		intr = devm_of_iomap(dev, node, index, NULL);
		if (IS_ERR(intr))
			return PTR_ERR(intr);

		irq = of_irq_get_byname(node, "periph_irq");
		if (irq <= 0)
			return irq ?: -ENXIO;
	}
'''
replace_once(old_bus_resources, new_bus_resources, "bus ACPI resources")

old_irq_domain = '''	dev_dbg(&pdev->dev, "adding irq domain for bus %d\\n", bus_index);

	bus->domain = irq_domain_create_tree(of_fwnode_handle(node), &pmic_arb_irq_domain_ops, bus);
	if (!bus->domain) {
		dev_err(&pdev->dev, "unable to create irq_domain\\n");
		return -ENOMEM;
	}

	irq_set_chained_handler_and_data(bus->irq,
					 pmic_arb_chained_irq, bus);

	ctrl->dev.of_node = node;
	dev_set_name(&ctrl->dev, "spmi-%d", bus_index);

	ret = devm_spmi_controller_add(dev, ctrl);
	if (ret)
		return ret;

	pmic_arb->buses_available++;

	return 0;
'''
new_irq_domain = '''	if (!pmic_arb->acpi_bootstrap) {
		dev_dbg(&pdev->dev, "adding irq domain for bus %d\\n", bus_index);

		bus->domain = irq_domain_create_tree(of_fwnode_handle(node),
						     &pmic_arb_irq_domain_ops, bus);
		if (!bus->domain) {
			dev_err(&pdev->dev, "unable to create irq_domain\\n");
			return -ENOMEM;
		}

		irq_set_chained_handler_and_data(bus->irq,
						 pmic_arb_chained_irq, bus);
		ctrl->dev.of_node = node;
	}

	dev_set_name(&ctrl->dev, "spmi-%d", bus_index);

	ret = devm_spmi_controller_add(dev, ctrl);
	if (ret)
		return ret;

	pmic_arb->buses_available++;

	if (pmic_arb->acpi_bootstrap)
		dev_info(dev,
			 "A14 ACPI SPMI bootstrap: spmi-%d registered without PMIC IRQ domain\\n",
			 bus_index);

	return 0;
'''
replace_once(old_irq_domain, new_irq_domain, "IRQ-domain suppression")

old_register = '''static int spmi_pmic_arb_register_buses(struct spmi_pmic_arb *pmic_arb,
					struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *node = dev->of_node;
	int ret;

	/* legacy mode doesn't provide child node for the bus */
'''
new_register = '''static int spmi_pmic_arb_register_buses(struct spmi_pmic_arb *pmic_arb,
					struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *node = dev->of_node;
	int i, ret = 0;

	if (pmic_arb->acpi_bootstrap) {
		for (i = 0; i < PMIC_ARB_X1E_ACPI_BUS_COUNT; i++) {
			ret = spmi_pmic_arb_bus_init(pdev, NULL, pmic_arb);
			if (ret)
				return ret;
		}
		return 0;
	}

	/* legacy mode doesn't provide child node for the bus */
'''
replace_once(old_register, new_register, "ACPI bus registration")

old_deregister = '''		irq_set_chained_handler_and_data(bus->irq,
						 NULL, NULL);
		irq_domain_remove(bus->domain);
'''
new_deregister = '''		if (bus->irq > 0)
			irq_set_chained_handler_and_data(bus->irq, NULL, NULL);
		if (bus->domain)
			irq_domain_remove(bus->domain);
'''
replace_once(old_deregister, new_deregister, "safe deregistration")

old_probe_res = '''	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "core");
	core = devm_ioremap(dev, res->start, resource_size(res));
	if (!core)
		return -ENOMEM;

	pmic_arb->core_size = resource_size(res);

	platform_set_drvdata(pdev, pmic_arb);
'''
new_probe_res = '''	if (has_acpi_companion(dev)) {
#ifdef CONFIG_ACPI
		res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
		if (!res)
			return -ENODEV;

		err = pmic_arb_acpi_validate_conf(pdev, res);
		if (err)
			return err;

		pmic_arb->acpi_base = devm_ioremap_resource(dev, res);
		if (IS_ERR(pmic_arb->acpi_base))
			return PTR_ERR(pmic_arb->acpi_base);

		pmic_arb->acpi_size = resource_size(res);
		pmic_arb->acpi_bootstrap = true;
		core = pmic_arb->acpi_base + PMIC_ARB_X1E_CORE_OFFSET;
		pmic_arb->core_size = PMIC_ARB_X1E_CORE_SIZE;
#else
		return -ENODEV;
#endif
	} else {
		res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "core");
		if (!res)
			return -ENODEV;

		core = devm_ioremap(dev, res->start, resource_size(res));
		if (!core)
			return -ENOMEM;

		pmic_arb->core_size = resource_size(res);
	}

	platform_set_drvdata(pdev, pmic_arb);
'''
replace_once(old_probe_res, new_probe_res, "ACPI probe resource")

replace_once(
    '''	else
		pmic_arb->ver_ops = &pmic_arb_v8;

	err = pmic_arb->ver_ops->get_core_resources(pdev, core);
''',
    '''	else
		pmic_arb->ver_ops = &pmic_arb_v8;

	if (pmic_arb->acpi_bootstrap && pmic_arb->ver_ops != &pmic_arb_v7) {
		dev_err(dev,
			"A14 ACPI SPMI bootstrap: expected v7 arbiter, hardware=0x%x\\n",
			hw_ver);
		return -ENODEV;
	}

	err = pmic_arb->ver_ops->get_core_resources(pdev, core);
''',
    "v7 gate",
)

old_channel = '''	err = of_property_read_u32(pdev->dev.of_node, "qcom,channel", &channel);
	if (err) {
		dev_err(&pdev->dev, "channel unspecified.\\n");
		return err;
	}

	if (channel > 5) {
		dev_err(&pdev->dev, "invalid channel (%u) specified.\\n",
			channel);
		return -EINVAL;
	}

	pmic_arb->channel = channel;

	err = of_property_read_u32(pdev->dev.of_node, "qcom,ee", &ee);
	if (err) {
		dev_err(&pdev->dev, "EE unspecified.\\n");
		return err;
	}

	if (ee > 5) {
		dev_err(&pdev->dev, "invalid EE (%u) specified\\n", ee);
		return -EINVAL;
	}

	pmic_arb->ee = ee;
'''
new_channel = '''	if (pmic_arb->acpi_bootstrap) {
		/* Proven by the working X1E80100 DT and gated by CONF/_CRS above. */
		channel = 0;
		ee = 0;
		dev_info(dev,
			 "A14 ACPI SPMI bootstrap: using X1E channel=%u ee=%u, PMIC IRQs disabled\\n",
			 channel, ee);
	} else {
		err = of_property_read_u32(pdev->dev.of_node, "qcom,channel", &channel);
		if (err) {
			dev_err(&pdev->dev, "channel unspecified.\\n");
			return err;
		}

		err = of_property_read_u32(pdev->dev.of_node, "qcom,ee", &ee);
		if (err) {
			dev_err(&pdev->dev, "EE unspecified.\\n");
			return err;
		}
	}

	if (channel > 5) {
		dev_err(&pdev->dev, "invalid channel (%u) specified.\\n", channel);
		return -EINVAL;
	}
	if (ee > 5) {
		dev_err(&pdev->dev, "invalid EE (%u) specified\\n", ee);
		return -EINVAL;
	}

	pmic_arb->channel = channel;
	pmic_arb->ee = ee;
'''
replace_once(old_channel, new_channel, "ACPI channel/EE")

old_match = '''MODULE_DEVICE_TABLE(of, spmi_pmic_arb_match_table);

static struct platform_driver spmi_pmic_arb_driver = {
'''
new_match = '''MODULE_DEVICE_TABLE(of, spmi_pmic_arb_match_table);

#ifdef CONFIG_ACPI
static const struct acpi_device_id spmi_pmic_arb_acpi_match_table[] = {
	{ "QCOM0C0B", 0 },
	{ }
};
MODULE_DEVICE_TABLE(acpi, spmi_pmic_arb_acpi_match_table);
#endif

static struct platform_driver spmi_pmic_arb_driver = {
'''
replace_once(old_match, new_match, "ACPI match table")

replace_once(
    '''		.name\t= "spmi_pmic_arb",
		.of_match_table = spmi_pmic_arb_match_table,
''',
    '''		.name\t= "spmi_pmic_arb",
		.of_match_table = spmi_pmic_arb_match_table,
		.acpi_match_table = ACPI_PTR(spmi_pmic_arb_acpi_match_table),
''',
    "driver ACPI match pointer",
)

if text == original:
    raise SystemExit("internal error: no source changes produced")
if "A14_ACPI_SPMI_BOOTSTRAP" not in text:
    raise SystemExit("internal error: marker missing after patch")

path.write_text(text)
print("A14_ACPI_ROOT16_SOURCE_PATCH=APPLIED")
PY

    grep -q 'A14_ACPI_SPMI_BOOTSTRAP' "$SRC_FILE" || die "ROOT16 source marker absent after patch"

    diff -u --label spmi-pmic-arb.c.before-root16 --label spmi-pmic-arb.c.root16 \
         "$BACKUP_FILE" "$SRC_FILE" >"$SOURCE_PATCH_REPORT" || true
    chown "$OWNER:$OWNER" "$SOURCE_PATCH_REPORT" 2>/dev/null || true
    say "source_patch_report=$SOURCE_PATCH_REPORT"
}

clone_root14_grub_fragment(){
    [[ -r "$ROOT14_FRAGMENT" ]] || die "ROOT14 GRUB fragment missing: $ROOT14_FRAGMENT"
    [[ -r "$ROOT11_INITRD" ]] || die "proven ROOT11 initrd missing: $ROOT11_INITRD"

    local tmp
    tmp="$(mktemp /tmp/a14-root16-grub.XXXXXX)"
    python3 - "$ROOT14_FRAGMENT" "$tmp" "$ROOT14_KREL" "$ROOT16_KREL" "$ENTRY_TITLE" <<'PY'
import re
import sys
from pathlib import Path

src, dst, oldk, newk, title = sys.argv[1:]
lines = Path(src).read_text(errors="replace").splitlines()
start = next((i for i, line in enumerate(lines) if re.match(r"^\s*menuentry\s+", line)), None)
if start is None:
    raise SystemExit("ROOT14 fragment has no menuentry")
end = next((i for i in range(start + 1, len(lines)) if re.match(r"^\s*}\s*$", lines[i])), None)
if end is None:
    raise SystemExit("ROOT14 fragment menuentry is unterminated")
block = lines[start:end + 1]
if not any(f"vmlinuz-{oldk}" in line for line in block):
    raise SystemExit("ROOT14 fragment does not reference expected ROOT14 kernel")
if any(re.match(r"^\s*devicetree\s+", line) for line in block):
    raise SystemExit("refusing to clone a stanza containing devicetree")

block = [line.replace(f"vmlinuz-{oldk}", f"vmlinuz-{newk}") for line in block]
header = block[0]
m = re.match(r"^(\s*menuentry\s+)(['\"])(.*?)(\2)(.*)$", header)
if not m:
    raise SystemExit("cannot parse ROOT14 menuentry header")
q = m.group(2)
block[0] = f"{m.group(1)}{q}{title}{q}{m.group(5)}".replace(oldk, newk)
linux = [i for i, line in enumerate(block) if re.match(r"^\s*linux(?:efi)?\s+", line)]
if len(linux) != 1:
    raise SystemExit(f"expected one linux line, got {len(linux)}")
idx = linux[0]
if not re.search(r"(^|\s)panic=0(\s|$)", block[idx]):
    block[idx] = block[idx].rstrip() + " panic=0"
if not any("initrd.img-7.1.5-a14-acpi-root11" in line for line in block):
    raise SystemExit("ROOT16 must retain the proven ROOT11 initrd")

out = [
    "#!/bin/sh",
    "# Generated by a14-acpi-root16-spmi-controller-one-go.sh",
    'exec tail -n +4 "$0"',
    "# A14_ACPI_ROOT16_GRUB_FRAGMENT",
    *block,
    "",
]
Path(dst).write_text("\n".join(out))
PY

    if [[ -e "$ROOT16_FRAGMENT" ]] &&
       ! grep -q 'A14_ACPI_ROOT16_GRUB_FRAGMENT' "$ROOT16_FRAGMENT" 2>/dev/null; then
        rm -f "$tmp"
        die "refusing to overwrite non-ROOT16 GRUB fragment: $ROOT16_FRAGMENT"
    fi
    install -m 0755 "$tmp" "$ROOT16_FRAGMENT"
    rm -f "$tmp"
}

verify_root16_grub_entry(){
    [[ -r "$GRUB_CFG" ]] || die "GRUB config missing: $GRUB_CFG"
    python3 - "$GRUB_CFG" "$ROOT16_KREL" "$ENTRY_TITLE" <<'PY'
import re
import sys
from pathlib import Path

cfg, krel, title = sys.argv[1:]
lines = Path(cfg).read_text(errors="replace").splitlines()
needle = f"vmlinuz-{krel}"
matches = []
for i, line in enumerate(lines):
    if needle not in line or not re.match(r"^\s*linux(?:efi)?\s+", line):
        continue
    start = next((j for j in range(i, -1, -1) if re.match(r"^\s*menuentry\s+", lines[j])), None)
    if start is None:
        continue
    end = next((j for j in range(i + 1, len(lines)) if re.match(r"^\s*}\s*$", lines[j])), None)
    if end is None:
        continue
    block = lines[start:end + 1]
    if title in block[0]:
        matches.append(block)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one ROOT16 GRUB entry, found {len(matches)}")
block = matches[0]
if any(re.match(r"^\s*devicetree\s+", line) for line in block):
    raise SystemExit("ROOT16 GRUB entry unexpectedly contains devicetree")
linux = [line for line in block if needle in line and re.match(r"^\s*linux(?:efi)?\s+", line)]
if len(linux) != 1 or not re.search(r"(^|\s)panic=0(\s|$)", linux[0]):
    raise SystemExit("ROOT16 linux line missing or panic=0 absent")
if not any("initrd.img-7.1.5-a14-acpi-root11" in line for line in block):
    raise SystemExit("ROOT16 entry does not retain ROOT11 initrd")
print("A14_ACPI_ROOT16_GRUB_ENTRY=PASS")
print(f"entry_title={title}")
print(linux[0].strip())
PY
}

prepare(){
    for c in bash cat chown cp date diff getent grep grub-editenv install make mktemp \
             nproc python3 sha256sum sync tee update-grub; do
        have "$c" || die "missing command: $c"
    done

    [[ -d "$SRC" && -f "$SRC/Makefile" ]] || die "kernel source missing: $SRC"
    [[ -x "$SRC/scripts/config" ]] || die "kernel scripts/config missing"
    [[ -r "$ROOT14_CONFIG" ]] || die "ROOT14 config missing: $ROOT14_CONFIG"
    [[ -r "$ROOT14_FRAGMENT" ]] || die "ROOT14 GRUB fragment missing: $ROOT14_FRAGMENT"
    [[ -r "$ROOT11_INITRD" ]] || die "ROOT11 initrd missing: $ROOT11_INITRD"

    mkdir -p "$OUT"

    {
        say "A14_ACPI_ROOT16_PREPARE_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "owner=$OWNER"
        say "src=$SRC"
        say "out=$OUT"
        say "root14_config=$ROOT14_CONFIG"
        say "root11_initrd=$ROOT11_INITRD"
        say "root16_krel=$ROOT16_KREL"
        say "stage_scope=QCOM0C0B_controller_only_no_PMIC_IRQ_domain"
        say "image_only=true"
        say "module_build=false"
        say "modules_install=false"
        say "initramfs_update=false"
        say "pdc_programming=false"
        say "pmic_enumeration=false"
        say "reboot_performed=false"

        section "safety: clear stale one-shot boot"
        clear_next_entry
        assert_unarmed

        section "apply transactional ROOT16 SPMI source patch"
        patch_spmi_source
        grep -nE 'A14_ACPI_SPMI_BOOTSTRAP|QCOM0C0B|acpi_bootstrap|CONF validated|without PMIC IRQ domain' "$SRC_FILE" || true

        section "seed ROOT14 config and retag ROOT16"
        cp -- "$ROOT14_CONFIG" "$OUT/.config"
        "$SRC/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "-a14-acpi-root16"
        "$SRC/scripts/config" --file "$OUT/.config" --disable LOCALVERSION_AUTO
        make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" olddefconfig

        assert_cfg "$OUT/.config" ACPI y
        assert_cfg "$OUT/.config" SPMI y
        assert_cfg "$OUT/.config" SPMI_MSM_PMIC_ARB y
        assert_cfg "$OUT/.config" MFD_SPMI_PMIC y
        assert_cfg "$OUT/.config" LEDS_CLASS_FLASH y
        assert_cfg "$OUT/.config" V4L2_FLASH_LED_CLASS n
        assert_cfg "$OUT/.config" LEDS_QCOM_FLASH y
        assert_cfg "$OUT/.config" AUTOFS_FS y
        assert_cfg "$OUT/.config" I2C_CHARDEV y
        assert_cfg "$OUT/.config" I2C_QCOM_CCI y

        section "kernel release"
        local actual_krel
        actual_krel="$(make -s -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" kernelrelease)"
        say "kernelrelease=$actual_krel"
        [[ "$actual_krel" == "$ROOT16_KREL" ]] ||
            die "unexpected kernelrelease: expected=$ROOT16_KREL got=$actual_krel"

        section "Image-only build"
        say "make_target=Image"
        say "jobs=$JOBS"
        make -C "$SRC" O="$OUT" ARCH="$ARCH_NAME" -j"$JOBS" Image
        [[ -s "$OUT/arch/arm64/boot/Image" ]] || die "Image build did not produce Image"
        say "A14_ACPI_ROOT16_IMAGE_BUILD=PASS"

        section "install ROOT16 Image/config only"
        install -m 0644 "$OUT/arch/arm64/boot/Image" "$ROOT16_IMAGE"
        install -m 0644 "$OUT/.config" "$ROOT16_CONFIG"
        if [[ -s "$OUT/System.map" ]]; then
            install -m 0644 "$OUT/System.map" "$ROOT16_SYSTEM_MAP"
        fi
        sync
        say "A14_ACPI_ROOT16_IMAGE_INSTALL=PASS"
        sha256sum "$ROOT16_IMAGE" "$ROOT16_CONFIG"

        section "clone proven ROOT14 GRUB stanza"
        clone_root14_grub_fragment
        update-grub
        verify_root16_grub_entry
        say "A14_ACPI_ROOT16_GRUB_CLONE=PASS"

        section "final safety state"
        clear_next_entry
        assert_unarmed
        say "A14_ACPI_ROOT16_SOURCE_PATCH=PASS"
        say "A14_ACPI_ROOT16_CONFIG=PASS"
        say "A14_ACPI_ROOT16_PREPARE=PASS"
        say "A14_ACPI_ROOT16_READY=UNARMED"
        say "reboot_performed=false"
    } 2>&1 | tee "$PREP_REPORT"

    chown "$OWNER:$OWNER" "$PREP_REPORT" 2>/dev/null || true
}

arm(){
    verify_root16_grub_entry
    [[ -s "$ROOT16_IMAGE" ]] || die "ROOT16 image missing: $ROOT16_IMAGE"
    [[ -r "$ROOT11_INITRD" ]] || die "ROOT11 initrd missing: $ROOT11_INITRD"

    clear_next_entry
    assert_unarmed
    grub-reboot "$ENTRY_TITLE"

    local envtxt
    envtxt="$(grub-editenv "$GRUBENV" list 2>/dev/null || true)"
    printf '%s\n' "$envtxt"
    grep -Fqx "next_entry=$ENTRY_TITLE" <<<"$envtxt" ||
        die "failed to set exact ROOT16 one-shot entry"

    say "A14_ACPI_ROOT16_ARM=PASS"
    say "A14_ACPI_ROOT16_ONE_SHOT_SET=1"
    say "entry=$ENTRY_TITLE"
    say "reboot_performed=false"
    say "MANUAL_REBOOT_REQUIRED=1"
}

status(){
    {
        say "A14_ACPI_ROOT16_STATUS_ENTERED=1"
        say "timestamp=$(date -Is)"
        say "uname=$(uname -a)"
        say "running_kernel=$(uname -r)"
        say "expected_kernel=$ROOT16_KREL"
        say "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"

        if [[ "$(uname -r)" == "$ROOT16_KREL" ]]; then
            say "A14_ACPI_ROOT16_BOOTED=PASS"
        else
            say "A14_ACPI_ROOT16_BOOTED=NO"
        fi

        section "ROOT16 SPMI kernel log"
        dmesg --color=never 2>/dev/null |
            grep -Ei 'A14 ACPI SPMI bootstrap|spmi_pmic_arb|PMIC arbiter|QCOM0C0B|spmi-[01]' |
            tail -n 250 || true

        local dmesg_text
        dmesg_text="$(dmesg --color=never 2>/dev/null || true)"
        grep -q 'A14 ACPI SPMI bootstrap: CONF validated' <<<"$dmesg_text" &&
            say "A14_ACPI_ROOT16_CONF_VALIDATED=PASS" ||
            say "A14_ACPI_ROOT16_CONF_VALIDATED=NOT_SEEN"
        grep -q 'A14 ACPI SPMI bootstrap: spmi-0 registered without PMIC IRQ domain' <<<"$dmesg_text" &&
            say "A14_ACPI_ROOT16_BUS0_REGISTERED=PASS" ||
            say "A14_ACPI_ROOT16_BUS0_REGISTERED=NOT_SEEN"
        grep -q 'A14 ACPI SPMI bootstrap: spmi-1 registered without PMIC IRQ domain' <<<"$dmesg_text" &&
            say "A14_ACPI_ROOT16_BUS1_REGISTERED=PASS" ||
            say "A14_ACPI_ROOT16_BUS1_REGISTERED=NOT_SEEN"

        section "SPMI sysfs"
        if [[ -d /sys/bus/spmi/devices ]]; then
            find /sys/bus/spmi/devices -maxdepth 1 -mindepth 1 -printf '%f -> %l\n' 2>/dev/null | sort || true
        else
            say "SPMI_SYSFS=ABSENT"
        fi
        if [[ -d /sys/class/spmi-master ]]; then
            find /sys/class/spmi-master -maxdepth 1 -mindepth 1 -printf '%f -> %l\n' 2>/dev/null | sort || true
        fi

        section "interrupt safety check"
        grep -Ei 'pmic_arb|PDC[[:space:]]+[13][[:space:]]' /proc/interrupts 2>/dev/null || true
        say "ROOT16_EXPECTATION=no_new_PMIC_irq_domain_and_no_PDC_pin_1_or_3_request"

        section "source marker"
        grep -n 'A14_ACPI_SPMI_BOOTSTRAP' "$SRC_FILE" 2>/dev/null || true

        section "GRUB one-shot state after boot"
        grub-editenv "$GRUBENV" list 2>/dev/null || true

        say "A14_ACPI_ROOT16_STATUS=COMPLETE"
        say "service_mutation=false"
        say "reboot_performed=false"
    } 2>&1 | tee "$STATUS_REPORT"

    chown "$OWNER:$OWNER" "$STATUS_REPORT" 2>/dev/null || true
}

case "$ACTION" in
    prepare) prepare ;;
    arm) arm ;;
    status) status ;;
esac
