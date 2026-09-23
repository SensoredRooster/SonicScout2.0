# SonicScout2.0 Support & Diagnostics

SonicScout2.0 includes a local-first support system built into the WPF application.

## Included support functions

- Rotating JSONL runtime telemetry under `%LOCALAPPDATA%\SonicScout\logs`
- One-second session heartbeat
- Session IDs for correlating tester reports
- WPF dispatcher, AppDomain, and unobserved Task exception capture
- Runtime health snapshot including app version, Windows version, .NET version, process architecture, elevation state, free disk space, and support paths
- Main-window **Diagnostics** button
- Native **Support & Diagnostics** WPF window
- **Create Support Bundle**
- **Send Diagnostics to Developer** with explicit user confirmation
- **Open Logs Folder**
- **Report Issue**
- **Open Repository**
- Redacted routing configuration snapshot
- No raw audio capture in support bundles
- Dedicated Cloudflare Worker + dedicated R2 bucket
- Per-IP upload rate limiting
- ZIP-only upload validation and bundle-size limit
- Admin-protected bundle listing/download endpoints
- Windows/.NET CI build validation

## Privacy

Nothing is uploaded automatically. A tester must click **Send Diagnostics to Developer** and confirm the prompt.

The bundle does not contain recorded audio or headphone/profile audio content. It contains support logs, the runtime diagnostic manifest, and a redacted routing configuration when available.

## Cloudflare isolation

This project uses:

- Worker: `sonicscout2-support`
- R2 bucket: `sonicscout2-support-logs`

It does not share diagnostic storage with RCM Tool, SubScript, or Universal AI Studio.

The deployment workflow requires only the `CLOUDFLARE_API_TOKEN` GitHub Actions secret. The Cloudflare account ID is non-secret and is stored in the Wrangler/deployment configuration.
## Production Cloudflare services

- Diagnostics Worker: `https://sonicscout2-support.sensoredrooster-com.workers.dev`
- Diagnostics R2: `sonicscout2-support-logs`
- Tester Share: `https://sonicscout2-share.sensoredrooster-com.workers.dev`
- Tester Share R2: `sonicscout2-share`

The built-in collector is active by default; `SONICSCOUT_SUPPORT_UPLOAD_URL` remains a development override. The WPF Support window includes a **TESTER SHARE** button that opens the authenticated portal.

