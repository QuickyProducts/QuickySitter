<?php

// QuickySitter settings.php deploy config — flat-file edition.
// Edit on the deployment server with values that fit your hosting.

// Where to persist dump chunks. Must be writable by the PHP-FPM /
// Apache user. Recommended: a path OUTSIDE the webroot (so the raw
// .txt files can't be accessed directly via URL). If you keep it
// inside the webroot, the shipped dumps/.htaccess (sitting next to
// this config) blocks direct access on Apache; on nginx, add an
// explicit `location ~ /dumps/` deny rule yourself.
$dump_dir = __DIR__ . '/dumps';

// How long (seconds) a dump survives after last write before
// opportunistic cleanup unlinks it. Matches upstream AVsitter's
// 10-minute default. Cleanup runs on every GET, so a stale file
// can linger past TTL if nothing else hits the endpoint — that's
// fine, it just means a slightly later cron-or-traffic-driven sweep.
$ttl_seconds = 600;

// Browser auto-refresh cadence for live-view GETs (HTTP Refresh
// header). 3 seconds is short enough that the user sees content
// grow in near-real-time but long enough that a tight loop doesn't
// hammer the server. Only applied while the dump is still uploading
// (.done marker absent); the final file is served without Refresh
// so the browser settles.
$refresh_seconds = 3;

// How long (seconds) the .txt file can stay untouched WITHOUT the
// .done marker before settings.php declares the upload stalled and
// stops auto-refreshing the client. Realistic dumps complete in a
// few seconds; 30s is generous enough to absorb a laggy region or
// throttled HTTP without false-positiving.
$stall_seconds = 30;

// Require SL's X-SecondLife-Owner-Key header on POST. SL fills this
// server-side for llHTTPRequest calls, so enabling it blocks naive
// curl-from-outside-SL submissions. Forgeable by a determined attacker
// (custom HTTP client setting the header), so it's defense-in-depth
// rather than authentication. Leave FALSE for testing; flip TRUE once
// you're past testuser phase. Future: replace with a fork-level shared
// secret check for real auth.
$check_owner_key = false;
