/*
 * [QS]boot - QuickySitter loader
 *
 * Pure one-shot LSD writer. On state_entry:
 *   • if qs:boot:asset matches the AVpos notecard's current asset-key
 *     → already seeded, skip re-parse (sitA/sitB read LSD directly)
 *   • else → parse AVpos notecard, write qs:cfg:<ch>, qs:sitter:<ch>,
 *            qs:p:<ch>:<i>, qs:meta:<ch>, finally qs:boot:asset
 *
 * After seeding, boot is idle until the notecard's asset-key changes
 * (changed(CHANGED_INVENTORY) wipes qs:* and resets) or storage is
 * wiped (qs:boot:asset is gone → next state_entry re-seeds).
 *
 * No message dispatching. sitA and sitB read LSD directly. Boot is the
 * sole source of LSD writes during seed; the adjuster writes LSD for
 * live creator edits at runtime, independently.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "1.02";
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
// camera plugin name is an AVsitter protocol constant — stock plugin
// probes and replies by literal script name. Once [QS]camera adopts
// QSDUMP_HELLO (like [QS]faces 0.902 and [QS]prop do), this constant
// can go too.
string camera_script = "[AV]camera";

// QSDUMP — DUMP plugin discovery via announce/probe handshake, mirroring
// the QSALIVE pattern. Plugins announce themselves on state_entry/on_rez;
// boot probes once during its state_entry to wake plugins that came up
// before boot. See qs/PROTOCOL.md § QSDUMP for the full contract.
integer QSDUMP_PROBE = 90094;
integer QSDUMP_HELLO = 90095;
list dump_plugins;

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

// Boot self-check — verifies the minimum base scripts (sitA + sitB) are
// present in the linkset, plus a conditional warn if the notecard has
// PROP* directives but [QS]prop is missing. Fires from finalize_boot
// (fresh-boot) or state_entry's skip-seed branch as soon as both
// sita_seen and sitb_seen land (via try_complete_selfcheck), with a
// 10s safety-net timer for the no-reply case. See qs/PROTOCOL.md
// § QSALIVE (sitA-side) and § QS_SITB_PROBE (sitB-side).
//
// Detection has two complementary paths per base script: an explicit
// probe (90096/90077) the script answers from its link_message handler,
// and an unsolicited HELLO emitted at the end of qs_load_from_lsd() in
// slot-0 sitA / slot-0 sitB. The probe covers the skip-seed path where
// boot is reset alone while sitA/sitB keep running (their state_entry
// doesn't re-fire, so no unsolicited HELLO); the unsolicited HELLOs
// cover the fresh-boot path, where finalize_boot's QS_BOOT_RELOAD
// broadcast triggers a fresh qs_load_from_lsd() in both base scripts.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer QS_SITB_PROBE = 90077;
integer QS_SITB_HELLO = 90078;
integer sita_seen;
integer sitb_seen;
integer has_prop_in_notecard;
integer selfcheck_pending;

// [DUMP] output pipeline. Migrated from adjuster: cache fills via
// Readout_Say, web() flushes to the AVsitter settings service every
// ~1024 escaped chars or on force(TRUE) at the end of the cascade.
//
// Two endpoints: `url` (stock avsitter.com/settings.php, third-party,
// uncontrolled TTL/uptime) is used for the loud [HELPER] path, keeping
// stock behavior + chat fallback if the service goes down. `url_qs`
// (self-hosted at slquicky.com) is used for the quiet [QUICKYHUD]
// path — same w/c/t POST + ?q GET protocol (selfhosted PHP is a verbatim
// deploy of the AVsitter PHP receiver, MIT). web() picks the endpoint
// per-request based on `dump_quiet`. http_response sets `dump_failed`
// when the QS endpoint returns non-200 so the end-of-cascade URL shout
// can fall back to a chat-only failure hint instead of a dead link.
string url    = "https://avsitter.com/settings.php";
string url_qs = "https://slquicky.com/quicky-sitter/dump/settings.php";
string cache;
string webkey;
integer webcount;
integer dump_failed;
// Note: web() reads `notecard_lines` directly for the &n=<lines>
// QUICKYHUD-progress param. `notecard_lines` is populated by the
// dataserver callback from state_entry's unconditional
// llGetNumberOfNotecardLines call — works on both fresh-seed and
// skip-seed paths, no LSD persist or per-dump iteration needed.

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

// Wipe-confirmation dialog state. dialog_channel is per-instance random.
integer dialog_channel;
integer dialog_handle;

// Streaming-dump state. Boot owns [DUMP] now (the qs:cfg/qs:sitter/
// qs:p:* keys it writes during seed are exactly what dump emits back).
// Adjuster sends 90098 to start a channel; boot streams V: synchronously,
// then ticks via 90099 — one qs:p entry per event — so per-iteration
// locals are released and the 90022 echo queue drains between ticks.
// Idle when qs_dump_ch == -1.
//
// dump_quiet: when TRUE, Readout_Say feeds the web cache only and
// skips the per-line llRegionSayTo to the owner — including the
// `--✄--COPY ABOVE/BELOW--✄--` banners (they still land in the web
// cache because the AVpos paste format expects them, just not in chat).
// The only chat output in quiet mode is the one-shot start hint from
// the 90098 handler and either the final `Settings copy: <url>` shout
// or a `[DUMP] Upload failed` hint (per dump_failed below) after
// web(TRUE). Set from the initial 90098 trigger's id field (id="quiet"
// → quiet, anything else → loud, preserving stock-style helper [DUMP]
// behavior). Reset at end of the cascade. See qs/PROTOCOL.md § DUMP.
//
// The quiet path also drives endpoint selection: dump_url() returns
// url_qs (self-hosted) when dump_quiet, else stock url (avsitter.com).
// See globals near `string url` for the endpoint-pair rationale.
integer qs_dump_ch = -1;
integer qs_dump_pi;
integer dump_quiet;

// Cascade watchdog. The 90021 plugin-probe cascade sends 90020 to each
// DUMP-capable plugin, then waits for it to echo 90021 back — with no
// built-in timeout. A non-conformant plugin that never echoes (a third-party
// DUMP plugin, or a mismatched camera) would park the dump forever, stalling
// exactly where the next "SITTER" line should print, with no footer. After
// each 90020 we arm a one-shot inactivity timer; every dump line the plugin
// emits (90022) re-arms it, so a slow but working plugin is never falsely
// skipped — only true silence trips it. On trip we re-emit the channel-done
// 90021 ourselves, naming the silent plugin, so the cascade skips past it and
// the dump finishes (minus that plugin's lines) instead of hanging.
integer qs_cascade_pending;        // TRUE while waiting for a probed plugin's 90021
integer qs_cascade_ch = -1;        // channel whose cascade is active (-1 = none)
string  qs_cascade_wait;           // script we sent 90020 to and are waiting on
float   QS_CASCADE_TIMEOUT = 5.0;  // seconds of plugin silence before we skip it

// Dump pacing. The stream is throttle-paced like stock AVsitter's per-line
// llSleep(0.2): instead of firing the next 90099 tick immediately, qs_dump_tick
// arms a one-shot timer and timer() fires it after QS_DUMP_PACE. Keeps the
// dump's HTTP POSTs well under SL's ~1/sec llHTTPRequest throttle (a big config
// otherwise bursts ~25 chunk-POSTs and trips "Too many HTTP requests too fast")
// while staying event-driven — peak RAM is still one entry, no blocking loop.
integer qs_pace_pending;           // TRUE while a paced 90099 self-tick is timer-armed
float   QS_DUMP_PACE = 0.2;        // seconds between dump entries (stock parity)

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
        Out(0, "ERROR: storage full after wipe — " + notecard_name + " too large; reduce poses/sitters.");
        return;
    }
    Out(0, "ERROR: storage full at " + k + " — see wipe dialog.");
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

// Done seeding. sitA/sitB poll qs:meta:<ch> in their state_entry and pick
// up the data themselves once we've written meta. No reset needed.
finalize_boot()
{
    total_channels = current_channel + 1;
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
    // Tell sibling sitB scripts to refresh from LSD. They missed our
    // mid-boot writes if they were already past state_entry.
    llMessageLinked(LINK_SET, QS_BOOT_RELOAD, "", "");
    // Re-stamp presence flags. Covers the rare full-LSD-reset path
    // (wipe-retry) where qs:alive:* was cleared without the plugins
    // resetting, and re-confirms any plugin that became ready only after
    // its own state_entry write. Plugins re-write their flag on CENSUS.
    llMessageLinked(LINK_SET, QS_ALIVE_CENSUS, "", "");
    // Arm self-check timer — 10s safety net for probe replies. Replies
    // typically arrive in <1s on small notecards, but multi-prim builds
    // with many poses (251+) and several sitter slots can cumulatively
    // run past 1s on busy regions. The 10s timer is a fail-safe; when
    // both sita_seen and sitb_seen become TRUE the link_message handler
    // calls try_complete_selfcheck() to short-circuit the wait and run
    // the report immediately. arm_autosync() is deferred to either
    // path so it always runs after the self-check resolves.
    selfcheck_pending = TRUE;
    llSetTimerEvent(10.0);
}

// Early-exit hook for the self-check: if both base scripts have
// reported in, kill the safety-net timer and run the report now. Both
// link_message branches (QSALIVE_REPLY, QS_SITB_HELLO) call this after
// setting their flag. The selfcheck_pending guard makes it idempotent —
// only the first complete-state firing actually reports.
try_complete_selfcheck()
{
    if (selfcheck_pending && sita_seen && sitb_seen)
    {
        selfcheck_pending = FALSE;
        llSetTimerEvent(0);
        self_check_report();
        arm_autosync();
    }
}

// One-shot post-boot self-check. Hard-fails on missing sitA/sitB (no
// animation or no menu). Warns on PROP* directives without [QS]prop.
// No-ops for missing adjuster — sitB already gates the [HELPER] menu
// item on qs:alive:adjuster, so end-users in read-only setups see
// nothing broken.
self_check_report()
{
    integer ok = TRUE;
    if (!sita_seen)
    {
        Out(0, "ERROR: [QS]sitA missing — no animations.");
        ok = FALSE;
    }
    if (!sitb_seen)
    {
        Out(0, "ERROR: [QS]sitB missing — no menu.");
        ok = FALSE;
    }
    if (has_prop_in_notecard && llLinksetDataRead("qs:alive:prop") == "")
    {
        Out(0, "WARN: " + notecard_name + " has PROP* but [QS]prop missing — props won't rez.");
    }
    if (!ok)
    {
        llSetText("ERROR: base scripts missing — see chat", <1, 0, 0>, 1);
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

// ========================================================================
// [DUMP] output pipeline. Format + chat + HTTP upload, also migrated from
// adjuster so the entire dump (producer + receiver) lives in boot.
// ========================================================================

string FormatFloat(float f, integer num_decimals)
{
    f += ((integer)(f > 0) - (integer)(f < 0)) * ((float)(".5e-" + (string)num_decimals) - .5e-6);
    string ret = llGetSubString((string)f, 0, num_decimals - (!num_decimals) - 7);
    if (num_decimals)
    {
        num_decimals = -1;
        while (llGetSubString(ret, num_decimals, num_decimals) == "0")
        {
            --num_decimals;
        }
        if (llGetSubString(ret, num_decimals, num_decimals) == ".")
        {
            --num_decimals;
        }

        return llGetSubString(ret, 0, num_decimals);
    }
    return ret;
}

// Resolve the endpoint for the current dump. Stays a tiny helper so
// the URL choice is in one place (web POST + end-of-cascade shout both
// call it).
string dump_url()
{
    if (dump_quiet) return url_qs;
    return url;
}

web(integer force)
{
    if (llStringLength(llEscapeURL(cache)) > 1024 || force)
    {
        if (force)
        {
            cache += "\n\nend";
        }
        webcount++;
        // Quiet-mode adds &n=<lines> so settings.php can render
        // progress as "X of ~Y lines". The `> 0` gate handles the
        // tiny race where boot just reset and dataserver hasn't yet
        // populated notecard_lines (first chunk would still send &n=
        // once that response lands). Loud-mode skips it (stock
        // endpoint ignores unknown params anyway).
        string params = "w=" + webkey + "&c=" + (string)webcount;
        if (dump_quiet && notecard_lines > 0)
        {
            params += "&n=" + (string)notecard_lines;
        }
        params += "&t=" + llEscapeURL(cache);
        // Throttle guard: llHTTPRequest returns NULL_KEY *synchronously* when the
        // per-object HTTP rate limit (~25 req / 20s) is hit — the chunk is
        // dropped, not queued. Flag it so the quiet-mode end-of-cascade message
        // reports an incomplete upload instead of advertising a truncated link.
        // Also catches the final web(TRUE) chunk, which the async http_response
        // non-200 check can miss. (Loud mode posts to the stock endpoint and the
        // chat output is the real deliverable, so it intentionally ignores this.)
        if (llHTTPRequest(dump_url(), [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/x-www-form-urlencoded", HTTP_VERIFY_CERT, FALSE], params) == NULL_KEY)
            dump_failed = TRUE;
        cache = "";
    }
}

Readout_Say(string say)
{
    cache += say + "\n";
    if (!dump_quiet)
    {
        string objectname = llGetObjectName();
        llSetObjectName("");
        llRegionSayTo(llGetOwner(), 0, "◆" + say);
        llSetObjectName(objectname);
    }
    say = "";
    web(FALSE);
}

// ========================================================================
// [DUMP] streaming. Symmetric to the seed phase: read what we wrote, emit
// AVpos-style 90022 lines for the Readout_Say/web pipeline above. Runs
// off 90098 (start) + 90099 (per-entry tick) so peak memory stays small.
// ========================================================================

// Build and emit the V: line synchronously, then queue the first tick.
qs_dump_start(integer ch)
{
    list p = llParseStringKeepNulls(llLinksetDataRead("qs:cfg:" + (string)ch), ["\n"], []);
    string vline = "V:" + llDumpList2String(
        [ version,
          (integer)llList2String(p, 0),                  // MTYPE
          (integer)llList2String(p, 1),                  // ETYPE
          (integer)llList2String(p, 2),                  // SET
          (integer)llList2String(p, 3),                  // SWAP
          llLinksetDataRead("qs:sitter:" + (string)ch),  // sitter blob
          qs_str_replace(llList2String(p, 13), "\\n", "\n"),  // CUSTOM_TEXT
          llList2String(p, 14),                          // ADJUST_MENU (raw, SEP-joined)
          (integer)llList2String(p, 4),                  // SELECT
          (integer)llList2String(p, 5),                  // AMENU
          (integer)llList2String(p, 6)                   // OLD_HELPER_METHOD
        ], "|");
    p = [];
    llMessageLinked(LINK_THIS, 90022, vline, (string)ch);
    qs_dump_ch = ch;
    qs_dump_pi = 0;
    qs_cascade_ch = ch;   // watchdog: this channel's 90021 echoes are now valid
    llMessageLinked(LINK_THIS, 90099, (string)ch, "");
}

// Process exactly one qs:p:<ch>:<pi> entry per call. When the channel is
// exhausted, send 90021 so adjuster's plugin-probe / next-channel cascade
// runs. Returning to the event loop between ticks lets adjuster drain its
// queued 90022 echoes and frees `parts`/`val`.
qs_dump_tick()
{
    if (qs_dump_ch == -1) return;
    string val = llLinksetDataRead(qs_p_key(qs_dump_ch, qs_dump_pi));
    if (val == "")
    {
        integer ch = qs_dump_ch;
        qs_dump_ch = -1;
        llMessageLinked(LINK_THIS, 90021, (string)ch, "");
        return;
    }
    list parts = llParseStringKeepNulls(val, ["|"], []);
    val = "";
    llMessageLinked(LINK_THIS, 90022,
        "S:" + llList2String(parts, 0) + "|" + llList2String(parts, 2),
        (string)qs_dump_ch);
    string pos = llList2String(parts, 3);
    if (pos != "")
    {
        llMessageLinked(LINK_THIS, 90022,
            "{" + llList2String(parts, 0) + "}" + pos + llList2String(parts, 4),
            (string)qs_dump_ch);
    }
    parts = [];
    ++qs_dump_pi;
    // Throttle-pace: arm a one-shot timer instead of firing 90099 now, so the
    // POST flushes stay under SL's HTTP rate limit on big configs (see globals).
    qs_pace_pending = TRUE;
    llSetTimerEvent(QS_DUMP_PACE);
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
            Out(0, "ERROR: " + notecard_name + " notecard missing — boot stopped.");
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
            // sitA/sitB read LSD directly; we just rebuild total_channels
            // (needed by the DUMP cascade), re-arm the timer, and re-probe
            // DUMP plugins so the cached steady state resumes.
            integer ch = 0;
            while (llLinksetDataRead("qs:meta:" + (string)ch) != "")
                ++ch;
            total_channels = ch;
            boot_done = TRUE;
            // Self-check on the skip-seed path too — sitA/sitB presence
            // still needs verification after a script reset. PROP-warn
            // is skipped here (no notecard parse → has_prop_in_notecard
            // stays FALSE). Timer handler runs arm_autosync() after the
            // check, replacing the direct call. 10s safety net (see
            // finalize_boot for rationale); try_complete_selfcheck()
            // short-circuits early when both base scripts report in.
            selfcheck_pending = TRUE;
            llSetTimerEvent(10.0);
        }
        else
        {
            start_boot();
        }
        // Wake any DUMP plugins that came up before boot. Late starters
        // send their own unsolicited QSDUMP_HELLO on state_entry/on_rez.
        llMessageLinked(LINK_SET, QSDUMP_PROBE, "", "");
        // Self-check probes. Replies land in sita_seen / sitb_seen via
        // link_message; try_complete_selfcheck() fires the report once
        // both flags are TRUE (or the 10s safety-net timer fires if not).
        // Strictly needed only on the skip-seed path — on fresh-boot,
        // finalize_boot's QS_BOOT_RELOAD broadcast triggers the same
        // HELLOs via qs_load_from_lsd() anyway. Kept unconditional here
        // so state_entry stays branch-uniform; cost is two LinkMessages.
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        llMessageLinked(LINK_SET, QS_SITB_PROBE, "", "");
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
            Out(1, "Storage wiped — retrying boot.");
            start_boot();
            return;
        }
        // Cancel — stay in error state. CHANGED_INVENTORY on the notecard
        // (or a manual reset) restarts boot fresh; wipe_attempted clears
        // automatically via llResetScript().
        Out(0, "Boot aborted — storage wipe declined.");
    }

    timer()
    {
        if (qs_pace_pending)
        {
            // Paced dump tick: the inter-entry delay elapsed — fire the next
            // streaming step (replaces qs_dump_tick's old immediate 90099).
            qs_pace_pending = FALSE;
            llMessageLinked(LINK_THIS, 90099, (string)qs_dump_ch, "");
            return;
        }
        if (qs_cascade_pending)
        {
            // Cascade watchdog tripped: the plugin we probed went silent (no
            // 90022, no 90021) past the timeout. Warn the owner, then re-emit
            // the channel-done 90021 naming the silent plugin so the 90021
            // handler finds it via llListFindList, ++i skips past it, and the
            // cascade continues (next plugin / next channel / finalize). The
            // dump completes without that plugin's lines instead of hanging.
            qs_cascade_pending = FALSE;
            llRegionSayTo(llGetOwner(), 0,
                "[DUMP] plugin '" + qs_cascade_wait + "' didn't respond — lines omitted.");
            llMessageLinked(LINK_THIS, 90021, (string)qs_cascade_ch, qs_cascade_wait);
            return;
        }
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
        // scripts (sitA/sitB/adjuster/...) is now inconsistent with
        // empty LSD until they're reset or the furniture is re-rezzed.
        if (act == LINKSETDATA_RESET)
            OutForce("LSD was wiped — inconsistent state; reset scripts or re-rez.");
        if (act == LINKSETDATA_RESET || name == "QPP_CFG:AUTOSYNC")
            arm_autosync();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        // No same-prim filter here: the self-check (QSALIVE_REPLY from
        // slot-0 sitA, QS_SITB_HELLO from any sitB) needs to accept
        // messages from sit-prims, which on real furniture are typically
        // child prims separate from boot's root prim. The previous
        // `if (sender != llGetLinkNumber()) return;` (dropped in 0.906)
        // blanket-rejected those, leaving sita_seen/sitb_seen permanently
        // FALSE → false "missing" ERRORs on multi-prim builds like
        // Lalou - Lima Ottoman. Each handler validates payload itself;
        // spoofing from other child-prim scripts in the same linkset is
        // out of scope (owner-controlled assets).
        if (num == QSDUMP_HELLO)
        {
            // DUMP plugin announce. id = announcer's script name. Dedup
            // so repeat announces (on_rez, probe-reply, state_entry race)
            // don't grow the list.
            string plugin = (string)id;
            if (plugin != "" && llListFindList(dump_plugins, [plugin]) == -1)
                dump_plugins += plugin;
            return;
        }
        if (num == QSALIVE_REPLY)
        {
            // Slot-0 sitA reply — flag suffices for the self-check.
            sita_seen = TRUE;
            try_complete_selfcheck();
            return;
        }
        if (num == QS_SITB_HELLO)
        {
            // Any sitB instance answers — one reply is enough to confirm
            // the menu pipeline is present.
            sitb_seen = TRUE;
            try_complete_selfcheck();
            return;
        }
        if (num == 90098)
        {
            // Initial trigger (msg == "0") consumes the id field as a
            // mode marker: id="quiet" → QUICKYHUD-path web-only dump,
            // anything else → stock-style loud dump (full chat output).
            // Cascade re-emits for additional channels (msg >= 1, see
            // 90021 handler) leave dump_quiet untouched so the mode
            // persists across all channels of a multi-channel furniture.
            //
            // Reject gate: initial triggers while a cascade is already
            // running would clobber webkey + cache + qs_dump_pi mid-stream
            // (qs_dump_start unconditionally resets them and emits a fresh
            // V: line), producing a half-uploaded "abc" file on the web
            // service and duplicated pose entries in the "def" file. The
            // gate is keyed on ch == 0 so it only fires for initial
            // triggers — cascade re-emits (ch >= 1) always have
            // qs_dump_ch == -1 (qs_dump_tick clears it before sending 90021,
            // and the 90021 handler advances synchronously), so the gate
            // never blocks normal channel progression.
            integer ch = (integer)msg;
            if (ch == 0 && qs_dump_ch != -1)
            {
                llRegionSayTo(llGetOwner(), 0,
                    "[QS] DUMP already running — wait for URL.");
                return;
            }
            if (ch == 0)
            {
                dump_quiet = ((string)id == "quiet");
                dump_failed = FALSE;
                // No start-hint here — the V: handler (90022 branch
                // below) emits the live-view URL the moment the webkey
                // is generated, which happens in the next event-loop
                // tick. Adding a hint here would just be two rapid-fire
                // chat lines saying the same thing.
                //
                // No total-lines fetch needed — web() reads
                // `notecard_lines` (populated unconditionally at
                // state_entry) directly in quiet mode.
            }
            qs_dump_start(ch);
            return;
        }
        if (num == 90099)
        {
            qs_dump_tick();
            return;
        }
        if (num == 90021)
        {
            // Plugin probe + next-channel cascade. Boot owns this now —
            // when one channel finishes (qs_dump_tick sends 90021, or a
            // plugin script's 90020 worker echoes back 90021), probe the
            // remaining plugin scripts (dump_plugins, populated dynamically
            // via QSDUMP_HELLO; plus the hardcoded stock plugins for which
            // we don't yet control the source) for this channel; once
            // they're done, advance to the next channel via 90098 (back to
            // qs_dump_start) or finalize the upload and shout the URL.
            integer script_channel = (integer)msg;
            // Watchdog: drop a stale 90021 echoed by a plugin we already
            // skipped on a now-finished channel — processing it would
            // double-advance / duplicate output. Only qs_cascade_ch's echoes
            // are currently valid (it is -1 after finalize, so late echoes
            // arriving post-dump are dropped too).
            if (script_channel != qs_cascade_ch) return;
            // A valid 90021 arrived (channel-done, or a plugin echo): whatever
            // we were waiting on has answered, so disarm the wait. The probe
            // loop below re-arms it if it sends a fresh 90020.
            qs_cascade_pending = FALSE;
            // [QS]faces (≥ 0.902) announces via QSDUMP_HELLO, so it lands
            // in dump_plugins automatically. camera_script stays hardcoded
            // until [QS]camera fork exists.
            list scripts = dump_plugins + [camera_script];
            integer i = llListFindList(scripts, [(string)id]);
            while (i < llGetListLength(scripts))
            {
                ++i;
                string lookfor = llList2String(scripts, i);
                if (lookfor == camera_script && script_channel > 0)
                {
                    lookfor = lookfor + " " + (string)script_channel;
                }
                if (llGetInventoryType(lookfor) == INVENTORY_SCRIPT)
                {
                    string probed = llList2String(scripts, i);
                    Out(3, "[DUMP] probing plugin '" + probed + "' for channel " + (string)script_channel);
                    llMessageLinked(LINK_THIS, 90020, (string)script_channel, probed);
                    // Arm the inactivity watchdog: if `probed` neither emits a
                    // dump line (90022) nor echoes 90021 before the timeout,
                    // the timer skips it. Re-armed per 90022 in the receiver.
                    qs_cascade_pending = TRUE;
                    qs_cascade_wait = probed;
                    llSetTimerEvent(QS_CASCADE_TIMEOUT);
                    return;
                }
            }
            if (script_channel + 1 < total_channels)
            {
                // Channel done, no more plugins → advance to the next channel.
                // Clear the active cascade channel (qs_dump_start re-sets it)
                // so a late stale echo from THIS channel is dropped, and hand
                // the timer back to AUTOSYNC (the watchdog only runs during
                // plugin probes).
                qs_cascade_ch = -1;
                arm_autosync();
                llMessageLinked(LINK_THIS, 90098, (string)(script_channel + 1), "");
            }
            else
            {
                // Dump complete — release the cascade watchdog and restore the
                // AUTOSYNC timer before finalizing.
                qs_cascade_ch = -1;
                arm_autosync();
                Readout_Say("");
                Readout_Say("--✄--COPY ABOVE INTO \"AVpos\" NOTECARD--✄--");
                Readout_Say("");
                web(TRUE);
                // End-of-cascade chat. Quiet mode already gave the URL
                // upfront, so we only emit a completion / failure
                // signal here. Loud mode keeps the stock end-of-dump
                // URL shout (URL wasn't emitted earlier in that path).
                if (dump_quiet)
                {
                    if (dump_failed)
                    {
                        llRegionSayTo(llGetOwner(), 0,
                            "[DUMP] Upload failed — link may be incomplete.");
                    }
                    else
                    {
                        llRegionSayTo(llGetOwner(), 0,
                            "[DUMP] Done — link finalized.");
                    }
                }
                else
                {
                    llRegionSayTo(llGetOwner(), 0,
                        "Settings copy: " + dump_url() + "?q=" + webkey);
                }
                dump_quiet = FALSE;
            }
            return;
        }
        if (num == 90022)
        {
            // Watchdog: a dump line from the plugin we're waiting on proves it
            // is alive and working — push the timeout back so a slow, many-line
            // plugin is never falsely skipped. Only relevant during a plugin
            // probe (qs_cascade_pending); boot's own pose lines stream with the
            // watchdog idle.
            if (qs_cascade_pending) llSetTimerEvent(QS_CASCADE_TIMEOUT);
            // Format one dump line and Readout_Say it. Sources: boot's
            // own qs_dump_start/qs_dump_tick (V:/S:/{}) and plugin
            // scripts (announced via QSDUMP — [QS]prop, [QS]faces —
            // plus the hardcoded camera_script) that the 90021 cascade
            // wakes via 90020.
            list data = llParseStringKeepNulls(msg, ["|"], []);
            if (llGetSubString(msg, 0, 3) == "S:M:" || llGetSubString(msg, 0, 3) == "S:T:")
            {
                msg = qs_str_replace(msg, "*|", "|");
            }
            if (llGetSubString(msg, 0, 1) == "V:")
            {
                if (!(integer)((string)id))
                {
                    webkey = (string)llGenerateKey();
                    webcount = 0;
                    // Quiet-mode live-view URL: shouted upfront so the
                    // owner can open the link the moment the dump
                    // starts and watch chunks accumulate in the
                    // browser (settings.php serves partial content +
                    // Refresh: 3 until the .done marker lands).
                    if (dump_quiet)
                    {
                        llRegionSayTo(llGetOwner(), 0,
                            "[DUMP] Live view: " + dump_url() + "?q=" + webkey);
                    }
                    Readout_Say("");
                    Readout_Say("--✄--COPY BELOW INTO \"AVpos\" NOTECARD--✄--");
                    Readout_Say("");
                    Readout_Say("\"" + llToUpper(llGetObjectName()) + "\" " + qs_str_replace(llList2String(data, 0), "V:", "QuickySitter "));
                    if (llList2Integer(data, 1))
                    {
                        Readout_Say("MTYPE " + llList2String(data, 1));
                    }
                    if (llList2Integer(data, 2) != 1)
                    {
                        Readout_Say("ETYPE " + llList2String(data, 2));
                    }
                    if (llList2Integer(data, 3) > -1)
                    {
                        Readout_Say("SET " + llList2String(data, 3));
                    }
                    if (llList2Integer(data, 4) != 2)
                    {
                        Readout_Say("SWAP " + llList2String(data, 4));
                    }
                    if (llList2String(data, 6) != "")
                    {
                        Readout_Say("TEXT " + qs_str_replace(llList2String(data, 6), "\n", "\\n"));
                    }
                    if (llList2String(data, 7) != "")
                    {
                        Readout_Say("ADJUST " + qs_str_replace(llList2String(data, 7), SEP, "|"));
                    }
                    if (llList2Integer(data, 8))
                    {
                        Readout_Say("SELECT " + llList2String(data, 8));
                    }
                    if (llList2Integer(data, 9) != 2)
                    {
                        Readout_Say("AMENU " + llList2String(data, 9));
                    }
                    if (llList2Integer(data, 10))
                    {
                        Readout_Say("HELPER " + llList2String(data, 10));
                    }
                    // VERBOSE is global (not per-channel) — read from
                    // qs:cfg:verbose directly. Emit only when > 0; stock
                    // AVsitter parses it as unknown-command and ignores,
                    // so the dumped notecard stays portable.
                    string vstr = llLinksetDataRead("qs:cfg:verbose");
                    if (vstr != "" && (integer)vstr > 0)
                    {
                        Readout_Say("VERBOSE " + vstr);
                    }
                }
                Readout_Say("");
                if (total_channels > 1 || llList2String(data, 5) != "")
                {
                    string SITTER_TEXT;
                    if (llList2String(data, 5) != "")
                    {
                        SITTER_TEXT = "|" + qs_str_replace(llList2String(data, 5), SEP, "|");
                    }
                    Readout_Say("SITTER " + (string)id + SITTER_TEXT);
                    Readout_Say("");
                }
                return;
            }
            else if (llGetSubString(msg, 0, 0) == "{")
            {
                msg = qs_str_replace(msg, "{P:", "{");
                list parts = llParseStringKeepNulls(llDumpList2String(llParseString2List(llGetSubString(msg, llSubStringIndex(msg, "}") + 1, 99999), [" "], [""]), ""), ["<"], []);
                vector pos2 = (vector)("<" + llList2String(parts, 1));
                vector rot2 = (vector)("<" + llList2String(parts, 2));
                string result = "<" + FormatFloat(pos2.x, 3) + "," + FormatFloat(pos2.y, 3) + "," + FormatFloat(pos2.z, 3) + ">";
                result += "<" + FormatFloat(rot2.x, 1) + "," + FormatFloat(rot2.y, 1) + "," + FormatFloat(rot2.z, 1) + ">";
                msg = llGetSubString(msg, 0, llSubStringIndex(msg, "}")) + result;
            }
            else if (llGetSubString(msg, 1, 1) == ":")
            {
                msg = qs_str_replace(msg, "S:P:", "POSE ");
                msg = qs_str_replace(msg, "S:M:", "MENU ");
                msg = qs_str_replace(msg, "S:T:", "TOMENU ");
                if (llGetSubString(msg, -6, -1) == "|90210")
                {
                    msg = qs_str_replace(msg, "S:B:", "SEQUENCE ");
                    msg = qs_str_replace(msg, "|90210", "");
                }
                else
                {
                    msg = qs_str_replace(msg, "S:B:", "BUTTON ");
                    if (llSubStringIndex(msg, SEP) == -1)
                    {
                        msg = qs_str_replace(msg, "|90200", "");
                    }
                }
                msg = qs_str_replace(msg, "S:", "SYNC ");
                msg = qs_str_replace(msg, SEP, "|");
            }
            if (llGetSubString(msg, -1, -1) == "*")
            {
                msg = llGetSubString(msg, 0, -2);
            }
            if (llGetSubString(msg, -1, -1) == "|")
            {
                msg = llGetSubString(msg, 0, -2);
            }
            if (llGetSubString(msg, 0, 3) == "MENU")
            {
                Readout_Say("");
            }
            Readout_Say(msg);
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
        data = llStringTrim(data, STRING_TRIM_HEAD);
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

        if (command == "SITTER")
        {
            integer s_ch = (integer)part0;
            // Flush the previous channel's sitter row before resetting
            // per-channel locals. qs:cfg/qs:meta wait until EOF — GENDERS
            // is still accumulating across the rest of the notecard.
            if (current_channel >= 0)
                flush_channel_sitter(current_channel);
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
        if (command == "BRAND")  { BRAND = part0; return; }
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
                llLinksetDataDeleteFound("^qs:(meta|cfg|sitter|p|nm|nt|boot):", "");
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
                // "[QS]sitA missing" ERRORs.
                if (selfcheck_pending) llSetTimerEvent(10.0);
            }
        }
    }

    // QS DUMP-endpoint failure detection. Stock-loud dumps go to
    // avsitter.com (not our concern, chat fallback already covers).
    // Quiet dumps go to url_qs (self-hosted) — if any chunk POST
    // returns non-200, set dump_failed so the end-of-cascade URL
    // shout flips to a chat-only failure hint instead of advertising
    // a dead/incomplete link. Race note: web(TRUE) is async, so the
    // FINAL chunk's response may not have arrived when the URL shout
    // fires (HTTP responses come after the next event loop tick).
    // Intermediate-chunk failures are caught reliably; same-connection
    // final-chunk-only failures are rare in practice.
    http_response(key request_id, integer status, list metadata, string body)
    {
        if (dump_quiet && status != 200)
        {
            dump_failed = TRUE;
        }
    }
}
