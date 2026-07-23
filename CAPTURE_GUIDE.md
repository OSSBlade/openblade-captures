# Capturing an unsupported Razer Blade

This runbook is for protocol research on a Razer Blade model that OpenBlade does
not yet support. It does not authorize firmware writes. A command becomes a
production capability only after the complete admission gate in this document
passes for the exact model and firmware family.

## Safety model

1. Work on native Windows 11 with the .NET SDK, Wireshark/tshark, USBPcap, and
   the vendor application used only as an oracle.
2. Keep the OpenBlade service stopped while USBPcap owns the target interface.
   The generic capture runner records and restores its prior service state.
3. Capture one operator action at a time. Never infer a command from a nearby
   model or combine exploratory writes.
4. Discover and implement read/query operations before testing a setter.
5. For every write validation, save the prior confirmed state, show the exact
   proposed change, require operator confirmation, apply once, query it, and
   restore the saved state.
6. Stop USBPcap only through the supplied isolated-process-group helper. Never
   call `GenerateConsoleCtrlEvent` with group `0`; that broadcasts to the parent
   console and can terminate Codex or PowerShell.
7. Raw captures stay local. USB traffic can contain serials, unique instance
   paths, keystrokes, and unrelated device data.

## 1. Prepare the machine

Install:

- .NET 10 SDK
- Wireshark with tshark
- USBPcap
- the current vendor software for this laptop, temporarily

Verify the shutdown regression before any real capture:

```powershell
.\tools\Test-UsbPcapShutdownSafety.ps1
```

Create a non-unique inventory:

```powershell
.\tools\Get-BladeCaptureInventory.ps1 `
  -OutputPath .\raw\my-model\inventory.json
```

Review the output. It must contain the Razer model number, BIOS, Windows build,
and VID/PID pairs, but not the machine serial number or full PnP instance
suffixes. Record EC and MCU versions from a trustworthy UI or a later validated
query; do not guess them.

## 2. Create a local session

```powershell
$session = .\tools\New-CaptureWorkspace.ps1 `
  -RootDirectory .\raw `
  -ModelNumber RZ09-XXXX `
  -VendorId 1532 `
  -ProductId 0000 `
  -BiosVersion 0.00 `
  -Purpose "battery charge limit query"
```

The command creates an ignored directory containing:

- `capture-plan.json`: exact target, preconditions, action, expected observation,
  prior-state, readback, and restoration fields;
- `operator-log.md`: timestamps and notes;
- empty `baseline` and `action` directories.

Complete the plan before capture. Use a new session for every changed value.

## 3. Identify USBPcap root and device address

Run USBPcapCMD's device listing from an elevated terminal and match the target
by its USB hardware identity. Device addresses can change after reconnect,
resume, or reboot, so resolve them again for every session. If identity is
ambiguous, stop. Do not capture all devices merely to avoid identifying the
target.

The capture runner accepts `-AllDevices` only for descriptor discovery. An
action capture should use a single `-DeviceAddress`.

## 4. Capture baseline and one action

Start the baseline capture from an elevated PowerShell:

```powershell
.\tools\Invoke-InteractiveUsbPcapCapture.ps1 `
  -UsbPcapDevice \\.\USBPcap3 `
  -DeviceAddress 2 `
  -OutputDirectory $session.BaselineDirectory
```

Leave the relevant vendor page idle for several seconds, then create the
`capture.stop` sentinel shown by the runner. Repeat in the action directory,
changing exactly one value once and leaving enough quiet time before and after
the action.

The runner:

- starts USBPcapCMD with `CREATE_NEW_PROCESS_GROUP`;
- records PID, process-group ID, start time, executable, and output ownership;
- signals only that nonzero group with `CTRL_BREAK_EVENT` from a detached,
  protected worker;
- verifies graceful exit and nonempty output; and
- restores the OpenBlade service only if it was running before capture.

The interactive runner never chooses forced termination automatically. If
graceful shutdown fails, an operator may explicitly run
`Stop-UsbPcapCapture.ps1 -ForceFallback` against the retained ownership session.
Forced termination may lose buffered packets and must be disclosed in the
annotation.

## 5. Decode and compare

```powershell
.\tools\Convert-UsbPcapToTransactions.ps1 `
  -PcapPath $session.BaselinePcap `
  -OutputPath (Join-Path $session.Root "baseline-transactions.json")

.\tools\Convert-UsbPcapToTransactions.ps1 `
  -PcapPath $session.ActionPcap `
  -OutputPath (Join-Path $session.Root "action-transactions.json")

.\tools\Compare-CaptureTransactions.ps1 `
  -BaselinePath (Join-Path $session.Root "baseline-transactions.json") `
  -ActionPath (Join-Path $session.Root "action-transactions.json") `
  -OutputPath (Join-Path $session.Root "comparison.json")
```

The generic decoder retains frame number, relative time, direction, endpoint,
setup fields, bounded payload hex, and length. Treat its output as raw until it
has been reviewed and sanitized. A payload difference is a candidate, not a
command definition. The comparer recognizes checksum-valid 90-byte and
374-byte Razer envelopes, with or without a report-ID prefix. It ignores the
transaction ID, checksum, reserved bytes, and unused padding, but retains
status, report ID, command class/ID, payload length, and semantic payload.
Unknown or malformed payloads fall back to exact full-payload comparison.

Correlate candidates with:

- the exact operator timestamp;
- a repeated capture of the same value;
- a different value in the same control;
- a no-action negative capture; and
- the corresponding read/query traffic.

Identify the report envelope, transaction ID, command class/ID, payload length,
checksum, response status, and which bytes encode the value. Remove unrelated
interrupt input and periodic telemetry.

## 6. Build a query-first fixture

A commit-safe query fixture records:

- model number, VID, PID, BIOS, EC, and MCU when known;
- interface/collection and report ID;
- sanitized request and expected response;
- payload bounds and checksum interpretation;
- transaction correlation and accepted status;
- capture hash and decoder version; and
- negative evidence from nearby traffic.

Implement the query in a typed developer command. The command must verify exact
device identity, reject malformed or mismatched responses, impose a timeout,
and expose no arbitrary payload option.

Run the query repeatedly across:

- service restart;
- device reconnect;
- sleep/resume;
- AC, USB-C, and battery when relevant; and
- vendor software running and stopped.

Query failure must degrade to unavailable without writing.

## 7. Validate a setter

Do not use the generic capture scripts to replay bytes. Add a reviewed typed
validation plan under `plans`, hash-gate its exact bytes in the developer tool,
and present the plan before execution.

The interactive runner must:

1. verify the exact model, PID, and accepted firmware;
2. query and display the prior state;
3. display the exact one-value mutation and restoration;
4. require confirmation;
5. apply one value;
6. query readback and compare it;
7. restore the prior value in `finally`;
8. query restoration and compare it; and
9. emit a bounded result with no raw traffic.

If a getter does not exist, the command remains setter-only and cannot be
profiled, automatically reapplied, or labeled as current state. Visual
confirmation alone does not replace restoration.

## 8. Coverage matrix

Investigate only controls present on the target, but explicitly mark every row
as supported, absent, software-only, or not investigated.

Copy `templates/device-coverage.template.json` for the target. Its schema-2
nested matrix tracks each power context, USB-C power class, lighting variant,
color/duration/direction/region group, lifecycle event, conflict behavior, and
failure mode independently. Mark a missing target feature `Absent`; do not
delete the row or collapse several variants into one status.

| Area | Minimum capture set |
| --- | --- |
| Identity | descriptors, model, BIOS, EC, MCU, relevant interfaces |
| Performance | every AC/USB-C/battery preset, Custom levels, readback |
| Fans | Auto, fixed range endpoints and step, maximum, manual writes, RPM query |
| Battery | protection off, every advertised limit, temporary full charge, query |
| Keyboard lighting | Off, brightness, each effect, all colors/durations/directions/regions |
| Logo lighting | every mode and getter |
| Keyboard behavior | Fn-primary, Gaming mode, startup animation, device mode |
| Special keys | raw reports for every Fn-layer or dedicated hardware action |
| Display | Windows-visible modes, DRR, HDR, color-profile behavior |
| Lifecycle | cold boot, sign-in, service restart, sleep/resume, reconnect |
| Power | full AC, each supported USB-C class, battery, transitions |
| Conflicts | vendor controller present, external change, explicit reclaim |
| Failures | timeout, malformed response, wrong transaction, unsupported PID |

For effects or controls with multiple variants, capture every variant rather
than assuming a bit flag. For host-rendered effects, capture both the setup
command and enough frame traffic to establish matrix format and cadence.

## 9. Sanitize and validate

Create an annotation skeleton:

```powershell
.\tools\New-SanitizedCaptureAnnotation.ps1 `
  -PlanPath (Join-Path $session.Root "capture-plan.json") `
  -StatePath (Join-Path $session.ActionDirectory "capture.state.json") `
  -PcapPath $session.ActionPcap `
  -OutputPath .\annotations\YYYY-MM-DD-action.json
```

Replace placeholders with reviewed, bounded evidence. Never paste an entire
payload stream. Set `action.kind` to `ReadOnlyQuery`, `SettingChange`,
`Observation`, or `NegativeControl`; every `SettingChange` needs successful
prior-state, apply, readback, restoration, and restoration-readback results.
Use the provenance role `OracleCapture`, `ReadOnlyQueryCapture`,
`NegativeCapture`, `ExactDeviceInteractiveValidation`, or
`OpenBladeTypedValidation`, and include the controller name and version.
Each `sanitizedEvidence` item needs a short `kind`, a human-readable `summary`,
and only the bounded fields necessary to reproduce the protocol conclusion.
Then run:

```powershell
.\tools\Test-CaptureEvidence.ps1 `
  -AnnotationPath .\annotations\YYYY-MM-DD-action.json `
  -PcapPath $session.ActionPcap
```

The validator rejects missing provenance, empty or all-device captures without
disclosure, forced shutdown without disclosure, missing restoration outcomes,
local paths, serial-like values, unbounded evidence, and raw capture
extensions. `-PcapPath` is the pre-commit gate: it verifies the stored SHA-256
and byte length against the local raw capture. When reviewing an already
committed annotation without its intentionally untracked PCAP, use the explicit
`-SchemaOnly` mode; it validates schema and redaction but reports that the PCAP
hash was not independently verified.

Run the safe offline regressions after changing the toolkit:

```powershell
.\tests\Run-All.ps1
```

## 10. Production admission

A capability is ready for the OpenBlade production table only when all of these
are independently true:

- exact model/PID/firmware scope is explicit;
- at least one sanitized oracle capture is committed;
- request and response decode deterministically;
- checksum, bounds, transaction ID, status, and timeout are validated;
- the typed query works without vendor processes;
- the typed setter applies the requested value;
- readback matches;
- prior state restores and readback confirms restoration;
- unsupported devices and firmware produce zero writes;
- conflict policy produces the intended zero-write or explicit-reclaim result;
- lifecycle and power-state tests pass; and
- unit tests use the committed fixture.

Anything short of this remains capture evidence or a developer-only probe, not
an advertised control.
