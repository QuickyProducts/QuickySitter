/*
 * [QS]boot - QuickySitter loader
 *
 * Pure one-shot LSD writer. On reset, for each [QS]sitA channel:
 *   • if qs:meta:<ch> is set → already seeded, skip
 *   • else → parse AVpos notecard, write qs:cfg:<ch>, qs:sitter:<ch>,
 *            qs:p:<ch>:<i>, finally qs:meta:<ch>
 *
 * After all channels are seeded, resets every [QS]sitA and [QS]sitB
 * script in the prim so they bootstrap themselves from LSD. From that
 * point on, boot is idle until inventory changes (notecard or sitA-count)
 * trigger another reset.
 *
 * No message dispatching. sitA and sitB read LSD directly. Boot is the
 * sole source of LSD writes during seed; the adjuster writes LSD for
 * live creator edits at runtime, independently.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.02";
string notecard_name = "AVpos";
string main_script = "[QS]sitA";
string memoryscript = "[QS]sitB";
string prop_script = "[AV]prop";
string expression_script = "[AV]faces";
string camera_script = "[AV]camera";

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
// RESYNC: periodically restart SYNC-pose animations to fight Interest-List
// drift between viewers. Default ON (1). `RESYNC OFF` in the AVpos notecard
// disables it for this furniture. See PROTOCOL.md and qs/TESTPLAN.md.
integer RESYNC = 1;
string BRAND;
string onSit;
string CUSTOM_TEXT;
list ADJUST_MENU;
string RLVDesignations;
list GENDERS;

// Per-current-channel parse state. Reset on each channel switch.
integer SCRIPT_CHANNEL;
list SITTER_INFO;
list seed_names;
integer reading_notecard_section;

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

// Boot orchestration.
integer total_channels;
integer current_processing_channel;
integer load_t0;

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

qs_p_write(integer ch, integer i, string name, string type, string anim, string pos, string rot)
{
    llLinksetDataWrite(qs_p_key(ch, i), name + "|" + type + "|" + anim + "|" + pos + "|" + rot);
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
        , RESYNC                           // index 17 — see STORAGE.md
        ], "\n");
}

// Render bar + ETA. 20-cell bar sliced from a pre-built constant.
qs_loading_text(integer cur, integer total, string msg)
{
    if (total <= 0) total = 1;
    integer pct = cur * 100 / total;
    if (pct > 100) pct = 100;
    integer filled = pct / 5;
    string bar = llGetSubString("████████████████████░░░░░░░░░░░░░░░░░░░░", 20 - filled, 39 - filled);
    integer elapsed = llGetUnixTime() - load_t0;
    string eta;
    if (cur >= total) eta = "Done";
    else if (cur > 0 && elapsed > 0)
    {
        integer r = elapsed * (total - cur) / cur;
        if (r > 60) eta = "Est. " + (string)((r + 30) / 60) + " min";
        else if (r > 0) eta = "Est. " + (string)r + " sec";
        else eta = "Est. <1 sec";
    }
    else eta = "Estimating…";
    llSetText(msg + "\n[" + bar + "] " + (string)pct + "%\n" + eta, <1, 1, 0>, 1);
}

reset_channel_locals()
{
    SITTER_INFO = [];
    seed_names = [];
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
// Boot state machine
// ========================================================================

integer count_channels()
{
    integer i = 1;
    while (llGetInventoryType(main_script + " " + (string)i) == INVENTORY_SCRIPT)
        ++i;
    return i;
}

start_seed_for_channel(integer ch)
{
    SCRIPT_CHANNEL = ch;
    reading_notecard_section = FALSE;
    reset_channel_locals();
    // Wipe any partial state from a prior aborted seed on this channel.
    llLinksetDataDeleteFound("^qs:p:" + (string)ch + ":[0-9]+$", "");

    if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
    {
        // Refresh line count per channel so the bar resets cleanly each pass.
        reused_key = llGetNumberOfNotecardLines(notecard_name);
        reused_variable = 0;
        notecard_lines = 0;
        notecard_query = llGetNotecardLine(notecard_name, 0);
    }
    else
    {
        // No notecard. Seed channel as empty and advance.
        llLinksetDataWrite("qs:cfg:" + (string)ch, qs_cfg_pack());
        llLinksetDataWrite("qs:sitter:" + (string)ch, "");
        llLinksetDataWrite("qs:meta:" + (string)ch, "qs1");
        ++current_processing_channel;
        llSetTimerEvent(0.01);
    }
}

// Done seeding. sitA/sitB poll qs:meta:<ch> in their state_entry and pick
// up the data themselves once we've written meta. No reset needed.
finalize_boot()
{
    llSetText("", <1, 1, 1>, 1);
    llOwnerSay(llGetScriptName() + "[" + version + "] Seed complete; " + (string)total_channels + " channel(s) ready. Mem=" + (string)(65536 - llGetUsedMemory()));
}

process_next_channel()
{
    if (current_processing_channel >= total_channels)
    {
        finalize_boot();
        return;
    }
    integer ch = current_processing_channel;
    if (llLinksetDataRead("qs:meta:" + (string)ch) != "")
    {
        // Already seeded — skip and advance.
        ++current_processing_channel;
        llSetTimerEvent(0.01);
    }
    else
    {
        // Needs seed — read notecard.
        start_seed_for_channel(ch);
    }
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
          (integer)llList2String(p, 6),                  // OLD_HELPER_METHOD
          llList2String(p, 17)                           // RESYNC ("" = default-on)
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
        // Wait for [QS]sitB (channel 0) to exist as a sanity check.
        while (llGetInventoryType(memoryscript) != INVENTORY_SCRIPT)
            llSleep(0.1);

        total_channels = count_channels();
        notecard_key = llGetInventoryKey(notecard_name);
        current_processing_channel = 0;
        load_t0 = llGetUnixTime();
        llOwnerSay(llGetScriptName() + "[" + version + "] Seeding " + (string)total_channels + " channel(s)...");
        process_next_channel();
    }

    timer()
    {
        llSetTimerEvent(0);
        process_next_channel();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (sender != llGetLinkNumber()) return;
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
            // remaining plugin scripts ([AV]prop / [AV]faces / [AV]camera)
            // for this channel; once they're done, advance to the next
            // channel via 90098 (back to qs_dump_start) or finalize the
            // upload and shout the URL.
            integer script_channel = (integer)msg;
            list scripts = [prop_script, expression_script, camera_script];
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
            if (llGetInventoryType(main_script + " " + (string)(script_channel + 1)) == INVENTORY_SCRIPT)
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
                    // RESYNC default is on. Emit only when explicitly disabled.
                    // Empty (pre-RESYNC cfg dump) → treat as default = on, no emit.
                    string rs = llList2String(data, 11);
                    if (rs != "" && (integer)rs == 0)
                    {
                        Readout_Say("RESYNC OFF");
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
        if (data == EOF)
        {
            // Persist this channel's settings + sitter row, mark meta last.
            llLinksetDataWrite("qs:cfg:" + (string)SCRIPT_CHANNEL, qs_cfg_pack());
            llLinksetDataWrite("qs:sitter:" + (string)SCRIPT_CHANNEL, llDumpList2String(SITTER_INFO, SEP));
            llLinksetDataWrite("qs:meta:" + (string)SCRIPT_CHANNEL, "qs1");
            ++current_processing_channel;
            llSetTimerEvent(0.01);
            return;
        }
        if (notecard_lines)
            qs_loading_text(reused_variable, notecard_lines, "Seeding channel " + (string)SCRIPT_CHANNEL + " from " + notecard_name);

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
            reading_notecard_section = FALSE;
            integer s_ch = (integer)part0;
            if (s_ch == 0)
                GENDERS = [];
            integer g = -1;
            if (llList2String(parts, 2) == "M") g = 1;
            else if (llList2String(parts, 2) == "F") g = 0;
            GENDERS += g;
            if (s_ch == SCRIPT_CHANNEL)
            {
                reading_notecard_section = TRUE;
                if (llGetListLength(parts) > 1)
                    SITTER_INFO = llList2List(parts, 1, 99999);
            }
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
        if (command == "RESYNC")
        {
            // RESYNC OFF / RESYNC 0 → disabled. Anything else → enabled.
            // Default is enabled when the directive is absent.
            string up = llToUpper(part0);
            RESYNC = !(up == "OFF" || up == "0" || up == "FALSE" || up == "NO");
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

        // ===== Stock AVsitter sitA dataserver — verbatim parser block =====
        // Only difference: where stock dispatches 90300/90301 to sitB, we
        // also write to LSD. Locals (FIRST_POSENAME etc.) are kept even
        // though boot doesn't use them, so the parser flow matches stock
        // byte-for-byte.
        if (reading_notecard_section)
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
                integer si = llListFindList(seed_names, [command]);
                if (si == -1)
                    si = llListFindList(seed_names, ["P:" + command]);
                if (si != -1)
                {
                    list cur = llParseStringKeepNulls(llLinksetDataRead(qs_p_key(SCRIPT_CHANNEL, si)), ["|"], []);
                    qs_p_write(SCRIPT_CHANNEL, si,
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
                    integer si = llGetListLength(seed_names);
                    seed_names += part0;
                    qs_p_write(SCRIPT_CHANNEL, si, part0, t, part1, "", "");
                }
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_INVENTORY)
        {
            // Reset only on actual content change — notecard swap or sitA-count.
            if (llGetInventoryKey(notecard_name) != notecard_key
                || count_channels() != total_channels)
            {
                llResetScript();
            }
        }
    }
}
