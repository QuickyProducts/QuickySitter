string version = "0.05";   // qs2 dev scheme; 2.0x is reserved for the release

/*
 * [QS]boot - QuickySitter loader
 *
 * v2 FORK of qs/[QS]boot.lsl 1.27. The parser is untouched: the notecard
 * format did not change, and the whole point of the v2 base set is that
 * it reads the schema this file already writes. Every difference is
 * marked "v2 FORK ONLY". They are:
 *
 *   1. It ANNOUNCES COMPLETION, on 90430 QSB_READY. v1 never did. The
 *      base scripts polled qs:meta:<ch> from their own state_entry and
 *      simply lost the race whenever boot finished after them, which is
 *      why seat/core/menu each carried a linkset_data watcher as a
 *      stand-in. Both paths announce: the fresh parse at the end of
 *      finalize_boot, and the skip-seed path once it has confirmed the
 *      cached table is complete.
 *
 *   2. The self-check counts THREE base scripts, not two, and finds two
 *      of them through qs:alive:* instead of a probe. See the QSALIVE
 *      block below for why only one script may answer 90096.
 *
 *   3. The skip-seed path wipes ^qs:alive: and re-runs the CENSUS, which
 *      v1 only did on a fresh parse. It has to, now that the self-check
 *      reads those flags rather than live replies.
 *
 * Pure one-shot LSD writer. On state_entry:
 *   • if qs:boot:asset matches the AVpos notecard's current asset-key
 *     → already seeded, skip re-parse (the base set reads LSD directly)
 *   • else → parse AVpos notecard, write qs:cfg:<ch>, qs:sitter:<ch>,
 *            qs:p:<ch>:<i>, qs:meta:<ch>, finally qs:boot:asset
 *
 * After seeding, boot is idle until the notecard's asset-key changes
 * (changed(CHANGED_INVENTORY) wipes qs:* and resets) or storage is
 * wiped (qs:boot:asset is gone → next state_entry re-seeds).
 *
 * No pose dispatching. seat, core and menu read LSD directly. Boot is
 * the sole source of LSD writes during seed; the adjuster writes LSD for
 * live creator edits at runtime, independently.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string notecard_name = "AVpos";

// Verbose convention (project-wide):
//   Out(0, …)  errors + warnings (default — support-feedback floor, always shown)
//   Out(1, …)  boot banners — first user-visible "ready" line
//   Out(2, …)  runtime status ("Loading...", pose-switch reports)
//   Out(3, …)  debug — chatty, only when AVpos has `VERBOSE 3`
//   OutForce(…) bypasses verbose entirely; reserved for security/license
//                messages that must never be silenceable.
// Default verbose=0 (silent except errors); AVpos `VERBOSE n` directive
// overrides via qs:cfg:verbose LSD key (boot parses + writes, plugins
// read on state_entry).
integer verbose = 0;
Out(integer level, string msg)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + msg);
}
OutForce(string msg)
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + msg);
}
// The [DUMP] pipeline (readout, plugin cascade, web upload) lived here
// until 0.05 and now is [QS]dump - an authoring-time script that ships
// and leaves with the adjuster. boot only seeds; dump reads it back.
// QSDUMP discovery (90094/90095) moved with it.

// QS_ALIVE_CENSUS — boot broadcasts this on plugin add/remove (a
// CHANGED_INVENTORY with the notecard asset key unchanged). Each presence
// plugin re-writes its qs:alive:<name> LSD flag in response; a removed
// plugin can't, so its flag stays cleared — that's the removal detection.
// The wipe + this broadcast run synchronously in changed(), so every
// survivor's re-write is a strictly later event (no clear-vs-rewrite
// race). See PROTOCOL.md § qs:alive. prop presence is now read directly
// from qs:alive:prop in self_check_report (still rename-safe — the key is
// name-stable, unlike a literal "[QS]prop" inventory probe).
integer QS_ALIVE_CENSUS = 90079;

// QS_BOOT_RELOAD — broadcast at the end of the seed cascade so already-
// running sitB scripts re-read MENU_LIST from the freshly-written LSD
// instead of staying on the stale list from their last state_entry.
// Without this, a notecard re-save requires manual reset on every sitB.
integer QS_BOOT_RELOAD = 90023;

// QS_BOOT_WIPE — broadcast BEFORE the LSD wipe + llResetScript when a
// notecard re-save invalidates the seeded state. sitA / sitB receive
// and flip boot_done / iBooted back to FALSE so their pre-boot guards
// (sitA's link_message/changed `!boot_done return`, sitB slot-0's
// CHANGED_LINK eject) re-engage during the re-seed window. Without
// this signal, sitter scripts kept serving stale MENU_LIST / pose
// data between the wipe and the QS_BOOT_RELOAD that fires at the end
// of finalize_boot.
integer QS_BOOT_WIPE = 90024;

// v2 FORK ONLY. The v2 base wire; see qs2/PROTOCOL.md.
//
// Only READY exists here. QSB_RELOAD (90431) is declared in the base
// scripts but boot never sends it, because boot has no state in which
// "re-read now" is true and "the table is complete" is not: a notecard
// re-save runs through QS_BOOT_WIPE and a full re-parse, and telling the
// base scripts to re-read in the middle of that would hand them a
// half-built table. READY at the end of both paths covers it.
integer QSB_READY  = 90430;   // LSD is seeded and complete, re-read it


// Boot self-check - verifies the minimum base scripts are present in the
// linkset, plus a conditional warn if the notecard has PROP* directives
// but [QS]prop is missing. Fires from finalize_boot (fresh-boot) or
// state_entry's skip-seed branch as soon as all three base scripts have
// reported (via try_complete_selfcheck), with a 10s safety-net timer for
// the no-reply case.
//
// v2 FORK: v1 checked sitA and sitB and had a probe pair for each
// (90096/90097 and 90077/90078). The v2 base set is three singletons and
// only ONE of them may answer QSALIVE, because hudadmin sizes its
// SITTERS list from that single reply. So [QS]core answers the probe,
// and seat and menu prove themselves by stamping qs:alive:* during the
// CENSUS - the same mechanism the plugins already use, which keeps this
// free of both a second QSALIVE answerer and any script-name probe.
//
// The stamp is an LSD write, not a link message, so the early exit hangs
// off linkset_data rather than link_message. Both boot paths wipe
// ^qs:alive: before broadcasting the CENSUS, which is what makes a
// removed script read as removed instead of as permanently present.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;

// v2 FORK ONLY. The base set is three singletons instead of 2N sitA/sitB
// instances, and only one of them can answer QSALIVE: hudadmin sizes its
// SITTERS list from that single reply, so a second answerer would break
// the HUD. [QS]core answers it, which leaves seat and menu needing a
// different proof of life.
//
// They use the qs:alive:* flags, the same mechanism the plugins already
// use, so no new wire number appears and no script-name probe comes back
// (that convention is why the sitter count moved into the notecard in
// the first place). finalize_boot already wipes ^qs:alive: and
// broadcasts QS_ALIVE_CENSUS, so the flags are re-stamped from scratch
// on every boot and a removed script really does read as removed.
//
// QS_SITB_PROBE / QS_SITB_HELLO (90077/90078) are gone with sitB.
integer core_seen;
integer has_prop_in_notecard;
integer selfcheck_pending;

// Settings parsed from notecard (one set, applied to every channel).
integer MTYPE;
integer ETYPE = 1;
integer SET = -1;
integer SWAP = 2;
integer AMENU = 2;
integer SELECT;
integer OLD_HELPER_METHOD;
integer WARN = 1;
integer HASKEYFRAME;
integer REFERENCE;
integer DFLT = 1;
string BRAND;
string onSit;
string CUSTOM_TEXT;
list ADJUST_MENU;
string RLVDesignations;
list GENDERS;

// v2 FORK ONLY, stage 2 (DESIGN.md �11). Parallel lists, one entry per
// ITEM line: the name a prim description addresses it by, and the first
// global channel it owns. The count is derived at flush time from the
// next item.s first channel, so it needs no third list.
list item_names;
list item_first;

// AUTOSYNC ticker. Owned here (rather than in [QS]hudproxy) because
// hudproxy is bytecode-tight under 6-sitter stress; boot is mostly idle
// after seed completes and has plenty of headroom for a periodic timer.
// State written via the QPP_CFG:AUTOSYNC LSD key (unprotected) — the
// hudproxy settings dialog is the writer; we react via linkset_data.
// Coexists with the seed timer via the bAutoSyncActive flag: TRUE only
// after finalize_boot, FALSE during seeding.
integer bAutoSyncActive;

// Per-channel parse state. Reset on each SITTER directive.
integer current_channel = -1;
list SITTER_INFO;
// Per-sitter pose-entry counter. Used as the LSD index for the next
// qs:p:<ch>:<i> write and (via qs_seed_find) for reverse-lookup of
// {Posename}<pos><rot> defaults. Replaces a `list seed_names` whose
// per-item Mono overhead capped boot at ~470 entries per sitter.
integer seed_count;

// Cursor for qs_seed_find. Sequential {Posename} defaults
// (the common pattern: {Pose1}{Pose2}…{PoseN} right after a sitter's
// POSE block) used to re-scan from index 0 every time = O(N²).
// With the hint the second-and-later lookups start where the previous
// match landed = O(N) total. Reset per channel in reset_channel_locals().
integer seed_find_hint;

// Page-oriented menu sidecar (additive, dormant until the sitB page-rebuild
// reads it; see MENU_REBUILD_PLAN.md § 1/§ 8). Computed in the same single
// parse pass:
//   qs:nm:<ch>:<mi>     = childCount of the section opened by marker <mi>
//                         (mi = -1 is the root section). Lets the rebuild read
//                         total_items in O(1) instead of walking to the next M:.
//   qs:nt:<ch>:<ti>     = the MENU index a TOMENU at <ti> navigates to. O(1)
//                         submenu-enter instead of a name scan.
//   qs:cfg:slots:<ch>   = entry count (replaces llGetListLength(MENU_LIST)).
// open_marker = index of the section currently being filled (-1 = root); its
// childCount is written when the next M: marker or the channel end is reached.
integer open_marker;
// TOMENUs awaiting their matching MENU section (the M: is emitted *after* its
// T: in seed order), strided-2 [key, tomenuIndex]; key = label minus the 2-char
// T:/M: prefix. Sized by submenu count (dozens), not pose count — safe as RAM
// (unlike the retired full seed_names list). Reset per channel.
list tomenu_pending;

// Last-published progress percentage from qs_loading_text. Skipping
// llSetText calls when the integer pct hasn't moved cuts ~95% of the
// per-line floating-text refreshes on large notecards (one update per
// 1% step instead of one per notecard line). Reset to -1 in start_boot
// so the first call always paints.
integer last_pct = -1;

// Mirror stock AVsitter sitA's parser locals exactly so the parsing flow
// is byte-for-byte identical. They aren't used by boot, but having them
// ensures we don't accidentally diverge from the reference behavior.
string FIRST_POSENAME;
string FIRST_ANIMATION_SEQUENCE;
string CURRENT_POSE_NAME;
string CURRENT_ANIMATION_SEQUENCE;
string MALE_POSENAME;
string FIRST_MALE_ANIMATION_SEQUENCE;
string FEMALE_POSENAME;
string FIRST_FEMALE_ANIMATION_SEQUENCE;
vector FIRST_POSITION;
vector FIRST_ROTATION;
vector DEFAULT_POSITION;
vector DEFAULT_ROTATION;
vector CURRENT_POSITION;
vector CURRENT_ROTATION;

// Boot orchestration. total_channels emerges at notecard EOF as
// current_channel + 1 (count of SITTER directives seen). boot_done flips
// TRUE in finalize_boot — arm_autosync gates on it. boot_failed flips on
// LSD-memfull during seeding; wipe_attempted records that we've already
// offered (and the user accepted) a full LSD wipe, so a second memfull
// in the same run skips the dialog and surfaces "AVpos too large".
integer total_channels;
integer boot_done;
integer boot_failed;
integer wipe_attempted;

// Low-storage watchdog. The linkset_data event fires in this script on
// EVERY LSD write anywhere in the linkset, so boot (the LSD lifecycle
// owner) is the one central place that sees every writer — adjuster
// pose saves, HUD configs, plugins — without touching any of them.
// One-shot warning once free space drops below LSD_LOW_WATER; re-armed
// only after deletes/a wipe lift it back above twice the threshold
// (hysteresis, no spam). Boot's own seeding passes through here too, so
// an oversized AVpos warns BEFORE qs_lsd_write hits hard memfull.
integer LSD_LOW_WATER = 4096;
integer lsd_low_warned;

// Wipe-confirmation dialog state. dialog_channel is per-instance random.
integer dialog_channel;
integer dialog_handle;

// Notecard cursor.
key notecard_query;
key reused_key;
key notecard_key;
integer reused_variable;
integer notecard_lines;

// SEP = U+FFFD. Initialized at runtime via llUnescapeURL because the
// SL script editor mangles a literal U+FFFD to 0x20 (space) on upload,
// which silently splits anim names containing spaces.
string SEP;

// ========================================================================
// LSD layout helpers
// ========================================================================

string qs_p_key(integer ch, integer i)
{
    return "qs:p:" + (string)ch + ":" + (string)i;
}

// Memfull-aware LSD write. Sets boot_failed on memfull (llLinksetDataWrite
// return = 2 — literal here because the named constant for this return
// code is not portable across SL viewer versions). Surfaces a dialog
// offering a full llLinksetDataReset() — or, if the user already accepted
// a wipe and we're retrying, declares the notecard too large. Cheap to
// call on every write: no extra cost on success.
show_wipe_dialog()
{
    dialog_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    dialog_handle  = llListen(dialog_channel, "", llGetOwner(), "");
    llDialog(llGetOwner(),
        "Storage full during boot.\n\nWipe entire storage?\n\nWARNING: all storage entries (including QPP_CFG/AUTOSYNC and HUD configs) will be lost.",
        ["Wipe", "Cancel"],
        dialog_channel);
}

qs_lsd_write(string k, string v)
{
    if (boot_failed) return;
    if (llLinksetDataWrite(k, v) != 2) return;  // 2 = memfull
    boot_failed = TRUE;
    llSetText("ERROR: storage full during boot", <1, 0, 0>, 1);
    if (wipe_attempted)
    {
        Out(0, "ERROR: storage full after wipe - " + notecard_name + " too large; reduce poses/sitters.");
        return;
    }
    Out(0, "ERROR: storage full at " + k + " - see wipe dialog.");
    show_wipe_dialog();
}

qs_p_write(integer ch, integer i, string name, string type, string anim, string pos, string rot)
{
    qs_lsd_write(qs_p_key(ch, i), name + "|" + type + "|" + anim + "|" + pos + "|" + rot);
}

// Write the open section's child count (qs:nm) and re-point open_marker at the
// boundary that closed it — the new marker's index during parse, or seed_count
// at the channel end. childCount = entries strictly between open_marker and the
// boundary; for the root section (open_marker = -1) that is simply the boundary.
qs_close_section(integer ch, integer end_idx)
{
    qs_lsd_write("qs:nm:" + (string)ch + ":" + (string)open_marker, (string)(end_idx - open_marker - 1));
    open_marker = end_idx;
}

// Reverse-lookup a seed name to its qs:p:<ch>:<i> index. Replaces the
// `llListFindList(seed_names, ...)` calls that the parser used for
// {Posename}<pos><rot> default-offset resolution. Tries the bare name
// first, then with a "P:" prefix — same fallback order as the original
// two-call sequence. Returns -1 on miss.
//
// Scan order uses seed_find_hint as the starting index, then wraps to
// 0..hint-1. For the common sequential-defaults case ({Pose1}{Pose2}…)
// each lookup advances the hint past the last match, so total work
// is O(N) instead of the O(N²) a from-zero scan would cost.
integer qs_seed_find(integer ch, string nm)
{
    integer i;
    string  v;
    string  n;
    // Phase 1: from hint forward.
    for (i = seed_find_hint; i < seed_count; ++i)
    {
        v = llLinksetDataRead(qs_p_key(ch, i));
        n = llGetSubString(v, 0, llSubStringIndex(v, "|") - 1);
        if (n == nm) { seed_find_hint = i + 1; return i; }
    }
    // Phase 2: wrap to 0..hint-1.
    for (i = 0; i < seed_find_hint; ++i)
    {
        v = llLinksetDataRead(qs_p_key(ch, i));
        n = llGetSubString(v, 0, llSubStringIndex(v, "|") - 1);
        if (n == nm) { seed_find_hint = i + 1; return i; }
    }
    // Phase 3: try with "P:" prefix — full scan, hint not updated
    // (this is the fallback path; matches are sparse, so caching the
    // index would hurt the next sequential lookup more than it helps).
    nm = "P:" + nm;
    for (i = 0; i < seed_count; ++i)
    {
        v = llLinksetDataRead(qs_p_key(ch, i));
        n = llGetSubString(v, 0, llSubStringIndex(v, "|") - 1);
        if (n == nm) return i;
    }
    return -1;
}

string qs_str_replace(string s, string find, string replace)
{
    return llDumpList2String(llParseStringKeepNulls(s, [find], []), replace);
}

string qs_cfg_pack()
{
    return llDumpList2String(
        [ MTYPE, ETYPE, SET, SWAP, SELECT, AMENU, OLD_HELPER_METHOD
        , WARN, HASKEYFRAME, REFERENCE, DFLT
        , BRAND, onSit
        , qs_str_replace(CUSTOM_TEXT, "\n", "\\n")
        , llDumpList2String(ADJUST_MENU, SEP)
        , RLVDesignations
        , llList2CSV(GENDERS)
        ], "\n");
}

// Render bar. 20-cell bar sliced from a pre-built constant.
// Throttled by last_pct: only repaints when the integer percentage
// moves, so the dataserver hot-path doesn't burn frame-time on
// llSetText / string-builds for every notecard line.
qs_loading_text(integer cur, integer total, string msg)
{
    if (total <= 0) total = 1;
    integer pct = cur * 100 / total;
    if (pct > 100) pct = 100;
    if (pct == last_pct) return;
    last_pct = pct;
    integer filled = pct / 5;
    string bar = llGetSubString("████████████████████░░░░░░░░░░░░░░░░░░░░", 20 - filled, 39 - filled);
    llSetText(msg + "\n[" + bar + "] " + (string)pct + "%", <1, 1, 0>, 1);
}

reset_channel_locals()
{
    SITTER_INFO = [];
    seed_count = 0;
    seed_find_hint = 0;
    open_marker = -1;
    tomenu_pending = [];
    FIRST_POSENAME = "";
    FIRST_ANIMATION_SEQUENCE = "";
    CURRENT_POSE_NAME = "";
    CURRENT_ANIMATION_SEQUENCE = "";
    MALE_POSENAME = "";
    FIRST_MALE_ANIMATION_SEQUENCE = "";
    FEMALE_POSENAME = "";
    FIRST_FEMALE_ANIMATION_SEQUENCE = "";
    FIRST_POSITION = ZERO_VECTOR;
    FIRST_ROTATION = ZERO_VECTOR;
}

// ========================================================================
// Boot state machine — single-pass notecard read
// ========================================================================

// Flush the channel we just finished parsing (called at SITTER N>0 with
// current_channel = N-1, and at EOF with current_channel = last seen).
// qs:cfg/qs:meta are deferred until EOF because GENDERS accumulates
// across all SITTER directives.
flush_channel_sitter(integer ch)
{
    qs_lsd_write("qs:sitter:" + (string)ch, llDumpList2String(SITTER_INFO, SEP));
    // Close the channel's final open section (root if it had no submenus, else
    // the last M:) and publish the entry count. Additive sidecar (see decls).
    qs_close_section(ch, seed_count);
    qs_lsd_write("qs:cfg:slots:" + (string)ch, (string)seed_count);
}

// Done seeding. QSB_READY at the end of this tells the base set to read
// what we just wrote. No reset needed.
finalize_boot()
{
    total_channels = current_channel + 1;

    // v2 FORK ONLY, stage 2. qs:item:<idx> = "<name>|<firstChannel>|<count>".
    // Always written, even for a notecard with no ITEM line: that case is
    // one unnamed item owning every channel, which is exactly what the
    // consumers will need to read so they can treat both shapes alike.
    llLinksetDataDeleteFound("^qs:item:", "");
    integer ni = llGetListLength(item_names);
    if (ni == 0)
    {
        qs_lsd_write("qs:item:0", "|0|" + (string)total_channels);
    }
    else
    {
        integer ii = 0;
        while (ii < ni)
        {
            integer f = llList2Integer(item_first, ii);
            integer nxt = total_channels;
            if (ii + 1 < ni) nxt = llList2Integer(item_first, ii + 1);
            qs_lsd_write("qs:item:" + (string)ii,
                llList2String(item_names, ii) + "|" + (string)f + "|"
                + (string)(nxt - f));
            if (boot_failed) return;
            ++ii;
        }
        Out(1, "items: " + llDumpList2String(item_names, ", "));
    }

    string cfg = qs_cfg_pack();
    integer ch;
    for (ch = 0; ch < total_channels; ++ch)
    {
        qs_lsd_write("qs:cfg:" + (string)ch, cfg);
        if (boot_failed) return;
        qs_lsd_write("qs:meta:" + (string)ch, "qs1");
        if (boot_failed) return;
    }
    // Skip-marker for the next state_entry. Written last so a mid-boot
    // abort (memfull, declined wipe) leaves it absent → next reset
    // re-seeds from scratch.
    qs_lsd_write("qs:boot:asset", (string)notecard_key);
    if (boot_failed) return;
    boot_done = TRUE;
    llSetText("", <1, 1, 1>, 1);
    Out(1, "Load complete; " + (string)total_channels + " sitter(s) ready. Mem=" + (string)(65536 - llGetUsedMemory()) + " Storage=" + (string)llLinksetDataAvailable());
    // Tell sibling plugins to refresh from LSD. They missed our mid-boot
    // writes if they were already past state_entry.
    llMessageLinked(LINK_SET, QS_BOOT_RELOAD, "", "");
    // v2 FORK ONLY. QS_BOOT_RELOAD is a v1 number the v2 base set does
    // not speak, and v1 boot never announced completion in any form the
    // base scripts could act on - they polled qs:meta:<ch> from their own
    // state_entry instead and simply lost the race when boot finished
    // after them. That is why seat/core/menu carried a linkset_data
    // watcher on qs:meta:0 as a stand-in. This is the real signal.
    llMessageLinked(LINK_SET, QSB_READY, "", "");
    // Re-CENSUS presence: wipe first, then let the survivors answer. The
    // wipe is new in 1.26 and it matters. Until then this spot only
    // broadcast, i.e. it re-STAMPED whoever was present and never noticed
    // who had gone. Removal detection therefore hung entirely on the
    // changed(CHANGED_INVENTORY) path below, which is single-shot: miss
    // that one event and the stale flag was permanent, because no reset
    // and no re-rez could ever clear it. Observed in the field as a
    // [HELPER]/[HELPER HUD] entry that survived '/5 cleanup' and every
    // reset afterwards, pointing at a [QS]adjuster that was long gone.
    //
    // Same wipe-then-broadcast order as changed() and race-free for the
    // same reason: both happen synchronously inside this event, so every
    // plugin's re-write is a strictly later event. All seven flag owners
    // (adjuster, faces, prop, select, rlv, security, offset) re-stamp in
    // their own QS_ALIVE_CENSUS handler, so a present plugin is back
    // within the same cascade and only the absent ones stay cleared.
    //
    // Side effect worth having: a script reset is now a reliable repair
    // for a presence flag that went stale for any reason at all.
    llLinksetDataDeleteFound("^qs:alive:", "");
    llLinksetDataDelete("qs:offset:alive");
    llMessageLinked(LINK_SET, QS_ALIVE_CENSUS, "", "");
    // Arm self-check timer — 10s safety net for probe replies. Replies
    // typically arrive in <1s on small notecards, but multi-prim builds
    // with many poses (251+) and several sitter slots can cumulatively
    // run past 1s on busy regions. The 10s timer is a fail-safe; when
    // all three base scripts have reported, try_complete_selfcheck()
    // short-circuits the wait and runs the report immediately. arm_autosync() is deferred to either
    // path so it always runs after the self-check resolves.
    selfcheck_pending = TRUE;
    llSetTimerEvent(10.0);
}

// Early-exit hook for the self-check: if both base scripts have
// reported in, kill the safety-net timer and run the report now. Both
// QSALIVE_REPLY handler and the qs:alive:* linkset_data watcher both
// call this. The selfcheck_pending guard makes it idempotent - only the
// first complete-state firing actually reports.
try_complete_selfcheck()
{
    if (selfcheck_pending && core_seen
        && llLinksetDataRead("qs:alive:seat") != ""
        && llLinksetDataRead("qs:alive:menu") != "")
    {
        selfcheck_pending = FALSE;
        llSetTimerEvent(0);
        self_check_report();
        arm_autosync();
    }
}

// One-shot post-boot self-check. Hard-fails on a missing base script. Warns on PROP* directives without [QS]prop.
// No-ops for missing adjuster: the adjuster registers its own menu
// entries and takes them with it, so a read-only setup shows nothing
// broken. See qs2/REGISTRY.md.
self_check_report()
{
    integer ok = TRUE;
    if (!core_seen)
    {
        Out(0, "ERROR: [QS]core missing - nothing selects a pose.");
        ok = FALSE;
    }
    if (llLinksetDataRead("qs:alive:seat") == "")
    {
        Out(0, "ERROR: [QS]seat missing - no sit targets, no animations.");
        ok = FALSE;
    }
    if (llLinksetDataRead("qs:alive:menu") == "")
    {
        Out(0, "ERROR: [QS]menu missing - no menu.");
        ok = FALSE;
    }
    if (has_prop_in_notecard && llLinksetDataRead("qs:alive:prop") == "")
    {
        Out(0, "WARN: " + notecard_name + " has PROP* but [QS]prop missing - props won't rez.");
    }
    if (!ok)
    {
        llSetText("ERROR: base scripts missing - see chat", <1, 0, 0>, 1);
    }
    else
    {
        // Clear any prior hovertext (notecard-missing ERROR from a
        // previous boot attempt, or stale "Loading..." progress) — all
        // base scripts are in, no caller-visible reason to keep red text.
        llSetText("", <1, 1, 1>, 0);
    }
}

// Kick off (or restart) the notecard read. Called from state_entry and
// from the wipe-confirmation listen handler after llLinksetDataReset().
// notecard_lines is set by state_entry's unconditional
// llGetNumberOfNotecardLines call (works on both seed and skip-seed
// paths) — we don't re-fetch here, and we don't reset it either since
// the wipe-rerun case keeps the same notecard with the same line count.
start_boot()
{
    current_channel = -1;
    // v2 FORK ONLY, stage 2: a re-parse must not accumulate items.
    item_names = [];
    item_first = [];
    boot_done = FALSE;
    boot_failed = FALSE;
    reused_variable = 0;
    last_pct = -1;   // force first qs_loading_text() to paint
    Out(2, "Loading from " + notecard_name + "...");
    notecard_query = llGetNotecardLine(notecard_name, 0);
}

// Read QPP_CFG:AUTOSYNC and arm the timer accordingly. Idempotent: safe
// to call from finalize_boot, linkset_data, or after manual changes.
// Skips while boot is still running so we don't trample the boot flow.
// Also skips during the self-check window — the timer is reserved for
// the 10s self-check safety net, which re-arms AUTOSYNC itself when it
// fires (or try_complete_selfcheck fires it early on both flags set).
// Without this guard, a linkset_data event on QPP_CFG:AUTOSYNC during
// the self-check window would overwrite the timer and silently drop
// the install-verification report.
arm_autosync()
{
    if (!boot_done) return;
    if (selfcheck_pending) return;
    string s = llLinksetDataRead("QPP_CFG:AUTOSYNC");
    if (s == "" || s == "Off")
    {
        bAutoSyncActive = FALSE;
        llSetTimerEvent(0);
        return;
    }
    bAutoSyncActive = TRUE;
    llSetTimerEvent((float)s);
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
        // Restore verbose from LSD before any Out() call. Covers single-
        // script reset on the skip-seed path, where the notecard parser
        // doesn't re-run and the source-code default (1) would otherwise
        // clobber a user-chosen VERBOSE level.
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        notecard_key = llGetInventoryKey(notecard_name);
        if (llGetInventoryType(notecard_name) != INVENTORY_NOTECARD)
        {
            // No notecard → no slot config. Refuse to boot. Re-arm on
            // CHANGED_INVENTORY: notecard_key is NULL_KEY here, so adding
            // the notecard will flip the asset-key compare and reset.
            llSetText("ERROR: " + notecard_name + " notecard missing", <1, 0, 0>, 1);
            Out(0, "ERROR: " + notecard_name + " notecard missing - boot stopped.");
            return;
        }
        // Always fetch line count — used by the seed-phase progress
        // hovertext AND by the QUICKYHUD live-view's &n= total. Async;
        // dataserver populates notecard_lines whenever the response
        // arrives. Single call site so the dataserver branch's
        // query_id == reused_key check stays unambiguous.
        reused_key = llGetNumberOfNotecardLines(notecard_name);
        // Skip-seed requires BOTH the matching asset key AND the page-oriented
        // sidecar (qs:cfg:slots:0, written since 0.9952). Furniture seeded by an
        // older boot has the asset key but no sidecar; force one re-parse so the
        // sidecar exists before the sitB page-rebuild starts reading it. After
        // that single reseed the steady-state skip path resumes normally.
        if (llLinksetDataRead("qs:boot:asset") == (string)notecard_key
            && llLinksetDataRead("qs:cfg:slots:0") != "")
        {
            // Already seeded for this notecard — skip the re-parse.
            // The base set reads LSD directly; we just rebuild
            // total_channels (for the status line below) and re-arm the
            // timer so the cached steady state resumes.
            integer ch = 0;
            while (llLinksetDataRead("qs:meta:" + (string)ch) != "")
                ++ch;
            total_channels = ch;
            boot_done = TRUE;
            // Status line for the skip path — finalize_boot (and its
            // "Load complete" Mem/Storage line) only runs on a real
            // notecard parse, so a plain reset/re-rez showed neither
            // memory nor storage headroom without this.
            Out(1, "Cached boot; " + (string)total_channels
                + " sitter(s) ready. Mem=" + (string)(65536 - llGetUsedMemory())
                + " Storage=" + (string)llLinksetDataAvailable());
            // Self-check on the skip-seed path too - base-script presence
            // still needs verification after a script reset. PROP-warn
            // is skipped here (no notecard parse → has_prop_in_notecard
            // stays FALSE). Timer handler runs arm_autosync() after the
            // check, replacing the direct call. 10s safety net (see
            // finalize_boot for rationale); try_complete_selfcheck()
            // short-circuits early when both base scripts report in.
            selfcheck_pending = TRUE;
            llSetTimerEvent(10.0);
            // v2 FORK ONLY. The skip path needs the same wipe-then-CENSUS
            // as finalize_boot, and here it is not merely tidy: the
            // self-check now READS qs:alive:seat / qs:alive:menu, so
            // carrying flags over from the previous run would report a
            // removed script as present forever. Wiping first means only
            // whoever re-stamps counts.
            llLinksetDataDeleteFound("^qs:alive:", "");
            llLinksetDataDelete("qs:offset:alive");
            llMessageLinked(LINK_SET, QS_ALIVE_CENSUS, "", "");
            // The LSD is complete and unchanged, which is exactly the
            // condition QSB_READY announces. A base script that came up
            // before us gets its cue here.
            llMessageLinked(LINK_SET, QSB_READY, "", "");
        }
        else
        {
            start_boot();
        }
        // Self-check probe. The reply lands in core_seen via link_message;
        // seat and menu answer the CENSUS above with an LSD stamp instead,
        // and linkset_data completes the check when the last one arrives.
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
    }

    listen(integer chan, string name, key id, string msg)
    {
        if (chan != dialog_channel) return;
        llListenRemove(dialog_handle);
        dialog_handle = 0;
        if (msg == "Wipe")
        {
            llLinksetDataReset();
            wipe_attempted = TRUE;
            Out(1, "Storage wiped - retrying boot.");
            start_boot();
            return;
        }
        // Cancel — stay in error state. CHANGED_INVENTORY on the notecard
        // (or a manual reset) restarts boot fresh; wipe_attempted clears
        // automatically via llResetScript().
        Out(0, "Boot aborted - storage wipe declined.");
    }

    timer()
    {
        if (selfcheck_pending)
        {
            // One-shot self-check tick (armed in finalize_boot). Stop
            // the timer first so AUTOSYNC can re-arm it cleanly.
            selfcheck_pending = FALSE;
            llSetTimerEvent(0);
            self_check_report();
            arm_autosync();
            return;
        }
        if (bAutoSyncActive)
        {
            // Re-Sync trigger per qs/PROTOCOL.md § 90271. Timer keeps
            // firing at the configured interval (LSL repeats automatically
            // until llSetTimerEvent(0)).
            llMessageLinked(LINK_SET, 90271, "", "");
            return;
        }
        // Defensive: stop unexpected ticks.
        llSetTimerEvent(0);
    }

    linkset_data(integer act, string name, string val)
    {
        // Re-arm whenever the AUTOSYNC config changes (from hudproxy's
        // settings dialog) or the whole LSD is reset (/88 nuke). On a
        // full wipe, also warn the owner: cached RAM state in sibling
        // scripts (seat/core/menu/adjuster/...) is now inconsistent with
        // empty LSD until they're reset or the furniture is re-rezzed.
        if (act == LINKSETDATA_RESET)
            OutForce("LSD was wiped - inconsistent state; reset scripts or re-rez.");
        if (act == LINKSETDATA_RESET || name == "QPP_CFG:AUTOSYNC")
            arm_autosync();

        // v2 FORK ONLY. seat and menu prove they exist by stamping
        // qs:alive:*, not by answering a probe, so their arrival is an
        // LSD write rather than a link message. Watching for it here is
        // what keeps the early exit alive: without it the self-check
        // could only ever complete on the 10s safety-net timer, and
        // arm_autosync() would be held back that whole time on every
        // boot.
        if (selfcheck_pending)
        {
            if (name == "qs:alive:seat" || name == "qs:alive:menu")
                try_complete_selfcheck();
        }

        // Low-storage watchdog — see LSD_LOW_WATER. Runs on every LSD
        // event: writes shrink free space (warn once), deletes/wipes can
        // recover it (re-arm above 2x the threshold).
        integer avail = llLinksetDataAvailable();
        if (!lsd_low_warned && avail < LSD_LOW_WATER)
        {
            lsd_low_warned = TRUE;
            OutForce("storage low: " + (string)avail
                + " bytes free - pose saves and configs may start failing. Reduce poses or clear unused data.");
        }
        else if (lsd_low_warned && avail > LSD_LOW_WATER * 2)
            lsd_low_warned = FALSE;
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        // No same-prim filter here: the self-check (QSALIVE_REPLY from
        // [QS]core) needs to accept
        // messages from sit-prims, which on real furniture are typically
        // child prims separate from boot's root prim. The previous
        // `if (sender != llGetLinkNumber()) return;` (dropped in 0.906)
        // blanket-rejected those, leaving the seen-flags permanently
        // FALSE → false "missing" ERRORs on multi-prim builds like
        // Lalou - Lima Ottoman. Each handler validates payload itself;
        // spoofing from other child-prim scripts in the same linkset is
        // out of scope (owner-controlled assets).
        if (num == QSALIVE_REPLY)
        {
            // [QS]core, the single answerer. seat and menu prove
            // themselves through qs:alive:*, which try_complete_selfcheck
            // reads directly.
            core_seen = TRUE;
            try_complete_selfcheck();
            return;
        }
    }

    dataserver(key query_id, string data)
    {
        if (query_id == reused_key)
        {
            notecard_lines = (integer)data;
            return;
        }
        if (query_id != notecard_query)
            return;
        if (boot_failed)
            return;
        if (data == EOF)
        {
            // Flush the last channel's sitter row, then finalize (writes
            // qs:cfg + qs:meta for all channels with the now-complete
            // GENDERS list).
            if (current_channel >= 0)
                flush_channel_sitter(current_channel);
            finalize_boot();
            return;
        }
        if (notecard_lines && current_channel >= 0)
            qs_loading_text(reused_variable, notecard_lines, "Loading sitter " + (string)current_channel + " from " + notecard_name);

        notecard_query = llGetNotecardLine(notecard_name, ++reused_variable);

        data = llGetSubString(data, llSubStringIndex(data, "◆") + 1, 99999);
        // Trim BOTH ends. Head-only trim let a trailing space ride along on
        // the line's last field, and the raw parts[] reads below (the gender
        // markers at "SITTER 0|F|F " and "POSE name|anim|M ") compare against
        // untrimmed strings: "F " matched neither "M" nor "F", so the sitter
        // was recorded as gender -1 and sitA handed the seat to the next
        // gender-matching slot instead (woman on F2, second woman on F).
        // Stock AVsitter neutralizes the space, and QS promises notecard
        // compatibility, so the defect was ours. part0/part1 were already
        // STRING_TRIM'd and are unaffected either way.
        data = llStringTrim(data, STRING_TRIM);
        string command = llGetSubString(data, 0, llSubStringIndex(data, " ") - 1);
        list parts = llParseStringKeepNulls(llGetSubString(data, llSubStringIndex(data, " ") + 1, 99999), [" | ", " |", "| ", "|"], []);
        // Stock AVsitter parses with llParseString2List which drops empties.
        // We need KeepNulls so BUTTON's interior gaps (e.g. "name|90200||<S>")
        // survive, but a leading "|" right after the command keyword (common
        // in "POSE | name | anim", "ADJUST | 90100 | …") leaves a phantom ""
        // at parts[0]. That empty becomes a "P:"/"S:"/"M:"/"T:" pose name in
        // LSD, then renders as a blank button in the menu and trips llDialog
        // with "all buttons must have label strings". Drop the leading
        // empties to mirror stock behavior without losing interior nulls.
        while (llGetListLength(parts) && llList2String(parts, 0) == "")
            parts = llDeleteSubList(parts, 0, 0);
        string part0 = llStringTrim(llList2String(parts, 0), STRING_TRIM);
        string part1;
        if (llGetListLength(parts) > 1)
            part1 = llStringTrim(llDumpList2String(llList2List(parts, 1, 99999), SEP), STRING_TRIM);

        // v2 FORK ONLY, stage 2 (DESIGN.md §11). Opens a named group; every
        // SITTER until the next ITEM belongs to it. SITTER numbering is
        // LOCAL to the item, while channels stay globally numbered, so
        // every qs:p / qs:occ / qs:cur / QSO key keeps its current shape.
        //
        // A notecard without an ITEM line is one unnamed item, index 0 -
        // byte-identical to before, which is the whole point of doing this
        // additively rather than as the format change §4 described.
        //
        // NOTHING CONSUMES THIS YET. It is parsed and stored first, on
        // purpose: the table can be inspected in-world and proven correct
        // against a real notecard before seat, core and menu start scoping
        // themselves by it.
        if (command == "ITEM")
        {
            if (part0 == "")
            {
                Out(0, "ITEM without a name - ignored;"
                    + " prims cannot address a nameless item.");
                return;
            }
            // firstChannel is where the NEXT SITTER lands: current_channel
            // is the last one seen, -1 before any.
            item_first += (current_channel + 1);
            item_names += part0;
            return;
        }

        if (command == "SITTER")
        {
            // v2 FORK ONLY, stage 2: the number on a SITTER line is the
            // LOCAL slot within the current item, and the global channel
            // is that plus the item's first channel. Without an ITEM line
            // the offset is zero and this is v1's arithmetic exactly.
            //
            // Local numbering is not cosmetic: the prim description
            // addresses seats as "#Sofa-0", "#Sofa-1", so the notecard has
            // to count the same way or the two would disagree about which
            // seat is which.
            integer s_ch = (integer)part0;
            integer nit = llGetListLength(item_first);
            if (nit) s_ch += llList2Integer(item_first, nit - 1);

            // Flush the previous channel's sitter row before resetting
            // per-channel locals. qs:cfg/qs:meta wait until EOF — GENDERS
            // is still accumulating across the rest of the notecard.
            if (current_channel >= 0)
                flush_channel_sitter(current_channel);
            // GLOBAL channel 0, not the local slot: every item has a
            // slot 0, and resetting GENDERS at each of them would drop
            // the gender of every seat parsed so far.
            if (s_ch == 0)
                GENDERS = [];
            integer g = -1;
            if (llList2String(parts, 2) == "M") g = 1;
            else if (llList2String(parts, 2) == "F") g = 0;
            GENDERS += g;
            current_channel = s_ch;
            reset_channel_locals();
            // Wipe any stale pose entries from a prior boot at this channel.
            llLinksetDataDeleteFound("^qs:p:" + (string)s_ch + ":[0-9]+$", "");
            // Same for the page-oriented sidecar (qs:nm/qs:nt) — a re-seed with
            // fewer submenus must not leave higher-index sidecar keys behind.
            llLinksetDataDeleteFound("^qs:n[mt]:" + (string)s_ch + ":", "");
            // And the pose overlays: a removed OVERLAY line must not keep
            // playing off a stale key, and entry indexes shift on re-seed.
            llLinksetDataDeleteFound("^qs:ov:" + (string)s_ch + ":", "");
            if (llGetListLength(parts) > 1)
                SITTER_INFO = llList2List(parts, 1, 99999);
            return;
        }
        if (command == "MTYPE")  { MTYPE = (integer)part0; return; }
        if (command == "ETYPE")  { ETYPE = (integer)part0; return; }
        if (command == "SET")    { SET = (integer)part0; return; }
        if (command == "SWAP")   { SWAP = (integer)part0; return; }
        if (command == "SELECT") { SELECT = (integer)part0; return; }
        if (command == "AMENU")  { AMENU = (integer)part0; return; }
        if (command == "HELPER") { OLD_HELPER_METHOD = (integer)part0; return; }
        if (command == "WARN")   { WARN = (integer)part0; return; }
        if (command == "KFM")    { HASKEYFRAME = (integer)part0; return; }
        if (command == "LROT")   { REFERENCE = (integer)part0; return; }
        if (command == "DFLT")   { DFLT = (integer)part0; return; }
        if (command == "VERBOSE")
        {
            // QS extension (not stock AVsitter). Sets the project-wide
            // chat-verbosity floor for all QS scripts via the
            // qs:cfg:verbose LSD key; each script reads it on state_entry.
            // Stock-AVsitter sitters silently ignore the unknown command,
            // so notecards stay portable in the read direction.
            verbose = (integer)part0;
            llLinksetDataWrite("qs:cfg:verbose", part0);
            return;
        }
        // The authoring-lock mechanism (AVpos token in 1.255, then
        // hudconfig keyword) was removed entirely in the 1.2552 era:
        // authoring is presence-based (no [QS]adjuster = no authoring
        // surface), stock-style. A leftover AUTHORING line falls
        // through as an unknown command, ignored like on stock.
        if (command == "BRAND")  { BRAND = part0; return; }
        if (command == "OVERLAY")
        {
            // QS extension, v2 only (DESIGN.md §12): extra animations
            // played ALONGSIDE a pose on this sitter - hand grips, face
            // anims, held props. One line per pose, any number of anims:
            //
            //   OVERLAY <posename>|<anim>[|<anim>...]
            //
            // Stored as qs:ov:<ch>:<i> keyed by the ENTRY INDEX the pose
            // seeded at, so core's start path is one LSD read and a card
            // without OVERLAY lines costs nothing. The line must come
            // AFTER its pose's own line, same rule as {posename} splices.
            // Stock AVsitter ignores the unknown keyword, so cards stay
            // portable in the read direction.
            if (current_channel < 0)
            {
                Out(0, "OVERLAY before any SITTER - ignored.");
                return;
            }
            if (part1 == "")
            {
                Out(0, "OVERLAY " + part0 + " names no animation - ignored.");
                return;
            }
            integer oi = qs_seed_find(current_channel, part0);
            if (oi == -1)
            {
                Out(0, "OVERLAY " + part0 + " matches no pose above it in"
                    + " SITTER " + (string)current_channel + " - ignored.");
                return;
            }
            // part1 is already SEP-joined, which is the stored shape.
            qs_lsd_write("qs:ov:" + (string)current_channel + ":"
                + (string)oi, part1);
            return;
        }
        if (command == "ONSIT")  { onSit = part0; return; }
        if (command == "ROLES")  { RLVDesignations = (string)parts; return; }
        if (command == "TEXT")
        {
            CUSTOM_TEXT = llDumpList2String(llParseStringKeepNulls(part0, ["\\n"], []), "\n");
            return;
        }
        if (command == "ADJUST")
        {
            // KeepNulls leaves a leading "" from "| 90100 | …" — drop empties
            // so the ADJUST submenu doesn't render a blank button (llDialog
            // rejects empty labels with "all buttons must have label strings").
            ADJUST_MENU = [];
            integer ai;
            integer an = llGetListLength(parts);
            for (ai = 0; ai < an; ++ai)
            {
                string ap = llList2String(parts, ai);
                if (ap != "")
                    ADJUST_MENU += ap;
            }
            return;
        }
        // PROP* detection for the boot self-check. Set-once flag — multiple
        // PROP lines just re-set TRUE. Falls through to the parser block,
        // which doesn't match PROP* commands anyway.
        if (command == "PROP1" || command == "PROP2" || command == "PROP3")
        {
            has_prop_in_notecard = TRUE;
        }

        // Single-sitter AVpos notecards (real-world example shape from
        // older AVsitter products) omit the explicit `SITTER 0` directive
        // and just start emitting POSE/MENU/{posename} lines. Stock parses
        // these as implicit slot 0 because each [AV]sitA instance has its
        // own SCRIPT_CHANNEL baked into the script name; the consolidated
        // QS boot needs to synthesize the missing SITTER 0 when the first
        // pose-ish line arrives with no channel established yet.
        // Verified safe: empty SITTER_INFO → select.lsl falls back to
        // first POSE name as slot label; empty GENDERS → sitA's swap-by-
        // gender returns FALSE rather than matching (correct semantic).
        if (current_channel == -1
            && (command == "POSE" || command == "SYNC"
                || command == "MENU" || command == "TOMENU"
                || command == "BUTTON" || command == "SEQUENCE"
                || llGetSubString(data, 0, 0) == "{"))
        {
            current_channel = 0;
            reset_channel_locals();
        }

        // ===== Stock AVsitter sitA dataserver — verbatim parser block =====
        // Only difference: where stock dispatches 90300/90301 to sitB, we
        // also write to LSD. Locals (FIRST_POSENAME etc.) are kept even
        // though boot doesn't use them, so the parser flow matches stock
        // byte-for-byte. Pose lines are only written once we're past the
        // first SITTER directive (current_channel >= 0).
        if (current_channel >= 0)
        {
            if (llGetSubString(data, 0, 0) == "{")
            {
                command = llStringTrim(llGetSubString(data, 1, llSubStringIndex(data, "}") - 1), STRING_TRIM);
                parts = llParseStringKeepNulls(llDumpList2String(llParseString2List(llGetSubString(data, llSubStringIndex(data, "}") + 1, 99999), [" "], [""]), ""), ["<"], []);
                string pos = "<" + llList2String(parts, 1);
                string rot = "<" + llList2String(parts, 2);
                if (command == FIRST_POSENAME || "P:" + command == FIRST_POSENAME)
                {
                    FIRST_POSITION = DEFAULT_POSITION = CURRENT_POSITION = (vector)pos;
                    FIRST_ROTATION = DEFAULT_ROTATION = CURRENT_ROTATION = (vector)rot;
                }
                // LSD pos/rot splice — find existing entry by name and update.
                integer si = qs_seed_find(current_channel, command);
                if (si != -1)
                {
                    list cur = llParseStringKeepNulls(llLinksetDataRead(qs_p_key(current_channel, si)), ["|"], []);
                    qs_p_write(current_channel, si,
                        llList2String(cur, 0),
                        llList2String(cur, 1),
                        llList2String(cur, 2),
                        pos, rot);
                }
            }
            else
            {
                part0 = llGetSubString(part0, 0, 22);
                if (command == "SEQUENCE")
                {
                    command = "BUTTON";
                    part1 = "90210";
                }
                if (command == "POSE" || command == "SYNC" || command == "MENU" || command == "TOMENU" || command == "BUTTON")
                {
                    if (command != "SYNC")
                    {
                        part0 = llGetSubString(command, 0, 0) + ":" + part0;
                    }
                    if (command == "MENU" || command == "TOMENU")
                    {
                        part0 += "*";
                    }
                    if (command == "POSE" || command == "SYNC")
                    {
                        if (FIRST_POSENAME == "")
                        {
                            FIRST_POSENAME = CURRENT_POSE_NAME = part0;
                            FIRST_ANIMATION_SEQUENCE = CURRENT_ANIMATION_SEQUENCE = part1;
                        }
                        if (llList2String(parts, -1) == "M")
                        {
                            MALE_POSENAME = part0;
                            FIRST_MALE_ANIMATION_SEQUENCE = part1;
                        }
                        else if (llList2String(parts, -1) == "F")
                        {
                            FEMALE_POSENAME = part0;
                            FIRST_FEMALE_ANIMATION_SEQUENCE = part1;
                        }
                    }
                    // Don't generate empty buttons (issue #60)
                    if (part0 == "B:")
                        part0 = "B: ";
                    if (command == "BUTTON" && part1 == "")
                    {
                        part1 = "90200";
                    }
                    // LSD persist (replaces stock's 90300 dispatch).
                    string t = llGetSubString(command, 0, 0);
                    integer si = seed_count;
                    ++seed_count;
                    qs_p_write(current_channel, si, part0, t, part1, "", "");
                    // Page-oriented menu sidecar (additive; dormant until the
                    // sitB page-rebuild reads it). MENU markers close the prior
                    // section + adopt any TOMENU that was waiting for them;
                    // TOMENUs register their index for the matching MENU.
                    if (t == "M")
                    {
                        qs_close_section(current_channel, si);
                        string mkey = llGetSubString(part0, 2, 99999); // "M:Foo*" -> "Foo*"
                        integer pend = llListFindList(tomenu_pending, [mkey]);
                        if (pend != -1)
                        {
                            qs_lsd_write("qs:nt:" + (string)current_channel + ":"
                                + (string)llList2Integer(tomenu_pending, pend + 1), (string)si);
                            tomenu_pending = llDeleteSubList(tomenu_pending, pend, pend + 1);
                        }
                    }
                    else if (t == "T")
                    {
                        tomenu_pending += [llGetSubString(part0, 2, 99999), si];
                    }
                }
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_INVENTORY)
        {
            // Notecard is the source of truth — a notecard save/swap mints
            // a new asset key, which triggers reset + re-seed.
            if (llGetInventoryKey(notecard_name) != notecard_key)
            {
                // Tell sitA / sitB their cached MENU_LIST / pose data
                // is about to become invalid — they flip back to the
                // pre-boot state and engage their sit/menu eject guards
                // until our finalize_boot fires QS_BOOT_RELOAD again.
                // Broadcast BEFORE the wipe so the receivers have the
                // signal even if scheduling re-orders us; they read no
                // LSD on this path, just clear flags. qs:alive:* survive
                // the wipe (presence isn't notecard-derived; the plugins
                // re-seed it themselves on their own state_entry).
                llMessageLinked(LINK_SET, QS_BOOT_WIPE, "", "");
                llLinksetDataDeleteFound("^qs:(meta|cfg|sitter|p|nm|nt|ov|boot):", "");
                llResetScript();
            }
            else
            {
                // Notecard unchanged → a plugin script was added or removed.
                // Re-census presence: wipe every qs:alive flag, then trigger
                // the survivors to re-write theirs. A removed plugin can't
                // answer, so its flag stays cleared — that's the removal
                // detection (replaces sitB's old per-name inventory probe).
                // Wipe + broadcast are synchronous, so survivors' re-writes
                // are strictly later events: no clear-vs-rewrite race. This
                // also fires once per script-drag while a creator assembles
                // the furniture — harmless and self-correcting (each survivor
                // re-stamps on receipt; the state after the last drag wins).
                llLinksetDataDeleteFound("^qs:alive:", "");
                llLinksetDataDelete("qs:offset:alive");
                llMessageLinked(LINK_SET, QS_ALIVE_CENSUS, "", "");
                // Updater runs replace sibling scripts one by one. Keep the
                // self-check safety-net window open if it's still pending so
                // the timer doesn't fire mid-update with false-positive
                // "base script missing" ERRORs.
                if (selfcheck_pending) llSetTimerEvent(10.0);
            }
        }
    }
}
