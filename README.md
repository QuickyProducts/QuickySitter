# QuickySitter™

QuickySitter™ is a fork of **AVsitter™ 2** — a furniture pose system for Second Life® written in LSL.

## Goals

- **Eliminate heap pressure.** Script memory has been restructured onto LinkSet Data (LSD), moving large state out of the per-script heap so complex furniture stays stable on busy regions.
- **Full API compatibility with AV stock.** Existing AVsitter 2 notecards, MENU/POSE/PROP syntax, and LinkMsg contracts continue to work — QuickySitter is intended as a drop-in replacement.
- **Simpler HUD-driven position control.** The API has been extended so that sit-target adjustment can be driven cleanly from a HUD, not only from the on-prim helper bar.
- **Built-in Re-Sync via API.** A re-sync function is exposed through the LinkMsg API so HUDs and external tools can re-align state at any time, without re-rezzing the object or detaching the HUD.
- **QuickyHUD integration.** QuickyHUD is supported as a first-class adjustment option alongside the classic AVsitter helper bar.
- **Workload distribution across scripts.** Responsibilities have been split across more focused scripts so no single script carries the full heap pressure.
- **Plugin-friendly module discovery.** Optional fork modules announce themselves over a presence protocol (LinkMsg 90096 / 90097) instead of being looked up by script name. This means script names can be renamed without breaking the system, and third-party plugins keep working across releases.

## Editing & Optimization

You can edit any scripts, as long as you stay in compliance with the license (see below); however, in order to benefit from the extra memory that the SL Marketplace version provides, you're advised to optimize the scripts following the same method used for packaging the releases.

For increased script memory, scripts can be run through LSL-PyOptimizer. If you do this, please keep the license notification intact in the header of any scripts you distribute.

## License

QuickySitter LSL scripts are licensed under the Mozilla Public License Version 2.0.

This basically means that you must make the source code for any of your changes available under MPL, but you can combine the MPL code with proprietary code, as long as you keep the MPL code in separate files.

## Trademarks and branding

If you distribute the scripts in this repository or a derivation, you may only use the upstream brand as permitted. See the AVsitter Trademark Guidelines for permitted use of the AVsitter™ brand. We also suggest http://fossmarks.org for a practical guide to understanding trademarks in the context of Free and Open Source Software.

Second Life® is a trademark of Linden Research, Inc. QuickySitter™ is not affiliated with or sponsored by Linden Research or the AVsitter™ project.
