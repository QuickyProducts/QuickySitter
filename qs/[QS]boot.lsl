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

string version = "0.904";
string notecard_name = "AVpos";
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

// QS_BOOT_RELOAD — broadcast at the end of the seed cascade so already-
// running sitB scripts re-read MENU_LIST from the freshly-written LSD
// instead of staying on the stale list from their last state_entry.
// Without this, a notecard re-save requires manual reset on every sitB.
integer QS_BOOT_RELOAD = 90023;

// [DUMP] output pipeline. Migrated from adjuster: cache fills via
// Readout_Say, web() flushes to the AVsitter settings service every
// ~1024 escaped chars or on force(TRUE) at the end of the cascade.
string url = "https://avsitter.com/settings.php";
string cache;
string webkey;
integer webcount;

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
integer qs_dump_ch = -1;
integer qs_dump_pi;

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
        llOwnerSay(llGetScriptName() + "[" + version + "] ERROR: storage still full after wipe — " + notecard_name + " has too many entries. Reduce poses/sitters in the notecard.");
        return;
    }
    llOwnerSay(llGetScriptName() + "[" + version + "] ERROR: storage full at " + k + " — see dialog to wipe entire storage and retry.");
    show_wipe_dialog();
}

qs_p_write(integer ch, integer i, string name, string type, string anim, string pos, string rot)
{
    qs_lsd_write(qs_p_key(ch, i), name + "|" + type + "|" + anim + "|" + pos + "|" + rot);
}

// Reverse-lookup a seed name to its qs:p:<ch>:<i> index. Replaces the
// `llListFindList(seed_names, ...)` calls that the parser used for
// {Posename}<pos><rot> default-offset resolution. Tries the bare name
// first, then with a "P:" prefix — same fallback order as the original
// two-call sequence. Returns -1 on miss.
integer qs_seed_find(integer ch, string nm)
{
    integer i;
    string  v;
    string  n;
    for (i = 0; i < seed_count; ++i)
    {
        v = llLinksetDataRead(qs_p_key(ch, i));
        n = llGetSubString(v, 0, llSubStringIndex(v, "|") - 1);
        if (n == nm) return i;
    }
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
qs_loading_text(integer cur, integer total, string msg)
{
    if (total <= 0) total = 1;
    integer pct = cur * 100 / total;
    if (pct > 100) pct = 100;
    integer filled = pct / 5;
    string bar = llGetSubString("████████████████████░░░░░░░░░░░░░░░░░░░░", 20 - filled, 39 - filled);
    llSetText(msg + "\n[" + bar + "] " + (string)pct + "%", <1, 1, 0>, 1);
}

reset_channel_locals()
{
    SITTER_INFO = [];
    seed_count = 0;
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
    llOwnerSay(llGetScriptName() + "[" + version + "] Load complete; " + (string)total_channels + " sitter(s) ready. Mem=" + (string)(65536 - llGetUsedMemory()) + " Storage=" + (string)llLinksetDataAvailable());
    // Tell sibling sitB scripts to refresh from LSD. They missed our
    // mid-boot writes if they were already past state_entry.
    llMessageLinked(LINK_SET, QS_BOOT_RELOAD, "", "");
    arm_autosync();
}

// Kick off (or restart) the notecard read. Called from state_entry and
// from the wipe-confirmation listen handler after llLinksetDataReset().
start_boot()
{
    current_channel = -1;
    boot_done = FALSE;
    boot_failed = FALSE;
    reused_key = llGetNumberOfNotecardLines(notecard_name);
    reused_variable = 0;
    notecard_lines = 0;
    llOwnerSay(llGetScriptName() + "[" + version + "] Loading from " + notecard_name + "...");
    notecard_query = llGetNotecardLine(notecard_name, 0);
}

// Read QPP_CFG:AUTOSYNC and arm the timer accordingly. Idempotent: safe
// to call from finalize_boot, linkset_data, or after manual changes.
// Skips while boot is still running so we don't trample the boot flow.
arm_autosync()
{
    if (!boot_done) return;
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

web(integer force)
{
    if (llStringLength(llEscapeURL(cache)) > 1024 || force)
    {
        if (force)
        {
            cache += "\n\nend";
        }
        webcount++;
        llHTTPRequest(url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/x-www-form-urlencoded", HTTP_VERIFY_CERT, FALSE], "w=" + webkey + "&c=" + (string)webcount + "&t=" + llEscapeURL(cache));
        cache = "";
    }
}

Readout_Say(string say)
{
    string objectname = llGetObjectName();
    llSetObjectName("");
    llRegionSayTo(llGetOwner(), 0, "◆" + say);
    llSetObjectName(objectname);
    cache += say + "\n";
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
    llMessageLinked(LINK_THIS, 90099, (string)qs_dump_ch, "");
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
        notecard_key = llGetInventoryKey(notecard_name);
        if (llGetInventoryType(notecard_name) != INVENTORY_NOTECARD)
        {
            // No notecard → no slot config. Refuse to boot. Re-arm on
            // CHANGED_INVENTORY: notecard_key is NULL_KEY here, so adding
            // the notecard will flip the asset-key compare and reset.
            llSetText("ERROR: " + notecard_name + " notecard missing", <1, 0, 0>, 1);
            llOwnerSay(llGetScriptName() + "[" + version + "] ERROR: " + notecard_name + " notecard missing — boot stopped.");
            return;
        }
        if (llLinksetDataRead("qs:boot:asset") == (string)notecard_key)
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
            arm_autosync();
        }
        else
        {
            start_boot();
        }
        // Wake any DUMP plugins that came up before boot. Late starters
        // send their own unsolicited QSDUMP_HELLO on state_entry/on_rez.
        llMessageLinked(LINK_SET, QSDUMP_PROBE, "", "");
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
            llOwnerSay(llGetScriptName() + "[" + version + "] Storage wiped — retrying boot.");
            start_boot();
            return;
        }
        // Cancel — stay in error state. CHANGED_INVENTORY on the notecard
        // (or a manual reset) restarts boot fresh; wipe_attempted clears
        // automatically via llResetScript().
        llOwnerSay(llGetScriptName() + "[" + version + "] Boot aborted — storage wipe declined.");
    }

    timer()
    {
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
        // settings dialog) or the whole LSD is reset (/88 nuke).
        if (act == LINKSETDATA_RESET || name == "QPP_CFG:AUTOSYNC")
            arm_autosync();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (sender != llGetLinkNumber()) return;
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
        if (num == 90098)
        {
            qs_dump_start((integer)msg);
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
                    llMessageLinked(LINK_THIS, 90020, (string)script_channel, llList2String(scripts, i));
                    return;
                }
            }
            if (script_channel + 1 < total_channels)
            {
                llMessageLinked(LINK_THIS, 90098, (string)(script_channel + 1), "");
            }
            else
            {
                Readout_Say("");
                Readout_Say("--✄--COPY ABOVE INTO \"AVpos\" NOTECARD--✄--");
                Readout_Say("");
                web(TRUE);
                llRegionSayTo(llGetOwner(), 0, "Settings copy: " + url + "?q=" + webkey);
            }
            return;
        }
        if (num == 90022)
        {
            // Format one dump line and Readout_Say it. Sources: boot's
            // own qs_dump_start/qs_dump_tick (V:/S:/{}) and plugin
            // scripts ([AV]prop / [AV]faces / [AV]camera) that the 90021
            // cascade wakes via 90020.
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
                    Readout_Say("");
                    Readout_Say("--✄--COPY BELOW INTO \"AVpos\" NOTECARD--✄--");
                    Readout_Say("");
                    Readout_Say("\"" + llToUpper(llGetObjectName()) + "\" " + qs_str_replace(llList2String(data, 0), "V:", "AVsitter "));
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
                }
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_INVENTORY)
        {
            // Notecard is the source of truth — a notecard save/swap mints
            // a new asset key, which triggers reset + re-seed. Inventory
            // changes without a notecard touch (e.g. an extra [QS]sitA
            // dropped) are ignored — adding a slot requires a matching
            // SITTER directive in AVpos, which flips the asset key anyway.
            if (llGetInventoryKey(notecard_name) != notecard_key)
            {
                llLinksetDataDeleteFound("^qs:(meta|cfg|sitter|p|boot):", "");
                llResetScript();
            }
        }
    }
}
