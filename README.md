# QuickySitter™

QuickySitter™ is a fork of **AVsitter™ 2** — a furniture pose system for Second Life® written in LSL.

## Goals

- **Eliminate heap pressure.** Script memory has been restructured onto LinkSet Data (LSD), moving large state out of the per-script heap so complex furniture stays stable. Current capacity per furniture: up to ~550 poses per sitter slot and 100 props, with no post-processing required (stock AVsitter typically caps out around ~200 poses per slot before hitting Mono's 64 KB heap limit). The 550-pose capacity is the stable baseline of the shipped source — release packages are not pre-optimized.
- **Full API compatibility with AV stock.** Existing AVsitter 2 notecards, MENU/POSE/PROP syntax, and LinkMsg contracts continue to work.
- **Plug-and-play HUD addons.** Adding HUD addons is straightforward through the extended LinkMsg API — QuickyHUD attaches as a seamless adjustment addon alongside the built-in adjust menu and can be removed again at any time without side effects.
- **Animation SYNC via API.** The LinkMsg API exposes a SYNC trigger so HUDs and external tools can restart all currently playing animations in lockstep on demand — useful for couple poses that drift apart over time.
- **Workload distribution across scripts.** Responsibilities have been split across more focused scripts so no single script carries the full heap pressure.
- **Module discovery without script-name probes.** Optional fork modules announce themselves over a presence protocol (LinkMsg 90096 / 90097) instead of being detected by inventory script-name lookup. Scripts can be renamed freely, and third-party plugins keep working across releases.

## Editing & Optimization

You can edit any scripts, as long as you stay in compliance with the license (see below).

The shipped source compiles directly under SL's Mono compiler — no post-processing required. The ~550-pose/slot, ~100-prop capacity above is the stable baseline at that level; the heap headroom comes from the LSD-backed state architecture, not from optimization. Release packages ship un-optimized.

If you want to push further (significantly larger pose libraries, deeper nested ADJUST states, more concurrent runtime state), you can run the scripts through [LSL-PyOptimizer](https://github.com/Sei-Lisa/LSL-PyOptimizer) before upload. Expect another 10-25% heap headroom via constant folding, dead-code elimination, function inlining, and symbol shortening. This is opt-in — we don't do it as default. If you redistribute optimized scripts, keep the license notification intact in the header.

## License

QuickySitter LSL scripts are licensed under the Mozilla Public License Version 2.0.

This basically means that you must make the source code for any of your changes available under MPL, but you can combine the MPL code with proprietary code, as long as you keep the MPL code in separate files.

## Trademarks and branding

If you distribute the scripts in this repository or a derivation, you may only use the upstream brand as permitted. See the AVsitter Trademark Guidelines for permitted use of the AVsitter™ brand. We also suggest http://fossmarks.org for a practical guide to understanding trademarks in the context of Free and Open Source Software.

Second Life® is a trademark of Linden Research, Inc. QuickySitter™ is not affiliated with or sponsored by Linden Research or the AVsitter™ project.
