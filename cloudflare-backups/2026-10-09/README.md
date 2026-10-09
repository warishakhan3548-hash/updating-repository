# Pre-change recovery snapshot (2026-10-09)

This branch was created from GitHub main commit `82eec6fd2493dbac3ec3b97e4ab2e088b78f94be` before further changes, and contains a read-only copy of two Cloudflare Workers' downloaded JavaScript modules and non-secret settings. The backup operation **did not deploy** any Worker, update `main`, or merge a PR.

**Workers**: `aaris-phone-mcp` and `aaris-remote-ice`. The `metadata.json` file alongside each Worker contains compatible settings, bindings (without secret values), triggers and recent deployment IDs.

**Recovery**: restore GitHub from the preserved commit. For Cloudflare, first attempt rollback to the recorded deployment/version using Cloudflare's dashboard/API. If restoring from the JS files instead, use the Worker modules together (respecting imports), copy non-secret settings from `metadata.json`, restore secret values from their secure location, and deploy deliberately. The source snapshot alone **does not** back up secret values or Durable Object/KV/D1 data.

Snapshot captured UTC: 2026-10-09T18:04:00.498Z
