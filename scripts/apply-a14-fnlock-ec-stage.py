#!/usr/bin/env python3
from pathlib import Path

p = Path('asus_zenbook_a14_ec.c')
s = p.read_text()

MARKER = 'A14_FNLOCK_EC_STAGE_DSDT'
if MARKER in s:
    print('a14_fnlock_ec_stage=current')
    raise SystemExit(0)


def once(old: str, new: str, label: str) -> None:
    global s
    if s.count(old) != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {s.count(old)}')
    s = s.replace(old, new, 1)


once(
    '#define EC_REG_TEMP_MIN                 0x02\n',
    '#define EC_REG_TEMP_MIN                 0x02\n\n'
    '#define A14_FNLOCK_EC_STAGE_DSDT         1\n'
    '#define EC_FNLOCK_STAGE_MAJ              0x02\n'
    '#define EC_FNLOCK_STAGE_WMIN             0x84\n'
    '#define EC_FNLOCK_STAGE_ACTION_PRIMARY   0x04\n'
    '#define EC_FNLOCK_STAGE_FKEY_PRIMARY     0x08\n',
    'constants')

# The Windows DSDT for UX3407RA BIOS 312 implements DEVS(0x00100023, state)
# as ECCW(0x02, 0x84, KFSK | (state ? 0x08 : 0x04)).  The captured Windows
# DSTS value remained 0x00010002, so KFSK was not 0x80 during the reference
# tests.  This deliberately tests the observed KFSK=0 command pair first.  It
# is a root-only probe attribute, not yet the permanent Fn+Esc implementation.
anchor = '''static struct attribute *asus_ec_attrs[] = {\n'''
helper = '''static ssize_t fnlock_firmware_stage_store(struct device *dev,\n\t\t\t\t\t   struct device_attribute *attr,\n\t\t\t\t\t   const char *buf, size_t count)\n{\n\tstruct asus_ec *ec = dev_get_drvdata(dev);\n\tbool fkey_primary;\n\tu8 command;\n\tint ret;\n\n\tret = kstrtobool(buf, &fkey_primary);\n\tif (ret)\n\t\treturn ret;\n\n\tcommand = fkey_primary ? EC_FNLOCK_STAGE_FKEY_PRIMARY :\n\t\t\t\t EC_FNLOCK_STAGE_ACTION_PRIMARY;\n\n\tmutex_lock(&ec->ec_lock);\n\tret = __ec_cw(ec, EC_FNLOCK_STAGE_MAJ, EC_FNLOCK_STAGE_WMIN, command);\n\tmutex_unlock(&ec->ec_lock);\n\tif (ret)\n\t\treturn ret;\n\n\tdev_info(ec->dev,\n\t\t "Fn-lock DSDT firmware stage: state=%u command=0x%02x\\n",\n\t\t fkey_primary, command);\n\treturn count;\n}\n\nstatic DEVICE_ATTR_WO(fnlock_firmware_stage);\n\n'''
once(anchor, helper + anchor, 'sysfs helper')

once(
    'static struct attribute *asus_ec_attrs[] = {\n',
    'static struct attribute *asus_ec_attrs[] = {\n\t&dev_attr_fnlock_firmware_stage.attr,\n',
    'attribute group')

p.write_text(s)
print('a14_fnlock_ec_stage=dsdt-eccw-02-84-04-08')
