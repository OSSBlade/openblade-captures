# OpenBlade capture agent guide

This repository contains protocol evidence and capture tooling, not production
device-control code.

- Keep raw PCAP, PCAPNG, USB ownership state, serial numbers, device-instance
  suffixes, usernames, and local paths out of Git.
- Use one baseline and one operator action per session.
- Treat traffic differences as candidates, never as validated commands.
- Investigate reads before writes. A write needs exact device scope, prior-state
  capture, confirmation, apply, readback, restoration, and restoration readback.
- Never run OpenBlade control and USBPcap against the same interface.
- Never use `GenerateConsoleCtrlEvent` with process group `0`. Launch USBPcapCMD
  with `CREATE_NEW_PROCESS_GROUP` and target its nonzero group with Ctrl+Break.
- Do not reuse a command from another Blade model without model-specific
  capture and validation.
- Use Conventional Commits with lowercase imperative summaries, for example
  `feat(capture): add unsupported-model inventory tool`.
- Run `tools/Test-UsbPcapShutdownSafety.ps1` after changing capture process
  ownership or shutdown code.
- Run `tools/Test-CaptureEvidence.ps1` before committing a new schema-2
  annotation.
