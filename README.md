# OpenBlade capture toolkit

This repository contains commit-safe protocol evidence and the Windows tooling
used to investigate Razer Blade firmware interfaces. It is intentionally
separate from the OpenBlade application repository so raw capture work cannot
accidentally enter a product release.

Start with [CAPTURE_GUIDE.md](CAPTURE_GUIDE.md). It covers a new, unsupported
Blade from inventory through query discovery, isolated oracle captures,
readback, restoration, lifecycle testing, sanitization, and production
admission.

The broader project documentation is maintained in
[`OSSBlade/openblade-docs`](https://github.com/OSSBlade/openblade-docs).

## Toolkit

- `tools/Get-BladeCaptureInventory.ps1`: collect non-unique model, firmware,
  Windows, and Razer USB identities.
- `tools/New-CaptureWorkspace.ps1`: create a local, ignored session with a
  versioned capture plan and operator log.
- `tools/Invoke-InteractiveUsbPcapCapture.ps1`: run USBPcapCMD in an isolated
  process group, stop it through targeted Ctrl+Break, and restore the OpenBlade
  service state.
- `tools/Convert-UsbPcapToTransactions.ps1`: decode a local PCAP into bounded
  transaction records with tshark.
- `tools/Compare-CaptureTransactions.ps1`: compare baseline and one-action
  captures by a semantic fingerprint that removes transaction IDs, checksums,
  and unused padding from validated 90-byte and 374-byte Razer envelopes while
  retaining command and payload differences.
- `tools/New-SanitizedCaptureAnnotation.ps1`: create a commit-safe annotation
  skeleton with hashes and restoration results.
- `tools/Test-CaptureEvidence.ps1`: validate required provenance, redaction,
  bounded evidence, capture hashes, and restoration gates. Use `-PcapPath`
  before committing to verify the local capture; use the explicit `-SchemaOnly`
  mode only when the raw capture is intentionally unavailable.
- `tools/Test-UsbPcapShutdownSafety.ps1`: regression-check that capture shutdown
  cannot broadcast Ctrl+C to the parent console.

The `Rz090528` scripts are exact-device helpers for reviewed RZ09-0528 / PID
02C6 work. They are not generic starting points for another model:

- `Start-Rz090528*OracleCapture.ps1` wraps isolated Synapse effect captures;
  `Analyze-Rz090528*Oracle.ps1` and `Export-Rz090528*.ps1` turn the local
  captures into bounded effect and physical-key fixtures.
- `Invoke-Rz090528PowerSourceReadbackMatrix.ps1` runs the read-only barrel AC,
  USB-C, battery, and restored-AC matrix while isolating and restoring the
  installed OpenBlade service.
- `Invoke-Rz090528DeviceModeValidation.ps1` and
  `Invoke-Rz090528GpuClockOffsetValidation.ps1` are interactive reversible
  validations. They save, apply, independently read, and restore exact-device
  state; they must not be treated as probes for another Blade.
- `Get-Rz090528CpuTuningModuleOwnership.ps1` and
  `Invoke-Rz090528CpuTuningLifecycleValidation.ps1` preserve bounded ownership
  and negative lifecycle evidence for the verified Synapse CPU backend. They
  do not admit that backend for production use.

Existing `Analyze-*`, `Export-*`, and `Invoke-*Validation*` scripts are
model-specific tools retained as reviewed evidence. New models should begin
with the generic workflow rather than copying a validated command from the
RZ09-0581, RZ09-0528, or any other Blade.

## RZ09-0528 evidence map

The current exact-device ledger covers RZ09-0528, USB `1532:02C6`, BIOS 2.02,
EC 1.09, and MCU 1.9.0.0. Use these files instead of inferring status from a
tool name or a single successful session:

- [`decoded/rz09-0528-pid-02c6-bios-2.02-device-coverage.json`](decoded/rz09-0528-pid-02c6-bios-2.02-device-coverage.json)
  is the authoritative per-capability status matrix.
- [`decoded/rz09-0528-pid-02c6-bios-2.02-evidence.json`](decoded/rz09-0528-pid-02c6-bios-2.02-evidence.json)
  summarizes the admitted transport, power, performance, fan, battery,
  lighting, behavior, display, and failure-handling evidence.
- The remaining `decoded/rz09-0528-*` files are bounded fixtures for specific
  reports, effect oracles, key maps, and lifecycle results. Their matching
  `annotations/2026-07-*-rz09-0528-*` files record provenance, isolation,
  restoration, and limitations.

Recent evidence admits Off and every visible RZ09-0528 effect base while
keeping effect parameters at their individual coverage levels. There is still
no effect getter or matrix readback. Special-key admission is deliberately
partial: M3, M4, and M5 are production-admitted; M1, M2, and Fn+P remain
captured because their generic reports cannot be distinguished safely. The
media-row annotation records installed-product acceptance for Fn+F1 through
Fn+F3, not a new firmware command.

## Repository layout

- `annotations`: operator actions, provenance, timing, and safety outcomes.
- `decoded`: sanitized request/response fixtures and analysis summaries.
- `plans`: reviewed, hash-gated interactive validation plans.
- `raw`: ignored local PCAP files. Only `.gitkeep` is committed.
- `templates`: versioned starting documents for new investigations.
- `tests`: safe synthetic regression tests that never access live hardware.
- `tools`: capture, decoding, comparison, sanitization, and validation scripts.

Never commit raw PCAP/PCAPNG files, serial numbers, local paths, device-instance
suffixes, usernames, or unreviewed payload streams.

Copy `templates/device-coverage.template.json` when starting a model. Keep each
capability at `NotInvestigated` until its evidence advances it through capture,
query validation, setter validation, and production admission.

Run the offline toolkit regressions after changing schemas, comparison,
sanitization, or coverage:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Run-All.ps1
```

Keep `-NonInteractive` in automated runs. The evidence-validator regression
intentionally verifies that omitting both `-PcapPath` and `-SchemaOnly` fails;
an interactive host would prompt for the missing mandatory parameter instead.
