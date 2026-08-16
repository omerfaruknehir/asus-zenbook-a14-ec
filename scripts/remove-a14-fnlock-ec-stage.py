#!/usr/bin/env python3
from pathlib import Path

p = Path('asus_zenbook_a14_ec.c')
s = p.read_text()

MARKER = 'A14_FNLOCK_EC_STAGE_DSDT'
if MARKER not in s:
    print('a14_fnlock_ec_stage=absent')
    raise SystemExit(0)

constants = '''\n#define A14_FNLOCK_EC_STAGE_DSDT         1\n#define EC_FNLOCK_STAGE_MAJ              0x02\n#define EC_FNLOCK_STAGE_WMIN             0x84\n#define EC_FNLOCK_STAGE_ACTION_PRIMARY   0x04\n#define EC_FNLOCK_STAGE_FKEY_PRIMARY     0x08\n'''
helper = '''static ssize_t fnlock_firmware_stage_store(struct device *dev,\n\t\t\t\t\t   struct device_attribute *attr,\n\t\t\t\t\t   const char *buf, size_t count)\n{\n\tstruct asus_ec *ec = dev_get_drvdata(dev);\n\tbool fkey_primary;\n\tu8 command;\n\tint ret;\n\n\tret = kstrtobool(buf, &fkey_primary);\n\tif (ret)\n\t\treturn ret;\n\n\tcommand = fkey_primary ? EC_FNLOCK_STAGE_FKEY_PRIMARY :\n\t\t\t\t EC_FNLOCK_STAGE_ACTION_PRIMARY;\n\n\tmutex_lock(&ec->ec_lock);\n\tret = __ec_cw(ec, EC_FNLOCK_STAGE_MAJ, EC_FNLOCK_STAGE_WMIN, command);\n\tmutex_unlock(&ec->ec_lock);\n\tif (ret)\n\t\treturn ret;\n\n\tdev_info(ec->dev,\n\t\t "Fn-lock DSDT firmware stage: state=%u command=0x%02x\\n",\n\t\t fkey_primary, command);\n\treturn count;\n}\n\nstatic DEVICE_ATTR_WO(fnlock_firmware_stage);\n\n'''
attr = '\t&dev_attr_fnlock_firmware_stage.attr,\n'

for token, label in ((constants, 'constants'), (helper, 'helper'), (attr, 'attribute')):
    count = s.count(token)
    if count != 1:
        raise SystemExit(f'cannot remove stale Fn-lock EC stage {label}: expected 1, found {count}')
    s = s.replace(token, '', 1)

if MARKER in s or 'fnlock_firmware_stage' in s:
    raise SystemExit('stale Fn-lock EC stage remains after cleanup')

p.write_text(s)
print('a14_fnlock_ec_stage=removed-disproven-probe')