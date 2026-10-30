# Security

Reel Client is alpha software. There is no supported stable release or guaranteed response time yet. Security fixes target the current development branch; older development snapshots may not receive backports.

## Report privately

Use the repository's [private vulnerability reporting form](https://github.com/cj-vana/reel-client/security/advisories/new). Include the affected revision/platform, a minimal reproduction, impact and any relevant redacted diagnostics. Use a disposable account and synthetic media.

If the form is unavailable, open a public issue asking for a private security contact **without vulnerability details or sensitive data**. GitHub documents private reporting [here](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).

Do not post credentials, session cookies, personal server URLs, watch history, private media or exploit details in a public issue. Do not test against servers, users or receivers you do not control or have permission to test.

## Areas of interest

Credential disclosure, cross-account data or playback control, unsafe server/redirect handling, gateway authentication scope, local playback-relay boundaries, persistent download recovery, unintended history changes and unsafe handling of untrusted server/media metadata are relevant reports.

Jellyfin, Seerr, Google Cast and operating-system vulnerabilities should also be reported to the respective upstream maintainers. This policy does not grant permission to probe those services or anyone else's infrastructure.
