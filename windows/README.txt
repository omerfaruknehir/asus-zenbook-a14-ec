ASUS ZENBOOK A14 WINDOWS FIRMWARE TRACE COLLECTOR
=================================================

Purpose
-------
This collector records how Windows, MyASUS, and ASUS System Control Interface
control these functions on the ASUS Zenbook A14 UX3407RA:

1. Function Key Lock
2. Microphone mute and its physical indicator
3. Camera privacy and its physical indicator

It does not flash firmware and does not send experimental hardware commands.
You perform only the normal MyASUS and keyboard actions shown by the script.

How to run
----------
1. Boot Windows.
2. Extract this ZIP to a normal folder.
3. Double-click Start-Collector.cmd.
4. Approve the Administrator prompt.
5. Follow each on-screen step exactly.
6. The finished ZIP will be placed on your Desktop.

Process Monitor
---------------
The collector looks for the ARM64 Process Monitor binary first. If Process
Monitor is missing, it offers to download the official Microsoft Sysinternals
package from:

https://download.sysinternals.com/files/ProcessMonitor.zip

Declining is allowed. The collector will still gather WPR, registry, device,
driver, ACPI, and before/after state evidence.

What the output contains
------------------------
- A short Process Monitor .pml trace
- A Windows Performance Recorder .etl trace
- Precise action timestamps
- ASUS service and driver inventory
- Exported ASUS driver packages
- Copies of relevant signed ASUS service/driver binaries
- ACPI firmware tables
- MyASUS package information
- Before/after Registry and PnP device snapshots
- Relevant Windows event logs

Privacy
-------
The archive can contain process names, local file paths, Registry values,
device identifiers, and signed ASUS binaries. It is never uploaded
automatically. Review the archive before sharing it.

For best evidence
-----------------
- Ensure MyASUS and ASUS System Control Interface work normally in Windows.
- Keep other applications closed during the short action trace.
- Do not repeatedly press Fn+Esc; follow the exact prompts.
- In the camera step, keep the Windows Camera app open.
