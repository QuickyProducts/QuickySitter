# qs/examples — third-party plugin references

Small, copy-pasteable LSL scripts that demonstrate the public
extension points of the fork. These are **not** shipped inside
furniture by default — they're starting points for plugin authors.

| Example | Demonstrates | Spec |
|---------|--------------|------|
| [`[QS]plugin-example.lsl`](./%5BQS%5Dplugin-example.lsl) | Registering an `[OPTIONS]` menu button via `QSPLUG_REGISTER` (90212) — plug-and-play button, click dispatch, paging, dedupe, re-announce. | [PROTOCOL.md § QSPLUG_REGISTER](../PROTOCOL.md) |

## How to try

1. Drop one of the example scripts into any QuickySitter furniture
   prim (root or child). The script's state_entry registers it; the
   furniture's pose menu now shows `[OPTIONS]` if it wasn't already
   showing it.
2. Click `[OPTIONS]`, then your plugin's button — the click handler
   in the example shouts a confirmation back to you via
   `llRegionSayTo`.
3. To stress-test paging: drag the script multiple times into the
   prim and rename each copy (e.g. `[QS]plugin-example alpha`,
   `[QS]plugin-example beta`, …). Dedupe is by `llGetScriptName`, so
   renamed copies coexist. With ≥ 10 copies the dialog gets
   `[<<]`/`[>>]` paging buttons.

## What these are *not*

- **Not** part of the production fork's runtime. The QuickySitter
  product furniture doesn't ship any of these.
- **Not** stable APIs guarded by SemVer. They mirror what
  [PROTOCOL.md](../PROTOCOL.md) calls "v1" — payload formats may
  evolve in v2 (e.g. an active staleness probe).
- **Not** code review for shipping plugins. They're terse on purpose
  to keep the spec readable; production plugins will want better
  diagnostics, settings persistence, etc.

For full reference docs see [QuickySitter-docs](https://quickyproducts.github.io/QuickySitter-docs/options-menu-plugins.html).
