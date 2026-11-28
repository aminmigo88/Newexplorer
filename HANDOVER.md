# NewExplorer handover

## Release roadmap

| Version | Approved scope |
| --- | --- |
| 0.12.0 | Optimize CAD memory, cancel CAD loading, recover interrupted SMB transfers, improve regression testing, establish shared AI handover. |
| 0.13.0 | Original STEP colors, assembly hierarchy, individual component selection, hide and isolate components, dimensions and measurement tools. |
| 0.14.0 | 7z and encrypted archives, transfer queue, favorite locations, additional tabs, SFTP support. |

## Current work

Development branch `dev/v0.12.0`, candidate build 17. Baseline is v0.11.0 build 16 at `ca2c62f`. The README contains the release history. AGENTS.md has the shared development rules.

## Verification on the intended device

Install with KravaSigner. Compare the same representative STEP and IGES files on builds 16 and 17, including peak memory, shape counts and appearance. Close a complex CAD load, open another file and confirm the viewer responds. Disconnect Wi-Fi during Replace on a disposable Windows share, reconnect using the same address and account, then verify destination and source contents. Pick a Files folder, relaunch, and export a picture from Photos. Record the device, build, files and results here.
