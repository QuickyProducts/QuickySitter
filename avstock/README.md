# avstock — vendored AVsitter2 sources

Verbatim copies of the AVsitter2 scripts and documentation that
QuickySitter does **not** fork. Forked counterparts live in
[`qs/`](../qs/) under their `[QS]…` names. This directory exists
so the repository contains everything needed to assemble a working
QuickySitter furniture without hunting for plugin scripts elsewhere, and
so the cross-references in `qs/PROTOCOL.md` and `qs/STORAGE.md`
resolve to a stable, version-pinned target.

## Provenance

| Source | Commit |
|--------|--------|
| https://github.com/AVsitter/AVsitter | `0040fbea18c0cd0705ad9b3446ccd380f5025a86` (master at vendoring time) |

Pulled from `AVsitter2/`; the `AVsitter2/` wrapper directory was dropped
so `avstock/` is parallel to `qs/`. No content edits — files are
byte-identical to upstream at the pinned SHA except for one local-link
adjustment in `avsitter2_link_message_reference.md` documented at the
top of that file (if any).

## What is here

```
avstock/
├── README.md                     ← this file
├── [AV]helperscript.lsl          ← script that lives inside the rezzed
│                                   helper-bar object (not in furniture)
├── [AV]root-security.lsl         ← RLV-capture / permission forwarder
├── BUILD_GUIDE.md                ← upstream build instructions
├── IMPORT_GUIDE.md               ← upstream import instructions
├── MARKETPLACE.txt               ← upstream marketplace listing template
├── Makefile                      ← upstream build pipeline (uses build-aux.py)
├── build-aux.py                  ← upstream build helper
├── avsitter2_link_message_reference.md  ← spec, target of qs/PROTOCOL.md
├── Plugins/
│   ├── AVcamera/[AV]camera.lsl
│   ├── AVcontrol/                ← RLV control + transport plugins
│   │   ├── [AV]root-RLV.lsl
│   │   ├── [AV]root-RLV-extra.lsl
│   │   ├── [AV]root-control.lsl
│   │   ├── LockGuard/, LockMeister/, Xcite!-Sensations/
│   ├── AVfaces/[AV]faces.lsl
│   ├── AVfavs/[AV]favs.lsl
│   ├── AVprop/                   ← prop rezz + menu + driven object
│   │   ├── [AV]prop.lsl
│   │   ├── [AV]menu.lsl
│   │   └── [AV]object.lsl
│   └── AVsequence/[AV]sequence.lsl
└── Utilities/                    ← creator-side helpers, not in furniture
    ├── AVpos-generator.lsl
    ├── AVpos-shifter.lsl
    ├── Anim-perm-checker.lsl
    ├── MLP-converter.lsl
    ├── Missing-anim-finder.lsl
    ├── Noob-detector.lsl
    └── Updater/
        ├── update-receiver.lsl
        └── update-sender.lsl
```

## What is **not** here

QuickySitter forks of these AVsitter scripts live in
[`qs/`](../qs/) under their `[QS]…` names — copying them here
verbatim would create stale duplicates. Run `diff` against the upstream
versions if you need to see what changed.

| `qs/[QS]…` | upstream `AVsitter2/[AV]…` |
|----------------|----------------------------|
| `[QS]adjuster.lsl` | `[AV]adjuster.lsl` |
| `[QS]root.lsl` | `[AV]root.lsl` |
| `[QS]select.lsl` | `[AV]select.lsl` |
| `[QS]sitA.lsl` | `[AV]sitA.lsl` |
| `[QS]sitB.lsl` | `[AV]sitB.lsl` |
| `[QS]prop.lsl` | `Plugins/AVprop/[AV]prop.lsl` |
| `[QS]menu.lsl` | `Plugins/AVprop/[AV]menu.lsl` |
| `[QS]faces.lsl` | `Plugins/AVfaces/[AV]faces.lsl` |
| `[QS]sequence.lsl` | `Plugins/AVsequence/[AV]sequence.lsl` |
| `[QS]root-RLV.lsl` | `Plugins/AVcontrol/[AV]root-RLV.lsl` |

`[QS]boot.lsl`, `[QS]debug.lsl`, and `[QS]offset.lsl` are
QuickySitter-only — no upstream counterpart.

## License & trademark

AVsitter is licensed under MPL 2.0, same as QuickySitter. The MPL allows
verbatim redistribution under the same license. Files here keep their
upstream copyright headers intact.

AVsitter™ is a trademark — see
https://avsitter.github.io/TRADEMARK.mediawiki for the policy. We
distribute these files **as-is, unmodified**, which the policy permits.
Forks (the `qs/[QS]…` files) follow QuickySitter's trademark posture
described in the root [`README.md`](../README.md).

## How to update / sync

Bump the pin to a newer upstream commit by re-vendoring:

```bash
# from the repo root
git clone --depth=1 https://github.com/AVsitter/AVsitter /tmp/avsitter
NEW_SHA=$(cd /tmp/avsitter && git rev-parse HEAD)

# Refresh files we vendor (keep the AVsitter2 wrapper out)
rm -rf avstock/Plugins avstock/Utilities
rm -f avstock/[AV]*.lsl avstock/*.md avstock/Makefile avstock/build-aux.py avstock/MARKETPLACE.txt

cp /tmp/avsitter/AVsitter2/'[AV]helperscript.lsl' avstock/
cp /tmp/avsitter/AVsitter2/'[AV]root-security.lsl' avstock/
cp /tmp/avsitter/AVsitter2/BUILD_GUIDE.md avstock/
cp /tmp/avsitter/AVsitter2/IMPORT_GUIDE.md avstock/
cp /tmp/avsitter/AVsitter2/MARKETPLACE.txt avstock/
cp /tmp/avsitter/AVsitter2/Makefile avstock/
cp /tmp/avsitter/AVsitter2/build-aux.py avstock/
cp /tmp/avsitter/AVsitter2/avsitter2_link_message_reference.md avstock/
cp -r /tmp/avsitter/AVsitter2/Plugins avstock/
cp -r /tmp/avsitter/AVsitter2/Utilities avstock/

# Re-add the README provenance line with $NEW_SHA, then commit:
# git add avstock && git commit -m "avstock: bump to AVsitter $NEW_SHA"
```

Then update the SHA in this file's "Provenance" table.

If a forked-into-`qs/` script changed upstream, **don't** copy the
new upstream version into `avstock/` — that would create an
inconsistency with our fork. Instead, review the diff and decide whether
to forward-port the change into the QuickySitter fork.
