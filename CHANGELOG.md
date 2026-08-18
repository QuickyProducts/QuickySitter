# QuickySitter — Changelog

Customer-facing changes only. Each entry is tagged **Fix** (bug fix) or
**Feature** (new). Routine internal/technical changes are not listed.
Grouped by version, newest on top.

## Unreleased

- **Feature**: Groundwork for Remote authoring, the Creator Edition feature that lets you build an animesh scene while standing instead of sitting. Two things had to change on the sitter side: a prop (and the HUD itself) can now be handed to someone who occupies no seat at all, and the Adjust access level from `[SECURITY]` decides who may open such a session, exactly as it already decides who may use the seated adjust tools. On furniture without the security plugin the chat shortcut `/5 adjust owner|group|all` sets the same level. Nothing changes for a piece that is only sat on
- **Fix**: The `[DUMP]` link is repeated when the dump finishes. Until now the completion line only said the link was final, while the link itself had been printed before the dump started, so on a large piece you had to scroll back through hundreds of lines to find it. Both the success and the failure line now carry it, and in the failure case it is the more useful of the two, because it shows you what did arrive

## Version 1.27
- **Feature**: New build tool `[QS]AVpos-shifter`, the QuickySitter version of the AVsitter AVpos shifter. It moves every pose and prop in an AVpos notecard by an offset (`/5 <0,0,1.5>`), turns them (`/6 <0,0,180>`), or rebases the whole notecard onto another prim you touch. Three things are better than in the original: the "Settings copy" link at the end works again, because it posts to the QuickySitter dump service instead of the old avsitter.com page that stopped accepting our output; it reminds you to run `[HELPER]` `[DUMP]` into the notecard first, since positions you saved with `[SAVE]` live in the furniture and not in the notecard, so shifting without that step would convert old numbers and throw your saved ones away; and it no longer deletes itself after each run, so you can shift twice without fetching a fresh copy. It disappears with `/5 cleanup` together with the other build tools
- **Fix**: Seats are handed out by gender again on furniture whose AVpos has a stray space at the end of a `SITTER` line. That space was read as part of the gender letter, so the seat counted as "no gender set" and a woman was put into the next female seat instead of the first one (F2 before F, with the second woman then getting F). Such lines are common in notecards that came from the original AVsitter kit, where the space is ignored. After updating, re-save the AVpos notecard once so the furniture re-reads it

## Version 1.26
- **Feature**: The [QUICKYHUD] entry in the [ADJUST] menu is now called [HELPER HUD]. It sits right next to [HELPER] and does the same job with the HUD instead of the helper bars, so the name now says what the button is for. Nothing else changes: same access rules, same adjust mode, and creator scripts listening for the old name keep working
- **Feature**: New owner chat shortcut for the Adjust access level, `/5 adjust owner`, `/5 adjust group` or `/5 adjust all`. Same setting as [SECURITY] > Adjust, but it also works on furniture that does not have the security plugin in it, so a store-owned piece can be opened up for your building account without adding scripts
- **Feature**: The Adjust access level is now only offered on furniture that still has the adjust tools in it. Once you finalize a piece with `/5 cleanup` there is no adjust workflow left to gate, so the entry drops out of the [SECURITY] menu
- **Fix**: The `/5 helper` chat command works again. It had silently done nothing since the 0.910 menu rework and now opens the helper bars for the avatar in the first seat, exactly like the [HELPER] button

## Version 1.25
*Version numbers of QuickySitter and the QuickySitter Pro creator kit are
unified from this release on — QuickySitter jumps from 1.04 to 1.25 to meet
the kit. Same product, no release was skipped.*

- **Feature** — Prop scale & worn-fit support: props equipped with the [QS]objectadjust script (drop it into your prop next to [AV]object) can be resized in the editor, or fitted directly on the body for attachment props, and saved with [SAVE]. No more take-back-and-replace loop. Owners can also fine-tune a rezzed prop's size by touch (±1/5/10 % menu, [RESTORE])
- **Feature** — New "Adjust" access level in the [SECURITY] menu (OWNER / GROUP / ALL, default OWNER): lets chosen non-owners use the adjust tools ([HELPER] and the QuickyHUD adjust mode) — handy when a store account owns the furniture but you build from your personal account (set it to GROUP and both accounts just need the store group)
- **Feature** — The [DUMP] settings-copy web page now shows the familiar classic AVsitter layout: all pose and menu lines together, position data grouped below
- **Fix** — [DUMP] no longer lists the internal "QSDYN" entries the Quicky HUD registers for its automatic attach, so they stop showing up as bogus PROP lines when you paste a dump back into the AVpos notecard (the HUD recreates them on demand; already-pasted lines keep working and simply vanish from the next dump)
- **Fix** — The [HELPER] [DUMP] "Settings copy" link now uses the QuickySitter dump service; the old avsitter.com page it pointed to no longer works

## Version 1.04
- **Feature** — Plugins can now add their own buttons to the [ADJUST] menu. Used by the new QuickyHUD Animesh partner-dummy plugin (set up couples / group poses without a second avatar)

## Version 1.03
- **Fix** — The first sit after the furniture had been idle a while now plays the proper animation right away (in rare cases it could show the default pose until you re-sat)

## Version 1.02
- **Fix** — [QS]select dialog throttle
- **Fix** — [DUMP] no longer freezes when a plugin stops responding; it skips the unresponsive plugin, finishes the dump, and posts a notice naming it
- **Fix** — [DUMP] no longer fails with "too many HTTP requests" on large configs — the output is paced to stay under Second Life's rate limit, so the settings link comes out complete (and warns instead of silently truncating if a limit is ever hit)
