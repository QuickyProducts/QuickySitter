# QuickySitter — Changelog

Customer-facing changes only. Each entry is tagged **Fix** (bug fix) or
**Feature** (new). Routine internal/technical changes are not listed.
Grouped by version, newest on top.

## Version 1.03
- **Fix** — After the furniture had been unused for a while, the first sit in rare cases showed the default sit pose instead of the furniture animation; it now plays on the first sit — no second sit needed to "wake it up"

## Version 1.02
- **Fix** — [QS]select dialog throttle
- **Fix** — [DUMP] no longer freezes when a plugin stops responding; it skips the unresponsive plugin, finishes the dump, and posts a notice naming it
- **Fix** — [DUMP] no longer fails with "too many HTTP requests" on large configs — the output is paced to stay under Second Life's rate limit, so the settings link comes out complete (and warns instead of silently truncating if a limit is ever hit)
