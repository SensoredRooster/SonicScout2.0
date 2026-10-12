# Optional Wave Link installation blocker

Date: October 12, 2026. Evidence: user-supplied installation report screenshots from SENSOR... (machine name omitted here). After the restart, components, assets, managed configuration, audio service and virtual-endpoint APO registration were READY. The only component UPDATE was Elgato Wave Link detected but not selected. Final verification therefore returned 2 and the batch did not launch SonicScout.

Cause: final verification treats every UPDATE stage as incomplete, while the optional unselected mixer branch emitted UPDATE. The branch now emits INFO. Required audio-route, assets, configuration and APO checks remain unchanged.

Verification: Windows PowerShell 5.1 isolated control-flow regression reproduces a healthy cable installation with Wave Link present but unselected and now returns 0. All nine regression scenarios pass; output retained in regressions.txt. No host drivers or routing were changed. A successful retry on the user's physical PC remains to be confirmed.

Existing published packages need the updated tools/SonicScoutCSharp/setup_audio_stack.ps1 copied beside Install-SonicScout.bat, or a new publish from the updated source.

## VERIFY SETTINGS dialog resource failure

A subsequent user screenshot showed an unexpected-error dialog: SetupReadyBrush resource not found. PostInstallVerifyDialog built its machine-probe checklist inside the constructor, before MainWindow assigned its owner and copied theme resources. Checklist creation now happens once on Loaded, with safe fallback brushes when a theme key is absent. An unbuilt checklist cannot report AllConfirmed.

The real product dialog was tested in an isolated WPF harness with missing theme resources and with theme resources supplied after construction. Both scenarios open four rows, remain unverified and do not duplicate rows on another Loaded event. These tests only read machine audio state; no drivers, routing or settings were changed. The full app build passed with zero warnings/errors. Evidence: verification-dialog-test.txt and build-verification-dialog.txt. The professional installer EXE and automatic APO attachment are still outstanding work.
