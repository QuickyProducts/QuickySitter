# QuickySitter — Changelog

Customer-facing changes only. Each entry is tagged **Fix** (bug fix) or
**Feature** (new). Routine internal/technical changes are not listed.
Grouped by version, newest on top.

## Version 1.25
*Version numbers of QuickySitter and the QuickySitter Pro creator kit are
unified from this release on — QuickySitter jumps from 1.04 to 1.25 to meet
the kit. Same product, no release was skipped.*

- **Feature** — New "Adjust" access level in the [SECURITY] menu (OWNER / GROUP / ALL, default OWNER): lets chosen non-owners use the adjust tools ([HELPER] and the QuickyHUD adjust mode) — handy when a store account owns the furniture but you build from your personal account (set it to GROUP and both accounts just need the store group)
- **Feature** — The [DUMP] settings-copy web page now shows the classic AVsitter layout: all pose and menu lines together, position data grouped below — much easier to edit large AVpos notecards (add `&raw=1` to the link for the old interleaved stream)
- **Fix** — The [HELPER] [DUMP] "Settings copy" link now uses the QuickySitter dump service; the old avsitter.com page it pointed to no longer works
- **Feature** — Prop scale & worn-fit support: props equipped with the [QS]propadjust script (part of the QuickyHUD bundle) can be resized in the editor — or fitted directly on the body for attachment props — and saved with [SAVE], no more take-back-and-replace loop. Owners can also fine-tune a rezzed prop's size by touch (±1/5/10 % menu, [RESTORE])

## Version 1.04
- **Feature** — Plugins can now add their own buttons to the [ADJUST] menu. Used by the new QuickyHUD Animesh partner-dummy plugin (set up couples / group poses without a second avatar)

## Version 1.03
- **Fix** — The first sit after the furniture had been idle a while now plays the proper animation right away (in rare cases it could show the default pose until you re-sat)

## Version 1.02
- **Fix** — [QS]select dialog throttle
- **Fix** — [DUMP] no longer freezes when a plugin stops responding; it skips the unresponsive plugin, finishes the dump, and posts a notice naming it
- **Fix** — [DUMP] no longer fails with "too many HTTP requests" on large configs — the output is paced to stay under Second Life's rate limit, so the settings link comes out complete (and warns instead of silently truncating if a limit is ever hit)
