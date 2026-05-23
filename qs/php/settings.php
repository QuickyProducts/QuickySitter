<?php

/*
 * QuickySitter DUMP receiver — flat-file edition
 *
 * Self-hosted backend for [QS]boot.lsl ≥ 0.919's QUICKYHUD-path quiet
 * DUMP. Speaks the same w/c/t POST + ?q GET wire protocol as the
 * upstream AVsitter settings.php but persists to flat files instead of
 * MySQL — simpler deploy, no DB dependency, drop-in compatible with
 * the LSL side.
 *
 * Storage layout:
 *   <dump_dir>/<webkey>.txt   — chunks appended in order
 *   <dump_dir>/<webkey>.done  — empty marker, exists once the LSL
 *                               cascade emitted its final "\n\nend"
 *                               sentinel. GET only serves files that
 *                               have this marker, mirroring upstream's
 *                               count > 10000 completion gate.
 *
 * TTL: opportunistic — every GET runs a glob/unlink pass over files
 * older than $ttl_seconds. No cron job required for single-tenant use.
 *
 * Licensed under MPL 2.0 (matches the QuickySitter LSL side). The wire
 * protocol it implements originates with upstream AVsitter
 * (MIT, https://github.com/AVsitter/AVsitter/tree/master/php) — we only
 * replaced the storage layer.
 */

require_once __DIR__ . '/settings-config.inc.php';

header("Content-Type: text/plain; charset=utf-8");
error_reporting(E_ERROR | E_WARNING | E_PARSE);
ini_set('display_errors', '0');

// ----------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------

function is_valid_webkey($key) {
    // Strict UUID format. Blocks path-traversal attempts in the
    // filename construction below — webkey goes directly into a
    // file path, so anything looser than this is a security hole.
    return is_string($key)
        && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i', $key) === 1;
}

function paths_for($webkey) {
    global $dump_dir;
    return [
        'data'  => "$dump_dir/$webkey.txt",
        'done'  => "$dump_dir/$webkey.done",
        'total' => "$dump_dir/$webkey.total",
    ];
}

function cleanup_expired() {
    global $dump_dir, $ttl_seconds;
    $cutoff = time() - $ttl_seconds;
    foreach (glob("$dump_dir/*.txt") as $f) {
        if (@filemtime($f) < $cutoff) {
            $base = preg_replace('/\.txt$/', '', $f);
            @unlink($f);
            @unlink("$base.done");
            @unlink("$base.total");
        }
    }
}

function http_400($msg) {
    header('HTTP/1.0 400 Bad Request');
    die($msg);
}

// ----------------------------------------------------------------------
// Directory bootstrap (create on first request if missing)
// ----------------------------------------------------------------------

if (!is_dir($dump_dir)) {
    if (!@mkdir($dump_dir, 0750, true)) {
        http_400("dump_dir not writable: $dump_dir");
    }
}

// ----------------------------------------------------------------------
// Route: POST chunk  (w=<webkey>&c=<chunkno>&t=<text>)
// ----------------------------------------------------------------------

if (isset($_REQUEST['w'])) {
    $webkey = $_REQUEST['w'];
    if (!is_valid_webkey($webkey)) {
        echo "INVALID WEBKEY";
        exit;
    }

    if ($check_owner_key) {
        $owner_key = isset($_SERVER['HTTP_X_SECONDLIFE_OWNER_KEY'])
            ? $_SERVER['HTTP_X_SECONDLIFE_OWNER_KEY'] : '';
        if (!is_valid_webkey($owner_key)) {
            // Same UUID shape as webkey. SL sets this header server-side
            // on llHTTPRequest, so a missing/malformed value means the
            // request didn't come from SL (or someone is poking the
            // endpoint directly).
            echo "INVALID USER";
            exit;
        }
    }

    $text  = isset($_REQUEST['t']) ? $_REQUEST['t'] : '';
    $paths = paths_for($webkey);

    // Append chunk under exclusive lock. file_put_contents with
    // FILE_APPEND|LOCK_EX is atomic vs other PHP processes writing the
    // same file. If two LSL chunks for the same webkey land at the
    // same time (rare — boot streams them in sequence), they queue
    // cleanly without interleaving.
    $ok = @file_put_contents($paths['data'], $text, FILE_APPEND | LOCK_EX);
    if ($ok === false) {
        http_400("write failed");
    }

    // Total-entries marker for the GET-side progress display. Boot
    // sends &n=<total> on every chunk (quiet mode only), value is
    // constant across the cascade. Writing it idempotently means the
    // first chunk to land creates the marker and subsequent writes
    // are no-ops with the same content.
    if (isset($_REQUEST['n'])) {
        $total = intval($_REQUEST['n']);
        if ($total > 0 && !file_exists($paths['total'])) {
            @file_put_contents($paths['total'], (string)$total);
        }
    }

    // Final-chunk sentinel: boot's web(TRUE) appends "\n\nend" to the
    // cache right before the last POST. The marker file flips GET into
    // serve-mode.
    if (substr($text, -5) === "\n\nend") {
        @touch($paths['done']);
        echo "FINISHING";
    } else {
        echo "ADDING";
    }
    exit;
}

// ----------------------------------------------------------------------
// Route: GET assembled  (?q=<webkey>)
//
// Live-view mode: when the LSL cascade is still uploading chunks, the
// .done marker is absent. We serve whatever has arrived so far PLUS an
// HTTP Refresh header so the browser polls every $refresh_seconds and
// the user watches the AVpos content grow in real time. Once the
// final chunk's "\n\nend" sentinel lands and settings.php touches the
// .done marker, subsequent GETs serve the final file without the
// Refresh header — browser settles, no more auto-reload.
//
// Stall protection: if the .txt file hasn't been touched in
// $stall_seconds AND .done still doesn't exist, the upload looks
// abandoned. Drop the Refresh header so we don't loop the browser
// forever and surface a one-line "stalled" notice above whatever
// partial content made it through.
// ----------------------------------------------------------------------

if (isset($_REQUEST['q'])) {
    $webkey = $_REQUEST['q'];
    if (!is_valid_webkey($webkey)) {
        echo "INVALID WEBKEY";
        exit;
    }

    // Opportunistic cleanup runs on every GET. Cheap at the scale we
    // expect (a few files); add a cron job if traffic grows enough
    // that this becomes a hot path.
    cleanup_expired();

    $paths = paths_for($webkey);

    if (!file_exists($paths['data'])) {
        // No chunks have landed yet — could be a freshly-clicked URL
        // where the first POST is still in flight, or an unknown
        // webkey. Refresh once so the freshly-clicked case lights up
        // automatically on the next tick; if it's actually unknown,
        // the user can close the tab.
        header("Refresh: $refresh_seconds");
        echo "Upload not yet started — auto-refreshing every "
           . $refresh_seconds . "s.\n"
           . "If this persists, the link may be expired or the dump "
           . "never started.";
        exit;
    }

    if (file_exists($paths['done'])) {
        // Cascade complete. Final file, no Refresh — browser settles.
        readfile($paths['data']);
        exit;
    }

    // In-progress — partial content + auto-refresh.
    $silence = time() - @filemtime($paths['data']);

    // Count newlines in the partial file = lines streamed so far.
    // boot also sent &n=<lines> (raw notecard line count from
    // llGetNumberOfNotecardLines) so we can mention the notecard size
    // for context. We deliberately do NOT compute a percentage from
    // these — boot's adjuster ([NEW]/[SAVE] writing to qs:p:<ch>:<i>
    // LSD entries) can grow the dump output beyond the original
    // notecard line count, which would either inflate past 100% or
    // require dishonest clamping. Showing both numbers as plain facts
    // lets the owner see what's happening without misleading math.
    $lines_so_far = substr_count(
        file_get_contents($paths['data']), "\n");

    $total = file_exists($paths['total'])
        ? intval(file_get_contents($paths['total']))
        : 0;

    if ($total > 0) {
        $progress = "$lines_so_far lines uploaded — "
                  . "notecard had $total lines at boot time";
    } else {
        $progress = "$lines_so_far lines uploaded";
    }

    if ($silence > $stall_seconds) {
        // Upload looks abandoned. Surface the partial content but
        // stop the refresh loop so the browser doesn't poll forever.
        echo "[DUMP appears stalled — $progress; no new chunks in "
           . $silence . " seconds. Refresh manually if you think "
           . "more is coming.]\n\n";
        readfile($paths['data']);
        exit;
    }

    header("Refresh: $refresh_seconds");
    echo "[DUMP in progress (auto-refresh "
       . $refresh_seconds . "s) — $progress]\n\n";
    readfile($paths['data']);
    exit;
}

// ----------------------------------------------------------------------
// No valid action
// ----------------------------------------------------------------------

http_400("400 Bad Request: No valid action specified.");
