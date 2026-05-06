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

string #version = "0.01";
string notecard_name = "AVpos";
string main_script = "[QS]sitA";
string memoryscript = "[QS]sitB";

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
            ADJUST_MENU = parts;
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
