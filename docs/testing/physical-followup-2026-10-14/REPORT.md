# Physical-PC installation failure — 2026-10-14

Status: unresolved on the reporting PC. Pause broader tester distribution while this failure is diagnosed. Prior VM qualification remains historical evidence; it does not establish that this installation succeeded.

The user's screenshot shows missing ReaPlugs, failed JSFX installation, incomplete cable APO registration, missing managed configuration and a pending driver restart. It shows the saved-profile panel, not the headphone catalog search results. Catalog failure is therefore not yet established by this screenshot.

The available shell currently reports hostname BNAIL. It cannot see `C:\Program Files\SonicScout` or the reporting PC's SonicScout logs. The reporting machine and actual download error are requested from the user. No host audio configuration has been changed by this investigation.

The official ReaPlugs download succeeded from BNAIL on October 14: 1,192,256 bytes, SHA256 `1654F1F78D746FC87A6F6D078A8F928EA61C7B49997B1F2C07DFC870F8FA6C10`, matching the package validation hash. This establishes availability from this machine, not the cause of failure on the reporting PC.

## Confirmed code defect and correction

Setup continued into APO/plugin configuration even when required ReaPlugs or HeSuVi installation returned false. This allowed a missing component to produce a secondary JSFX/configuration error. Setup now waits for both required components before attempting configuration. A failed automatic download directs users to retry SETUP or create a Diagnostics support bundle, instead of instructing them to place installer files manually.

A controlled regression removes a required ReaPlugs DLL in a temporary fake installation, places a marker in the configuration helper, and verifies that setup returns incomplete without executing that helper. It also checks the prerequisite status message. Installation regressions pass. This code correction has not yet been packaged into a replacement EXE or exercised on the reporting PC.

## Required evidence and remaining work

Obtain the current Diagnostics ZIP or the `download-reaplugs-*-errors.txt` contents from the reporting PC. Identify its running package and the precise download failure; fix that cause, rebuild the EXE, and verify installation and catalog opening on that PC before restoring broader tester-readiness status.
