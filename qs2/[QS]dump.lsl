string version = "0.01";

/*
 * [QS]dump - QuickySitter v2 settings dump (AUTHORING TOOL)
 *
 * The complete [DUMP] pipeline, moved out of [QS]boot 0.05: readout
 * formatting, chat output, the streaming read-back of qs:p:*, the plugin
 * probe cascade, and the HTTP upload to the settings receiver.
 *
 * WHY IT MOVED. boot is the tightest script of the set (~5 KB free,
 * measured 2026-08-16) and its notecard-parse transients ride on that
 * rest - while everything in THIS file is creator-time only, which the
 * design principle (DESIGN.md: no authoring code in the base scripts)
 * says does not belong in the base set to begin with. v1 had pulled the
 * dump INTO boot because the adjuster was full; v2 gives it its own
 * script instead.
 *
 * IT SHIPS AND LEAVES WITH THE ADJUSTER. The only [DUMP] trigger is the
 * adjuster's dialog (90098) - hudproxy does not send it, so finalised
 * furniture has no dump path anyway (verified 2026-08-16 across both
 * repos). On '/5 cleanup' the adjuster broadcasts QS_FINALIZE (90215)
 * and this script removes itself like every other creator-only tool.
 *
 * THE WIRE IS UNCHANGED - this is the same code listening in a
 * different script, same prim: 90098 start (id "quiet" = web-only,
 * else loud), 90099 per-entry tick, 90020 plugin probe, 90021
 * channel/plugin done, 90022 dump line, QSDUMP 90094/90095 discovery.
 * Data comes straight from LSD (qs:cfg / qs:sitter / qs:p:*), which is
 * what makes the cut this clean: boot seeds it, this reads it back.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

integer verbose = 0;
Out(integer level, string msg)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + msg);
}

// camera plugin name is an AVsitter protocol constant - stock plugin
// probes and replies by literal script name. Once [QS]camera adopts
// QSDUMP_HELLO (like [QS]faces 0.902 and [QS]prop do), this constant
// can go too.
string camera_script = "[AV]camera";

// QSDUMP - DUMP plugin discovery via announce/probe handshake, mirroring
// the QSALIVE pattern. Plugins announce themselves on state_entry/on_rez;
// we probe once during our own state_entry to wake plugins that came up
// before us. See qs/PROTOCOL.md § QSDUMP for the full contract.
integer QSDUMP_PROBE = 90094;
integer QSDUMP_HELLO = 90095;
list dump_plugins;

integer QS_ALIVE_CENSUS = 90079;   // boot wiped presence, re-stamp
integer QS_FINALIZE     = 90215;   // adjuster '/5 cleanup': remove thyself

// Both dump modes post to the self-hosted receiver (qs/php/settings.php
// at slquicky.com, same w/c/t POST + ?q GET protocol as the retired
// stock avsitter.com service). `url` serves the loud [HELPER] path
// (since 1.25 - avsitter.com stopped working with QS output, issue #66;
// chat output remains that path's primary deliverable, see
// http_response), `url_qs` the quiet [QUICKYHUD] path. Two constants
// kept so the modes can be split again if a stock endpoint revives.
// web() picks the endpoint per-request based on `dump_quiet`.
// http_response sets `dump_failed` when the QS endpoint returns non-200
// on a quiet dump so the end-of-cascade URL shout can fall back to a
// chat-only failure hint instead of a dead link.
string url    = "https://slquicky.com/quicky-sitter/dump/settings.php";
string url_qs = "https://slquicky.com/quicky-sitter/dump/settings.php";
string cache;
string webkey;
integer webcount;
integer dump_failed;

// Streaming-dump state. Adjuster sends 90098 to start a channel; we
// stream the V: line synchronously, then tick via 90099 - one qs:p
// entry per event - so per-iteration locals are released and the 90022
// echo queue drains between ticks. Idle when qs_dump_ch == -1.
//
// dump_quiet: when TRUE, Readout_Say feeds the web cache only and
// skips the per-line llRegionSayTo to the owner - including the
// `--✄--COPY ABOVE/BELOW--✄--` banners (they still land in the web
// cache because the AVpos paste format expects them, just not in chat).
// The only chat output in quiet mode is the live-view URL from the V:
// handler and either the final completion shout or a `[DUMP] Upload
// failed` hint (per dump_failed) after web(TRUE). Set from the initial
// 90098 trigger's id field (id="quiet" → quiet, anything else → loud,
// preserving stock-style helper [DUMP] behavior). Reset at end of the
// cascade. See qs/PROTOCOL.md § DUMP.
integer qs_dump_ch = -1;
integer qs_dump_pi;
integer dump_quiet;

// Cascade watchdog. The 90021 plugin-probe cascade sends 90020 to each
// DUMP-capable plugin, then waits for it to echo 90021 back - with no
// built-in timeout. A non-conformant plugin that never echoes (a
// third-party DUMP plugin, or a mismatched camera) would park the dump
// forever, stalling exactly where the next "SITTER" line should print,
// with no footer. After each 90020 we arm a one-shot inactivity timer;
// every dump line the plugin emits (90022) re-arms it, so a slow but
// working plugin is never falsely skipped - only true silence trips it.
// On trip we re-emit the channel-done 90021 ourselves, naming the silent
// plugin, so the cascade skips past it and the dump finishes (minus that
// plugin's lines) instead of hanging.
integer qs_cascade_pending;        // TRUE while waiting for a probed plugin's 90021
integer qs_cascade_ch = -1;        // channel whose cascade is active (-1 = none)
string  qs_cascade_wait;           // script we sent 90020 to and are waiting on
float   QS_CASCADE_TIMEOUT = 5.0;  // seconds of plugin silence before we skip it

// Dump pacing. The stream is throttle-paced like stock AVsitter's
// per-line llSleep(0.2): instead of firing the next 90099 tick
// immediately, qs_dump_tick arms a one-shot timer and timer() fires it
// after QS_DUMP_PACE. Keeps the dump's HTTP POSTs well under SL's ~1/sec
// llHTTPRequest throttle (a big config otherwise bursts ~25 chunk-POSTs
// and trips "Too many HTTP requests too fast") while staying
// event-driven - peak RAM is still one entry, no blocking loop.
integer qs_pace_pending;           // TRUE while a paced 90099 self-tick is timer-armed
float   QS_DUMP_PACE = 0.2;        // seconds between dump entries (stock parity)

// Channel count for the cascade's "next channel or finalize" decision.
// boot derives it at parse time; we re-derive it from qs:meta:* at every
// dump start, so a re-seed between dumps cannot leave a stale count.
integer total_channels;

// Notecard line count for the quiet-mode &n= progress param. Fetched
// asynchronously at dump start; the `> 0` gate in web() covers the race
// where the first chunk flushes before the dataserver response lands.
string notecard_name = "AVpos";
key lines_query;
integer notecard_lines;

// SEP = U+FFFD. Initialized at runtime via llUnescapeURL because the
// SL script editor mangles a literal U+FFFD to 0x20 (space) on upload,
// which silently splits anim names containing spaces.
string SEP;

// ------------------------------------------------------------- helpers

string qs_p_key(integer ch, integer i)
{
    return "qs:p:" + (string)ch + ":" + (string)i;
}

string qs_str_replace(string s, string find, string replace)
{
    return llDumpList2String(llParseStringKeepNulls(s, [find], []), replace);
}

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
        // tiny race where the first chunk flushes before the async
        // line-count response lands (later chunks still send &n=).
        // Loud-mode skips it (stock endpoint ignores unknown params
        // anyway).
        string params = "w=" + webkey + "&c=" + (string)webcount;
        if (dump_quiet && notecard_lines > 0)
        {
            params += "&n=" + (string)notecard_lines;
        }
        params += "&t=" + llEscapeURL(cache);
        // Throttle guard: llHTTPRequest returns NULL_KEY *synchronously* when the
        // per-object HTTP rate limit (~25 req / 20s) is hit - the chunk is
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
// [DUMP] streaming. Symmetric to boot's seed phase: read what it wrote,
// emit AVpos-style 90022 lines for the Readout_Say/web pipeline above.
// Runs off 90098 (start) + 90099 (per-entry tick) so peak memory stays
// small.
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
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        // Presence for boot's census bookkeeping, same mechanism as every
        // plugin. Not part of the base-script self-check: this tool is
        // optional by design.
        llLinksetDataWrite("qs:alive:dump", "1");
        // Wake any DUMP plugins that came up before us. Late starters
        // send their own unsolicited QSDUMP_HELLO on state_entry/on_rez.
        llMessageLinked(LINK_SET, QSDUMP_PROBE, "", "");
    }

    on_rez(integer p)
    {
        // A rezzed copy must not resume a half-done dump from serialized
        // state - webkey, cascade and pace flags are all meaningless in
        // the new region context.
        llResetScript();
    }

    timer()
    {
        if (qs_pace_pending)
        {
            // Paced dump tick: the inter-entry delay elapsed - fire the next
            // streaming step.
            qs_pace_pending = FALSE;
            llSetTimerEvent(0);
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
            llSetTimerEvent(0);
            llRegionSayTo(llGetOwner(), 0,
                "[DUMP] plugin '" + qs_cascade_wait + "' didn't respond - lines omitted.");
            llMessageLinked(LINK_THIS, 90021, (string)qs_cascade_ch, qs_cascade_wait);
            return;
        }
        // Defensive: stop unexpected ticks.
        llSetTimerEvent(0);
    }

    dataserver(key query_id, string data)
    {
        if (query_id == lines_query)
            notecard_lines = (integer)data;
    }

    link_message(integer sender, integer num, string msg, key id)
    {
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
        if (num == QS_ALIVE_CENSUS)
        {
            llLinksetDataWrite("qs:alive:dump", "1");
            return;
        }
        if (num == QS_FINALIZE)
        {
            // '/5 cleanup': creator-only tools remove THEMSELVES
            // (adjuster's 90215 broadcast). Retract the presence flag
            // first - boot's census is a race here, see the adjuster's
            // cleanup handler for the field report.
            llLinksetDataDelete("qs:alive:dump");
            llRemoveInventory(llGetScriptName());
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
            // triggers - cascade re-emits (ch >= 1) always have
            // qs_dump_ch == -1 (qs_dump_tick clears it before sending 90021,
            // and the 90021 handler advances synchronously), so the gate
            // never blocks normal channel progression.
            integer ch = (integer)msg;
            if (ch == 0 && qs_dump_ch != -1)
            {
                llRegionSayTo(llGetOwner(), 0,
                    "[QS] DUMP already running - wait for URL.");
                return;
            }
            if (ch == 0)
            {
                dump_quiet = ((string)id == "quiet");
                dump_failed = FALSE;
                // Re-derive the channel count from what boot seeded, so a
                // re-seed between dumps cannot leave this stale.
                integer c = 0;
                while (llLinksetDataRead("qs:meta:" + (string)c) != "")
                    ++c;
                total_channels = c;
                // Line count for the quiet-mode progress param, async.
                if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
                    lines_query = llGetNumberOfNotecardLines(notecard_name);
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
            // Plugin probe + next-channel cascade: when one channel
            // finishes (qs_dump_tick sends 90021, or a plugin script's
            // 90020 worker echoes back 90021), probe the remaining plugin
            // scripts (dump_plugins, populated dynamically via
            // QSDUMP_HELLO; plus the hardcoded stock plugins for which
            // we don't yet control the source) for this channel; once
            // they're done, advance to the next channel via 90098 (back to
            // qs_dump_start) or finalize the upload and shout the URL.
            integer script_channel = (integer)msg;
            // Watchdog: drop a stale 90021 echoed by a plugin we already
            // skipped on a now-finished channel - processing it would
            // double-advance / duplicate output. Only qs_cascade_ch's echoes
            // are currently valid (it is -1 after finalize, so late echoes
            // arriving post-dump are dropped too).
            if (script_channel != qs_cascade_ch) return;
            // A valid 90021 arrived (channel-done, or a plugin echo): whatever
            // we were waiting on has answered, so disarm the wait. The probe
            // loop below re-arms it if it sends a fresh 90020.
            qs_cascade_pending = FALSE;
            // [QS]faces (>= 0.902) announces via QSDUMP_HELLO, so it lands
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
                // so a late stale echo from THIS channel is dropped, and stop
                // the watchdog timer (boot handed it back to AUTOSYNC here;
                // AUTOSYNC stayed in boot, so for us it just stops).
                qs_cascade_ch = -1;
                llSetTimerEvent(0);
                llMessageLinked(LINK_THIS, 90098, (string)(script_channel + 1), "");
            }
            else
            {
                // Dump complete - release the cascade watchdog before
                // finalizing.
                qs_cascade_ch = -1;
                llSetTimerEvent(0);
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
                            "[DUMP] Upload failed - link may be incomplete.");
                    }
                    else
                    {
                        llRegionSayTo(llGetOwner(), 0,
                            "[DUMP] Done - link finalized.");
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
            // is alive and working - push the timeout back so a slow, many-line
            // plugin is never falsely skipped. Only relevant during a plugin
            // probe (qs_cascade_pending); our own pose lines stream with the
            // watchdog idle.
            if (qs_cascade_pending) llSetTimerEvent(QS_CASCADE_TIMEOUT);
            // Format one dump line and Readout_Say it. Sources: our own
            // qs_dump_start/qs_dump_tick (V:/S:/{}) and plugin scripts
            // (announced via QSDUMP - [QS]prop, [QS]faces - plus the
            // hardcoded camera_script) that the 90021 cascade wakes via
            // 90020.
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
                    // The DUMP header a creator pastes back into AVpos.
                    // Display name, so it carries the 2; the QSALIVE wire
                    // token stays plain "QuickySitter".
                    Readout_Say("\"" + llToUpper(llGetObjectName()) + "\" " + qs_str_replace(llList2String(data, 0), "V:", "QuickySitter 2 "));
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
                    // VERBOSE is global (not per-channel) - read from
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

    // QS DUMP-endpoint failure detection. Loud dumps post to the
    // self-hosted endpoint too (since 1.25) but are deliberately NOT
    // flagged - the chat output is that path's primary deliverable, a
    // dead link degrades exactly like the stock avsitter.com behavior.
    // Quiet dumps go to url_qs (self-hosted) - if any chunk POST
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
