# Windows AOS front-sensor parameters and INIT576 wire reconstruction

Date: 2026-08-11
Machine: ASUS Zenbook A14 UX3407RA / X1E80100
Windows camera stack: Qualcomm Spectra 695 / qcAlwaysOnSensing

## Why this was revisited

Linux can discover SSC service 400 and the camera-handshake, human-presence and
camera-face-detect SUIDs, but INIT message 576 has timed out waiting for ACK 832
even while the complete Windows CAMP component-0 F0 resource state is held.

After clocks, CCI, ICP, genpd/ICC and the strongest missing QRD MCLK pins were
ruled out, the Windows front-sensor path was reconstructed to check for a
missing AP-side sensor activation or a wire-format mismatch.

## Front-sensor AOS parameter IOCTL

`qcAlwaysOnSensing.dll` opens the Camera Front Sensor device before the Camera
Platform device and issues front-sensor IOCTL:

```text
0x002323ff
```

It supplies no input buffer and requests exactly 0x58 (88) output bytes.
Reverse analysis of `qccamfrontsensor8380.sys` and the consuming AOS DLL gives
the exact structure:

```text
+0x00 u32 revision
+0x04 u32 AosCapability
+0x08 u32 AOSTestMode
+0x0c char AosSensorName[50]
+0x40 u32 AosSensorId
+0x44 u32 HPDClient
+0x48 u32 FDModeIndex
+0x4c u32 FDAlgo
+0x50 u32 FDDelivery
+0x54 u32 HorizontalViewAngle
```

The A14 live registry values captured from `ACPI\\QCOM0C06` are:

```text
revision             = 2 (driver ABI)
AosCapability        = 1
AOSTestMode           = 0
AosSensorName         = ov02c10
AosSensorId           = 2
HPDClient             = 1
FDModeIndex           = 0
FDAlgo                = 2
FDDelivery            = 1
HorizontalViewAngle   = 0x57 = 87 degrees
```

The machine's live `FDDelivery=1` is important: a base INF value of 0 is not the
final machine configuration.

The DLL requires revision 2 and AOS capability 1. It passes sensor name, camera
ID and horizontal FOV to `SetupAOSInitParam()` and caches the remaining mode
fields. No second front-sensor `DeviceIoControl` is used to power or transfer the
sensor before the camera-platform AOS ownership operation. The front-sensor
handle is later closed.

Therefore this IOCTL is a metadata/capability query, not a hidden AP-side
OV02C10 power-on prerequisite.

## QSH-side OV02C10 registry

The machine-specific `qsh_camera_ov02c10_2.json` independently describes the
AOC/SSC-side sensor configuration, including:

```text
bus instance       = 9
slave address      = 0x36
I2C speed          = 400 kHz
reset pin          = 22
DRI pin            = 113
suspend event ID   = 832
resume event ID    = 833
```

and AOC rail clients:

```text
/pmic/client/aoc_avdd
/pmic/client/aoc_dovdd_crd
/pmic/client/aoc_dvdd
```

Those settings belong to the QSH/AOC sensor registry. The Windows AOS DLL does
not receive them in the 0x2323ff front-sensor output and does not directly
program those rails before the CAMP route operation.

## Exact qsh_camera_handshake_init schema

The embedded protobuf descriptor in `qcAlwaysOnSensing.dll` defines:

```text
qsh_camera_handshake_init {
    1: sensor_name
    2: num_restarts_detected_since_last_successful_op
    3: camera_id
    4: sensor_otp_data
}
```

The generated ARM64 parser/serializer independently confirms the wire tags:

```text
field 1 -> tag 0x0a -> sensor_name
field 2 -> tag 0x10 -> integer at object +0x28
field 3 -> tag 0x18 -> integer at object +0x2c
field 4 -> tag 0x22 -> sensor_otp_data
```

## Newly discovered Linux/Windows mismatch

Immediately before serializing the real INIT576 request, the installed Windows
`qcAlwaysOnSensing.dll` constructs the object as follows:

```text
sensor_name = "ov02c10"
num_restarts_detected_since_last_successful_op = 5
camera_id = live AosSensorId = 2
sensor_otp_data = absent
```

The relevant ARM64 sequence sets the field-presence bits for fields 2 and 3,
loads constant `5`, loads the live camera ID from the AOS context, stores the two
32-bit values adjacent at protobuf object offsets +0x28/+0x2c, serializes the
object, then sends message ID 576.

The Linux implementation previously emitted:

```text
0a 07 6f 76 30 32 63 31 30  10 00  18 02
                                  ^^^^^
                                  field 2 = 0
```

The Windows-matched payload is:

```text
0a 07 6f 76 30 32 63 31 30  10 05  18 02
                                  ^^^^^
                                  field 2 = 5
```

This is a real wire-level difference and is safer to discriminate before any
new CPAS ownership-register access.

## Next discriminator

A diagnostic-only build keeps the previous test unchanged except for field 2:

```text
full validated CAMP F0 state
CPAS ownership mux untouched
sensor_name = ov02c10
restart count = 5   <-- only changed variable
camera_id = 2
send INIT576
wait for ACK832
```

Scripts:

```text
scripts/a14-aos-f0-ssc-wireexact-build.sh
scripts/a14-aos-f0-ssc-wireexact-install.sh
scripts/a14-aos-f0-ssc-wireexact-run.sh
```

Do not change the production handshake builder until this A/B discriminator has
returned. If ACK832 appears, the previous Linux restart-count encoding was the
protocol blocker. If ACK832 still times out, the protocol identity is fully
matched and the remaining boundary is the CAMP ownership/protection transition
that Windows performs before QSH takes control.

Direct CPAS reads remain prohibited. No `0x101` ownership write is part of this
wire-exact discriminator.
