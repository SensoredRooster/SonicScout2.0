# Optional Wave Link installation blocker

Date: October 12, 2026. Evidence: user-supplied installation report screenshots from SENSOR... (machine name omitted here). After the restart, components, assets, managed configuration, audio service and virtual-endpoint APO registration were READY. The only component UPDATE was Elgato Wave Link detected but not selected. Final verification therefore returned 2 and the batch did not launch SonicScout.

Cause: final verification treats every UPDATE stage as incomplete, while the optional unselected mixer branch emitted UPDATE. The branch now emits INFO. Required audio-route, assets, configuration and APO checks remain unchanged.

Verification: Windows PowerShell 5.1 isolated control-flow regression reproduces a healthy cable installation with Wave Link present but unselected and now returns 0. All nine regression scenarios pass; output retained in regressions.txt. No host drivers or routing were changed. A successful retry on the user's physical PC remains to be confirmed.

Existing published packages need the updated tools/SonicScoutCSharp/setup_audio_stack.ps1 copied beside Install-SonicScout.bat, or a new publish from the updated source.

## VERIFY SETTINGS dialog resource failure

A subsequent user screenshot showed an unexpected-error dialog: SetupReadyBrush resource not found. PostInstallVerifyDialog built its machine-probe checklist inside the constructor, before MainWindow assigned its owner and copied theme resources. Checklist creation now happens once on Loaded, with safe fallback brushes when a theme key is absent. An unbuilt checklist cannot report AllConfirmed.

The real product dialog was tested in an isolated WPF harness with missing theme resources and with theme resources supplied after construction. Both scenarios open four rows, remain unverified and do not duplicate rows on another Loaded event. These tests only read machine audio state; no drivers, routing or settings were changed. The full app build passed with zero warnings/errors. Evidence: verification-dialog-test.txt and build-verification-dialog.txt. The professional installer EXE and automatic APO attachment are still outstanding work.

## Diagnostics window and SonicPass error capture

The user's Diagnostics action failed while loading SupportWindow. A literal backslash-n text node between two WrapPanel buttons was interpreted as an invalid UIElementCollection entry. Replaced it with an actual newline. The real dialog now constructs and shows all seven support buttons in a WPF harness with support-service operations stubbed; no upload or external navigation occurred.

SonicPass stderr was redirected and read asynchronously without a handler, discarding the failure details. The app now records stderr with input/output IDs in errors.jsonl, records startup identification/format output, and records process-launch exceptions. Existing support bundles include errors.jsonl. A harmless child executable emitting an injected startup failure verified the real TryStartSonicPass method forwards stderr into support logging. Evidence: support-dialog-test.txt, sonicpass-error-capture-test.txt and build-support-dialog.txt (0 warnings/errors).

This fixes diagnostic access and preserves the next failure reason; it does not establish the cause of the user's SonicPass audio failure. A physical-PC retry and updated support bundle are still needed. Full audio functionality and the professional installer remain incomplete.
