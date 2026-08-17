# OpenBlade capture toolkit

This repository contains commit-safe protocol evidence and the Windows tooling
used to investigate Razer Blade firmware interfaces. It is intentionally
separate from the OpenBlade application repository so raw capture work cannot
accidentally enter a product release.

Start with [CAPTURE_GUIDE.md](CAPTURE_GUIDE.md). It covers a new, unsupported
Blade from inventory through query discovery, isolated oracle captures,
readback, restoration, lifecycle testing, sanitization, and production
admission.

Installed Razer driver packages are tracked separately in the
[`blade-driver-catalog`](https://github.com/OSSBlade/blade-driver-catalog).
That repository is currently private, so the link works only for collaborators.
This repository retains the protocol captures and physical behavior evidence
used to decide whether a cataloged package supports a device capability.

The broader project documentation is maintained in
[`OSSBlade/openblade-docs`](https://github.com/OSSBlade/openblade-docs).

## Toolkit

- `tools/Get-BladeCaptureInventory.ps1`: collect non-unique model, firmware,
  Windows, and Razer USB identities.
- `tools/New-CaptureWorkspace.ps1`: create a local, ignored session with a
  versioned capture plan and operator log.
- `tools/Invoke-InteractiveUsbPcapCapture.ps1`: run USBPcapCMD in an isolated
  process group, stop it through targeted Ctrl+Break, and restore the OpenBlade
  service state. One or more verified device addresses on the same root can be
  selected for bounded cross-device correlation.
- `tools/Convert-UsbPcapToTransactions.ps1`: decode a local PCAP into bounded
  transaction records with tshark.
- `tools/Compare-CaptureTransactions.ps1`: compare baseline and one-action
  captures by a semantic fingerprint that removes transaction IDs, checksums,
  and unused padding from validated 90-byte and 374-byte Razer envelopes while
  retaining command and payload differences.
- `tools/Invoke-CoolingPadFanContextCapture.ps1`: on the exact RZ09-0581 BIOS
  4.00 target, record Synapse-owned Fixed/Auto transitions with lighting frames
  active, with lighting dark in the same Synapse process session, and after a
  verified fresh Synapse process session. OpenBlade remains stopped and sends
  no HID command.
- `tools/Analyze-CoolingPadFanContextCapture.ps1`: compare those three bounded
  marker windows, require exact Fixed/Auto request acknowledgements, count
  lighting frames, and preserve the distinction between process-session
  evidence and unresolved literal HID-handle ownership.
- `tools/New-SanitizedCaptureAnnotation.ps1`: create a commit-safe annotation
  skeleton with hashes and restoration results.
- `tools/Test-CaptureEvidence.ps1`: validate required provenance, redaction,
  bounded evidence, capture hashes, and restoration gates. Use `-PcapPath`
  before committing to verify the local capture; use the explicit `-SchemaOnly`
  mode only when the raw capture is intentionally unavailable.
- `tools/Test-UsbPcapShutdownSafety.ps1`: regression-check that capture shutdown
  cannot broadcast Ctrl+C to the parent console.

Model-named `Analyze-*`, `Export-*`, `Get-*`, `Invoke-*`, and `Start-*` scripts
are exact-device helpers retained as reviewed evidence. They may wrap an
isolated oracle capture, export a bounded fixture, repeat a read-only matrix,
perform a reversible validation, or inspect a verified vendor backend. They
are not generic starting points: do not copy their identities, interfaces,
addresses, hashes, paths, report geometry, or command bytes to another model.

## Evidence ledgers

Keep model coverage separate from individual evidence files:

- `decoded/*-device-coverage.json` is the authoritative per-capability status
  matrix for an exact model and firmware scope.
- `decoded/*-evidence.json` provides a condensed ledger of admitted transport,
  controls, lifecycle behavior, and failure handling when a model has enough
  evidence to warrant one.
- Other `decoded` fixtures contain bounded reports, effect oracles, key maps,
  and validation results. Matching annotations record provenance, isolation,
  restoration, negative results, and limitations.

Advance each coverage leaf independently. Admitting a base control or effect
does not admit every parameter, getter, readback path, or lifecycle. Preserve
partial input evidence when some physical actions are distinguishable and
others are not. Treat installed UI or regression acceptance as product
evidence, not as a new firmware command or device readback.

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
