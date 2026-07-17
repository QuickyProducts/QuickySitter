# QuickySitter DUMP receiver — `settings.php`

Self-hosted backend for the QuickySitter **[DUMP]** upload. Implements
the same w/c/t POST + ?q GET wire protocol as the upstream AVsitter
receiver but persists to flat files instead of MySQL — simpler deploy,
no DB dependency, drop-in compatible with the LSL side.

Serves **both** dump modes: the quiet QUICKYHUD path (web-only, since
`[QS]boot.lsl` ≥ 0.919) and — since `[QS]boot.lsl` ≥ 1.05 — the loud
`[HELPER] [DUMP]` path's "Settings copy" link too (the stock
`avsitter.com/settings.php` no longer works with QS output, issue #66).

## What it does

Accepts the `w=<webkey>&c=<chunkno>&t=<text>` POST chunks streamed by
`[QS]boot.lsl`'s `web()` flusher and appends them in order to a
per-webkey file under `$dump_dir`. On `?q=<webkey>` GET, serves the
assembled content. Entries are auto-deleted opportunistically on GET
after `$ttl_seconds` (default 600 = 10 min).

**Classic grouped output (issue #66):** boot streams pose lines and
their `{name}<pos><rot>` position lines interleaved (one LSD entry per
tick emits both back-to-back). The finished GET (`.done` present)
regroups each sitter block into the classic AVsitter DUMP layout —
pose/menu/plugin lines first, all position lines in one blank-line
separated block at the end — which is much easier to edit for large
AVpos notecards. Re-import is order-independent (both QS and stock
AVsitter match `{}` lines by name), so the transform is purely
cosmetic. Append `&raw=1` to get the byte-exact stream as uploaded
instead. Live-view (partial) responses always serve the raw stream.

**Live-view mode:** while the dump is still uploading (the `.done`
marker isn't there yet), GET responses include an HTTP `Refresh: 3`
header + a one-line progress notice + whatever chunks have arrived so
far. The browser auto-polls every 3 seconds and the owner watches the
AVpos content grow in near-real-time. Once the LSL cascade's final
chunk (carrying the `\n\nend` sentinel) lands and settings.php touches
the `.done` marker, subsequent GETs serve the final file without the
Refresh header — browser settles, no more auto-reload. Stall protection:
if the `.txt` file goes `$stall_seconds` without an update AND `.done`
still doesn't exist, the Refresh header is dropped and a stalled-upload
notice is surfaced so the browser doesn't poll a dead dump forever.

Protocol details and link-message context: see
[`qs/PROTOCOL.md` § 90098](../PROTOCOL.md).

## Storage layout

```
<dump_dir>/<webkey>.txt     chunks appended in order
<dump_dir>/<webkey>.done    empty marker, created when the final chunk
                            ends with the "\n\nend" sentinel from
                            boot's web(TRUE) flush. GET only serves
                            files that have this marker (avoids
                            serving partial uploads).
<dump_dir>/<webkey>.total   notecard line count at boot time, written
                            from the &n= POST parameter that boot
                            sends in quiet-mode chunks. Value is the
                            raw notecard line count (from
                            llGetNumberOfNotecardLines, fetched at
                            every state_entry into boot's in-RAM
                            `notecard_lines` regardless of seed /
                            skip-seed path). GET reads this file to
                            render "X lines uploaded — notecard had Y
                            lines at boot time" in the live-view
                            header (no percentage — adjuster-added
                            entries can grow dump output beyond the
                            original notecard size, which would
                            misleadingly inflate any computed
                            percentage). Loud-mode dumps don't send
                            &n, so the file is absent for those — GET
                            falls back to a count-only display.
```

No database, no schema migration, no credentials. Backup = `cp -r`.

## Hardcoded endpoint (LSL side)

`[QS]boot.lsl` globals `url` (loud [HELPER] path, since 1.05) and
`url_qs` (quiet QUICKYHUD path), currently the same value:

```lsl
string url    = "https://slquicky.com/quicky-sitter/dump/settings.php";
string url_qs = "https://slquicky.com/quicky-sitter/dump/settings.php";
```

Changing the deploy location means bumping those strings and re-uploading
boot. There is intentionally no notecard override — the URL is a
fork-level decision, not a per-creator one.

## Dependencies

| Dep | Notes |
|---|---|
| PHP | Tested on 7.4 + 8.x. Zero extensions beyond core (no `mysqli`, no `pdo`). |
| Webserver | Apache or nginx, anything that runs PHP. HTTPS required (SL rejects mixed-content + http downgrades). |
| Filesystem | Write permission for the PHP-FPM / Apache user on `$dump_dir`. |

## Deploy

1. **Upload** `settings.php` + `settings-config.inc.php` to the path
   matched by `url_qs` (currently `/quicky-sitter/dump/`). Optionally
   ship the `dumps/` subdir with its `.htaccess` — settings.php
   creates the dir automatically on first request if missing.

2. **Set write permissions** on `dumps/` for the PHP user, e.g.:
   ```sh
   mkdir -p /var/www/quicky-sitter/dump/dumps
   chown www-data:www-data /var/www/quicky-sitter/dump/dumps
   chmod 750 /var/www/quicky-sitter/dump/dumps
   ```
   Or just let settings.php auto-create on first POST (it uses 0750).

3. **Edit** `settings-config.inc.php` if defaults don't fit:
   - `$dump_dir` — where to persist (default: `<script-dir>/dumps`).
     Move outside webroot for hardening if your hosting allows.
   - `$ttl_seconds` — retention window (default: 600s = 10 min).
   - `$refresh_seconds` — browser auto-refresh cadence during live-view
     (default: 3s).
   - `$stall_seconds` — how long without a chunk before settings.php
     declares the upload abandoned and drops the Refresh header
     (default: 30s).
   - `$check_owner_key` — SL header validation (default: `false` for
     testuser phase; flip to `true` once you're past initial testing).

4. **For nginx:** the shipped `dumps/.htaccess` only works on Apache.
   Nginx users add this to the server block:
   ```nginx
   location ~ /quicky-sitter/dump/dumps/ {
       deny all;
   }
   ```

5. **Test** inworld:
   - Rezz furniture with `[QS]boot.lsl` ≥ 0.919.
   - `[QUICKYHUD]` → `[DUMP]`.
   - Expected chat (owner-only): start-hint + URL.
   - Open URL in browser, confirm AVpos paste content shows.

## Failure mode

If the server returns non-200 on any chunk during a quiet dump,
`[QS]boot.lsl`'s `http_response` handler flips `dump_failed = TRUE`
and the end-of-cascade URL shout is replaced by:

```
[DUMP] Upload failed — link may be incomplete.
```

The owner can retry via `[HELPER]` `[DUMP]` (loud path — same endpoint
since boot 1.05, but the full ◆ chat output serves as the fallback
deliverable there, so a dead link never blocks the workflow).

## Extensibility — not implemented but easy to add

The MySQL upstream had a few features the flat-file rewrite dropped
for simplicity. None are needed for single-creator testuser use; here's
what to add if scope grows:

| Feature | Upstream did | Add by |
|---|---|---|
| Chunk-count validation (reject out-of-order) | `$row['count']+1 == $given_count` check | Persist last count in `<webkey>.cnt` sidecar, compare on POST. |
| Multi-tenant isolation | `owner_uuid` column | Subdirectory per owner: `<dump_dir>/<owner_uuid>/<webkey>.txt`. Validate owner header (`$check_owner_key = true`) to populate it. |
| Owner-name logging | `owner_name` column | Separate `access.log` write next to file create. |
| 64KB notecard-size warning | `strlen($newtext) > 65535` check | One `filesize()` check on POST, write a warning to the file if exceeded. |
| Auto-keep-on-access | `keep = 1` flag | Sidecar `<webkey>.keep` marker, skip in cleanup. |
| Shared-secret auth | not in upstream | Header check (`X-QS-Secret`) on POST, secret in config. Better than `$check_owner_key` for real protection. |
| Per-creator quotas / rate limit | not in upstream | Cron-driven aggregate + 429 response. |

## Security notes

- **Webkey validation is strict** — only UUID-shaped strings pass the
  regex (`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`).
  The webkey goes directly into a filename, so anything looser would
  be a path-traversal hole.
- **`$check_owner_key` is defense-in-depth, not auth.** SL fills
  `X-SecondLife-Owner-Key` server-side for `llHTTPRequest`, so toggling
  it on blocks naive curl-from-outside submissions — but a determined
  attacker can forge the header from any HTTP client. For real auth,
  the right move is a fork-level shared secret (see Extensibility
  table).
- **`dumps/` must not be directly browsable.** The shipped `.htaccess`
  handles Apache. Nginx needs an explicit deny rule (see Deploy step
  4). If you keep `$dump_dir` outside the webroot entirely, neither is
  needed.
- **No rate limiting.** A misconfigured furniture or a hostile client
  could fill the disk. Hardening idea: cap total `dumps/` size in a
  cron job and reject new POSTs once over a threshold.
