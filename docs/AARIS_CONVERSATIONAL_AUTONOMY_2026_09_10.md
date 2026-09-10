# Aaris Brain conversational autonomy — 10 September 2026

This upgrade closes a key gap between fuzzy search and safe app control. When a
natural-language command produces several plausible local stock rows, Aaris now
keeps a short-lived clarification context containing only the rows already shown
to the pharmacist. Each visible option is bound to the current medicine-row
revision. A follow-up can choose a visible ordinal in English, Hinglish or Hindi,
or an exact batch, barcode, block, row, vertical or location discriminator.

The clarification state is session-only, expires after five minutes and is never
written to inventory. If any candidate is edited, archived, disappears, or the
clock moves backwards, the whole option mapping fails closed. Loose or fuzzy
medicine wording can never resolve a destructive target. A new explicit app
command supersedes the old clarification instead of being trapped by it.

Resolving a choice performs no write. It only resumes the repository's existing
exact-stock workflow, so Remove, SOLD, stock correction, receiving, relocation
and FEFO sale continue to require their current deterministic review,
confirmation, revision and transaction guards.

The deterministic command firewall is also hardened for extra negative wording
(avoid/refrain), 24-hour clock times, calendar dates, relative durations,
weekdays and common dayparts. These future/conditional instructions are blocked
before stock lookup or mutation navigation, preserving the rule that Aaris only
opens an inventory write when the pharmacist is asking for a reviewed action now.
