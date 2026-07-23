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
  captures by normalized payload fingerprint.
- `tools/New-SanitizedCaptureAnnotation.ps1`: create a commit-safe annotation
  skeleton with hashes and restoration results.
- `tools/Test-CaptureEvidence.ps1`: validate required provenance, redaction,
  capture hashes, and restoration gates.
- `tools/Test-UsbPcapShutdownSafety.ps1`: regression-check that capture shutdown
  cannot broadcast Ctrl+C to the parent console.

Existing `Analyze-*`, `Export-*`, and `Invoke-*Validation*` scripts are
model-specific tools retained as reviewed evidence. New models should begin
with the generic workflow rather than copying a validated command from the
RZ09-0581.

## Repository layout

- `annotations`: operator actions, provenance, timing, and safety outcomes.
- `decoded`: sanitized request/response fixtures and analysis summaries.
- `plans`: reviewed, hash-gated interactive validation plans.
- `raw`: ignored local PCAP files. Only `.gitkeep` is committed.
- `templates`: versioned starting documents for new investigations.
- `tools`: capture, decoding, comparison, sanitization, and validation scripts.

Never commit raw PCAP/PCAPNG files, serial numbers, local paths, device-instance
suffixes, usernames, or unreviewed payload streams.

Copy `templates/device-coverage.template.json` when starting a model. Keep each
capability at `NotInvestigated` until its evidence advances it through capture,
query validation, setter validation, and production admission.
