# AI Agent Handshake

Shared coordination contract for parallel agents working on this repository.

**Live coordination thread:** GitHub issue #456 — `AI Agent Handshake / Coordination Hub`

## 1. Before you touch code

1. Read this file.
2. Read the latest comments in issue #456.
3. Check current `main` and your branch divergence.
4. Post a `STATUS` comment in issue #456 with:
   - branch / PR
   - exact goal
   - files you expect to touch
   - tests you plan to run
   - any contract/schema change you think is required
5. If another active workstream overlaps those files or contracts, coordinate before editing.

## 2. Shared ownership rule

Prefer one active owner per overlapping high-risk file or contract at a time. High-risk surfaces include:

- `app/src/main/java/com/aaris/remoteassist/ai/*`
- `app/src/main/java/com/aaris/remoteassist/webrtc/*`
- `app/src/main/java/com/aaris/remoteassist/control/*`
- `cloudflare/mcp-worker.js`
- Cloudflare signaling/TURN code
- release/version files

Parallel work is fine when the workstreams are orthogonal. If they overlap, coordinate in issue #456 and explicitly state who owns integration.

## 3. Current canonical contracts

### AI/MCP action contract

Do not silently fork the Android and MCP schemas.

Current canonical two-finger fields:

- first pointer: `x`, `y`, `toX`, `toY`
- second pointer: `secondX`, `secondY`, `secondToX`, `secondToY`

Existing safety invariants remain authoritative:

- exactly one admitted AI action per MCP call
- single-use observation tickets
- fresh-pixel + semantic target validation
- geometry generation / lease validation
- local-only sensitive input handling
- explicit user STOP must cancel execution
- action-id replay/idempotency protection

### Realtime video/control contract

`main` already uses freshness-first WebRTC and adaptive cadence. Preserve current behavior unless replacing it with measured, tested evidence.

Current cadence ladder includes the 45 FPS intermediate rung:

`60 -> 45 -> 30 -> 24 -> 20 -> 15`

Severe pressure / CPU limitation may deliberately skip the soft 45 FPS rung for stronger freshness relief.

Cloudflare is control/signaling/TURN infrastructure; primary video remains WebRTC rather than being proxied as a Worker video stream.

## 4. Active integration direction

Current integration branch:

`chatgpt/finalize-realtime-ai-hands-199`

Purpose: carry forward only the unique, still-useful improvements from older parallel realtime/AI branches while preserving the newer `main` contracts.

Currently intended unique changes:

- reduce maximum animated AI observation settle from 320 ms to 220 ms while retaining fresh-frame/semantic validation
- allow cautious faster cadence recovery only when real controller presentation/EGL feedback proves end-to-end health
- preserve current 45 FPS adaptive rung and current MCP/Android action naming

Do not resurrect older `gesture_path`/two-finger field variants or old cadence ladders just because they exist on stale branches.

## 5. Status comment format

Use issue #456 comments instead of repeatedly editing this file for chat.

```text
STATUS
branch: <branch>
pr: <number or none>
goal: <one sentence>
files: <paths>
contracts touched: <none or list>
tests planned: <commands/workflows>
blockers: <none or details>
```

## 6. Handoff format

When pausing, finishing, or asking another agent to integrate:

```text
HANDOFF
branch: <branch>
pr: <number or none>
latest commit: <sha>
what changed: <short summary>
tests actually run: <exact evidence>
not tested: <anything still unverified>
merge state: <safe / needs rebase / conflicts / do not merge>
remaining risks: <list>
next owner: <branch/workstream or unassigned>
```

## 7. Merge rules

- Never force-push `main`.
- Never blindly merge a branch that is behind/diverged from `main`.
- Reconcile schemas and behavior first; do not resolve conflicts by simply picking one side.
- Preserve newer tested behavior when an older branch duplicates it.
- Prefer a clean integration branch from current `main` when a stale branch has mixed useful and obsolete changes.
- State which tests actually ran. Never describe unrun tests as passing.
- Physical two-device smoothness is not proven by unit tests alone; distinguish algorithm/build validation from handset validation.

## 8. Communication rule

This file is the durable protocol and current high-level state. **Issue #456 is the live append-only conversation log.** Agents should talk there rather than racing to edit this file. Update this file only when the shared contract or integration direction changes.
