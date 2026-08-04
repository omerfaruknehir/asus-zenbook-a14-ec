# Safety and recovery

The direct EC module talks to the controller at I²C address `0x5b`. A warm-boot
hang was reported when the original proof of concept was autoloaded during
early boot and left controller state inherited by the next kernel.

This fork mitigates that failure in three layers:

1. the packaged EC module is loaded late by systemd rather than from
   `modules-load.d`;
2. the built driver has a platform `.shutdown()` callback that restores
   automatic fan control before reboot or poweroff;
3. the first direct EC transaction is delayed by 1.5 seconds by default.

The keyboard HID module does not use the raw EC I²C path and may load normally.

## Recovery

At the bootloader, select a kernel where the DKMS module is not installed, or
append `systemd.mask=asus-zenbook-a14-ec.service` to the kernel command line.
A complete power-off clears controller state more reliably than a warm reboot.

Manual PWM values `1-74` are rejected because they are below the measured spin
floor. `0` remains available for deliberate fan stop, while normal quiet mode
uses PWM 80 rather than forcing both fans off.
