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

## Engineering evidence

- Five fixtures (STEP box, IGES box, IGES wire, 500-sphere STEP and IGES assemblies) produced byte-identical coordinate buffers against build 16. Assembly counts were 324,000 and 220,000 triangles respectively. Native Linux OCCT 7.8.1 test, separate from the iOS build's OCCT 7.9.3.
- A Swift 5.10.1 Linux harness compared the old and new coordinate lifetimes through CPU-side geometry buffer preparation. Five fresh processes per format and version, alternating order. Median peak RSS was 106.3 to 94.8 MiB for STEP and 93.3 to 86.2 MiB for IGES. SceneKit, GPU and iPhone memory are outside these measurements.
- In-flight native STEP reads returned cancellation when requested at 10, 80 and 150 ms, and the following box opened successfully. OCCT's initial ReadFile call checks the token on return. Do not promise instantaneous interruption in that phase.
- Recovery records are written under Application Support before remote changes. Reconciliation runs on listing the same host, account, share and folder. An ambiguous publication preserves the old item under a visible recovery name. Records from installations before build 17 do not exist.
- Device validation, comparison of rendered output on iPhone and live Windows disconnect checks are pending. Simulator and IPA evidence belongs to the candidate's GitHub Actions run.
