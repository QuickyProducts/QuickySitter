# QuickySitter™

QuickySitter™ is a fork of **AVsitter™ 2** — a furniture pose system for Second Life® written in LSL. Full documentation: [QuickySitter-docs](https://quickyproducts.github.io/QuickySitter-docs/).

## Goals

- **Eliminate heap pressure.** Script memory has been restructured onto LinkSet Data (LSD), moving large state out of the per-script heap so complex furniture stays stable. Stock AVsitter typically caps out around 200 poses per sitter script before Mono's 64 KiB heap limit stops it; QuickySitter's pose data no longer lives there, so that ceiling is gone and the remaining limits are the ones SL imposes on the furniture as a whole (see below). No post-processing required.
- **Full API compatibility with AV stock.** Existing AVsitter 2 notecards, MENU/POSE/PROP syntax, and LinkMsg contracts continue to work.
- **Plug-and-play HUD addons.** Adding HUD addons is straightforward through the extended LinkMsg API — QuickyHUD attaches as a seamless adjustment addon alongside the built-in adjust menu and can be removed again at any time without side effects.
- **Animation SYNC via API.** The LinkMsg API exposes a SYNC trigger so HUDs and external tools can restart all currently playing animations in lockstep on demand — useful for couple poses that drift apart over time.
- **Workload distribution across scripts.** Responsibilities have been split across more focused scripts so no single script carries the full heap pressure.
- **Module discovery without script-name probes.** Optional fork modules announce themselves over a presence protocol (LinkMsg 90096 / 90097) instead of being detected by inventory script-name lookup. Scripts can be renamed freely, and third-party plugins keep working across releases.

## Capacity

Three separate limits, none of them per sitter slot, and only the second one has anything to do with the heap:

- **The `AVpos` notecard: 65 536 bytes.** An SL notecard asset cannot be larger, and that one file holds the poses for the whole piece, not per seat. At roughly 80 – 120 bytes for a pose entry with POS/ROT and a long animation name, that is somewhere around **550 entries** for the furniture. Note the viewer's built-in editor truncates on save well below the asset limit, at about 49 KB, so edit large notecards externally and paste them back in one go.
- **Linkset Data: 128 KiB per linkset.** Pose rows, prop records, personal offsets and the HUD's config share this one pool, again for the whole piece. This is the budget the LSD-backed architecture spends instead of the per-script heap, and `RESERVE` in `hudconfig` sets aside part of it for your own scripts.
- **100 props.** A hard ceiling from the stock wire format, where the prop index travels in `start_param` and runs 0 – 99. Memory has nothing to do with it, and it cannot be raised.

Both byte budgets are documented with their sources on the [Known limits](https://quickyproducts.github.io/QuickySitter-docs/known-limits.html) page.


## Editing & Optimization

You can edit any scripts, as long as you stay in compliance with the license (see below).

The shipped source compiles directly under SL's Mono compiler, no post-processing required, and the capacities above hold at that level: they come from the LSD-backed state architecture rather than from optimization. Release packages ship un-optimized.

If you want to push further (significantly larger pose libraries, deeper nested ADJUST states, more concurrent runtime state), you can run the scripts through [LSL-PyOptimizer](https://github.com/Sei-Lisa/LSL-PyOptimizer) before upload. Expect another 10-25% heap headroom via constant folding, dead-code elimination, function inlining, and symbol shortening. This is opt-in — we don't do it as default. If you redistribute optimized scripts, keep the license notification intact in the header.

## License

QuickySitter LSL scripts are licensed under the Mozilla Public License Version 2.0.

This basically means that you must make the source code for any of your changes available under MPL, but you can combine the MPL code with proprietary code, as long as you keep the MPL code in separate files.

## Trademarks and branding

If you distribute the scripts in this repository or a derivation, you may only use the upstream brand as permitted. See the AVsitter Trademark Guidelines for permitted use of the AVsitter™ brand. We also suggest http://fossmarks.org for a practical guide to understanding trademarks in the context of Free and Open Source Software.

Second Life® is a trademark of Linden Research, Inc. QuickySitter™ is not affiliated with or sponsored by Linden Research or the AVsitter™ project.
