# Runtime ordering check

The generated `hid_asus_ec` module calls `asus_a14_cycle_native_profile()`, exported by `asus_zenbook_a14_ec`.

Required service ordering:

- load: `asus_zenbook_a14_ec` -> `hid_asus_ec`
- unload: `hid_asus_ec` -> `asus_zenbook_a14_ec`

This ordering is intentional. The EC module is still delayed until the Qualcomm I2C controller exists, so the HID module must not be allowed to autoload the EC dependency before that guard completes.
