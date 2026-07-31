# CardRunner — Competitive Review & Roadmap

*Authored 2026-07-29. Sources: parallel research team (Hedge Offshoot deep-dive, Parashoot/Ottomatic safe-erase analysis, internal CardRunner v1.8.1 audit). This is a living strategy doc — sits alongside HANDOFF.md / PERF_REVIEW.md / UI-future.md.*

---

## 0. The one-line verdict

CardRunner's **failure-safety and durability engineering is already at or above Offshoot's level.** Its **verification *proof* and *portability* are below the professional bar.** Close that one gap and CardRunner is not a hobby offloader — it's the trust core for a whole suite (CardRunner → Fetch → FolderSync).

**The keystone:** upgrade verification from "≤10-file MD5 spot-check behind an opaque ✓ VERIFIED badge" to "full-file hashing + a portable MHL seal + an honest, tiered badge." Everything downstream — the safe-eraser, the competitive story, the suite's shared trust language — rests on this.

---

## 1. Where CardRunner already WINS (protect & market these)

| Strength | Detail | vs Offshoot |
|---|---|---|
| **Honest completion semantics** | `fsync` + one `F_FULLFSYNC` per job forces physical device write-back before "done." Verify runs *before* "safe to pull." Card stays mounted on any failure. | **We beat Hedge here.** Offshoot's own documented weakness (Newsshooter/Filmdrives teardown): its on-screen "done" tick can precede the background destination read-back — eject too early and verification never finished. When CardRunner says *safe to pull*, the read-back is already done. |
| **Structural "never lie about success"** | Single `evaluateIngestOutcome` gate, unit-tested. UI literally cannot render "all done" while any failure record exists. Persistent "DO NOT FORMAT" survives restarts, cleared only on strict same-card-identity match. | Equal or better. This is enforced by construction, not convention. |
| **Per-card media auto-detection** | Photo vs video inferred per card from actual file contents; mixed-card parallel offload just works. | Offshoot uses global organize presets + include/exclude filters — no per-card content inference. Genuine differentiator. |
| **Drive-tier-aware scheduling** | `diskutil`-probed fast/medium/slow classification decides same-drive parallel vs sequential, 3s timeout so a hung NAS can't stall. | Offshoot's Queuing modes are manual (Off/Single Source/Single Dest/Single Transfer). Ours is *automatic and hardware-aware*. |
| **Wrong-clock / bogus-date detection** | Detects dead-RTC cameras dumping footage to 1970/2011 folders, offers a reel picker instead of blind mtime trust. | Not addressed by most competitors at all. |
| **The ring / v3 visual identity** | Differentiated visual language, not a generic progress bar. | Offshoot is utilitarian. This is a brand asset. |

**Marketing takeaway we can make honestly:** *"When CardRunner says safe to pull, it means it — the verify is already finished, not running in the background."* That's a direct, sourced jab at the category leader's biggest technical criticism.

---

## 2. Where CardRunner LOSES (ranked gaps)

| # | Gap | Reality today | Offshoot | Severity |
|---|---|---|---|---|
| **1** | **No MHL / hash-manifest sidecar** | Zero MHL support anywhere in the code. | ASC MHL (Pro): reused on read, auto re-verified on write, portable chain-of-custody. | **Critical** — this is the #1 thing a DIT benchmark surfaces. It's what makes verification *portable and provable* across tools. |
| **2** | **Default "VERIFIED" = ≤10-file MD5 spot-check** | `verifyTransfer` default samples up to 10 random files, MD5. Full SHA-256 exists in `cardcopy.c` but is opt-in and gated off. Badge doesn't distinguish spot-check from full. | Three explicitly-named tiers (Transfer / Source / Source&Dest), xxHash default. | **Critical** — "VERIFIED" reads as "every file confirmed" but usually isn't. Honesty + credibility issue. |
| **3** | **No safe-erase** | Never formats cards (a *safety* win today), but also no verified-erase workflow. | Parashoot integration hands off eject after verified transfer. | **High** — this is the requested wedge feature. |
| **4** | **No cloud destination** | No S3/Dropbox/iCloud. NAS is "just a folder" (no reconnect logic, diskutil mis-tiers network mounts). | S3 (Pro, clunky but present). | **Medium** — matters for the suite (Fetch is Dropbox-native). |
| **5** | **No metadata/MAM layer** | Opt-in CSV report only. No clip thumbnails, no camera-metadata extraction, no JSON handoff. | Elements system → filenames/folders/logs/MHL + iconik/Frame.io/Scratch. | **Medium** — depends whether we want MAM-adjacent or stay lean. |
| **6** | **No cascading / source-release decoupling** | Source freed only when primary + all mirrors done. | Cascading releases source once fastest destination is done. | **Low/Med** — nice on-set time-saver. |
| **7** | **Perf debt** | Card scanned 2–6× via redundant `find` passes before copy; progress events can storm the main thread on high-file-count cards; O(n²) collision table. (Per PERF_REVIEW.md, unremediated.) | Fast Lane engine. | **Medium** — invisible until someone offloads a 2,000-photo card. |

---

## 3. The verification truth (the pivotal section)

Our audit found the nuance that matters most:

- **`cardcopy.c` already has real, re-read SHA-256** (both sides read from disk, `F_NOCACHE`) — but it's `--no-verify` by default and only fires on full-verify.
- **The default path is `verify_transfer()` in the shell: MD5, ≤10 random files.**
- **The ✓ VERIFIED badge** asserts "verify was enabled at launch + ≥1 new file + no VERIFY_FAIL" — with defaults, that's *at most 10 sampled files matched MD5*. Honest in code comments; **not** honest in the badge UI.

**DECIDED (2026-07-29) — MHL-first, keep spot-check default:**

1. **MHL generation — ship first.** Emit an **ASC MHL** sidecar per card/job (the XML standard Hedge/ShotPut/YoYotta all read). This is the single highest-leverage credibility feature we can ship, and it's the centerpiece of the next release. Reuse existing MHLs on the source when present (Offshoot's speed trick). *Note:* the MHL must record hashes for **every** file — so when full-verify is off, MHL generation still needs a full-file hash pass to populate it. Resolve this by hashing during copy (the `cardcopy.c` SHA-256 path already reads both sides) and writing those into the MHL, rather than forcing a second read.
2. **Keep spot-check as the DEFAULT verify.** No transfer-speed regression. Full-file verify stays opt-in for now. xxHash-as-default is **deferred** — revisit once MHL is shipping and we've measured the real cost of a full-file hash pass on field hardware.
3. **Honest tiered badge — ship first (quick win).** Replace one opaque "✓ VERIFIED" with a clear tier: **Size-checked / Spot-verified (N files) / Fully verified (every file) / Sealed (MHL)**. Never let decoration overstate the guarantee — consistent with the "UI cannot lie" ethos already in the code.

This is the foundation. MHL + honest badge close gaps #1 and #2's credibility problem now; the full-file-default decision and the safe-erase gate build on top later.

---

## 4. Safe-Erase — the strategic wedge ("Parashoot, but honest")

> **STATUS (2026-07-29): PARKED — documented here, not scheduled.** Safe-erase is only as trustworthy as the verification gate it stands on, and that gate (full-file checksum + MHL reconciliation) doesn't fully exist yet. Revisit *after* the verification core lands. The full design below is preserved so it's build-ready when we pick it up. When we do, the open scope call is: reversible fake-format vs. green-light-only (no card writes) for v1.

Parashoot's own docs admit: **"No checksums are verified though!"** — it matches by filename + byte-size only. A competitor (Stow) is already attacking them on exactly this. **We can beat the reference product on its one acknowledged flaw**, because we already hash during copy.

**Keep Parashoot's two genuinely brilliant ideas:**
- **Reversible "fake format"** — flip ~2MiB of the partition table so the card reads as unformatted (camera prompts to format) but *nothing is deleted* → fully restorable until a real in-camera format. The dangerous action stays non-destructive until a much later, deliberate step.
- **Camera-as-final-gate** — the card *looking* unformatted makes the camera an independent second confirmation the crew already trusts.

**Beat them on the gate:**
- **Checksum-level proof, not name/size** — every file matched by hash against every destination counted toward the gate.
- **Configurable N-of-M destination policy** with a **Required** flag (e.g. the offsite copy must always match).
- **Byte-count + file-count reconciliation** to catch truncated/partial copies.
- **MHL as source-of-truth** for "what should exist" (also handles previously-offloaded cards correctly).
- **Never do a real/full format ourselves** — only the reversible mark; the actual format happens in-camera. Say so explicitly in the UI.
- **Status-first UX** — the Erase affordance simply isn't enabled until the gate is met (no dismissible "are you sure?" under set pressure).
- **Two distinct modes** (steal this from Ottomatic): **Prep Mode** (fresh incoming cards, skip checks) vs **Safe-Erase** (verify then reversible-wipe). Don't make one button guess intent.

**Edge cases that must fail *closed*:** partial copy in progress → not safe; one-destination-only → hard warn (3-2-1 violation), never silently pass; mixed already-offloaded + new footage → file-by-file diff ("142 previously verified, 18 new, all 18 verified against 3 destinations"); RED/ARRI/Sony packages verified at whole-clip level; offline destination → "unverified," never skipped.

**Name candidates:** the Parashoot metaphor is "parachute." Ours could be **Clear**, **Release**, or **Wipe** — leaning "Release" (card released for reuse). TBD with you.

---

## 5. The suite thesis (CardRunner → Fetch → FolderSync)

The three apps are **three faces of one engine: verified file movement with a trust guarantee.**

- **CardRunner** — card → drive (offload)
- **Fetch** — Dropbox → drive (download)
- **FolderSync** — folder ↔ folder (sync/mirror)

The moat is **not** any single app — it's a **shared, bulletproof copy-and-verify core** plus **one consistent "did it actually make it?" trust language** across all three. The same verification engine that proves footage is safe to erase in CardRunner powers Fetch's "download complete & intact" and FolderSync's "both sides match, byte-for-byte."

**Implication for sequencing:** build the verification + MHL core *once*, as a shared primitive, inside CardRunner first (it's the most mature). Then Fetch and FolderSync inherit it instead of each reinventing trust. Perfecting CardRunner's verification is literally the act of building the suite's foundation.

---

## 6. Phased roadmap

**Phase 1 — Verification Core (the keystone).** *Unlocks everything. THIS IS NEXT.*
- **ASC MHL sidecar generation** (+ reuse existing source MHLs) — the release centerpiece.
- **Honest tiered verification badge** (Size / Spot / Full / Sealed) — quick win, ship alongside.
- Keep spot-check as the default verify (no speed regression). Populate the MHL from the copy-time hash pass.
- *Deferred within this phase:* xxHash-as-default (revisit after measuring full-file cost on field hardware).

**Phase 2 — Safe-Erase ("Release").** *PARKED — depends on a full-file/MHL gate. Design in §4, not yet scheduled.*
- Reversible fake-format + Restore.
- N-of-M + Required destination policy, checksum-gated.
- Prep Mode vs Safe-Erase split.
- Status-first UX; fail-closed edge cases.

**Phase 3 — Suite primitives.**
- Extract the verify/MHL core into a shared module Fetch + FolderSync consume.
- Cloud destination groundwork (S3/Dropbox) — also feeds Fetch.
- Consistent trust-badge language across all three apps.

**Continuous — pay down the debt that threatens the above.**
- The 15k-line `ContentView.swift` monolith (Stage 1b/2 split, currently paused) — the verify engine should land in a *new* testable module, not deeper into the monolith.
- PERF_REVIEW.md's redundant-scan and progress-storm findings — will bite on high-file-count cards exactly when full-verify becomes default.

---

## 7. Decisions & open questions

**Decided 2026-07-29:**
1. ✅ **Verification default** — keep the spot-check default (no speed regression); full-file/xxHash-as-default is deferred, not rejected.
2. ✅ **MHL** — yes, ASC MHL generation is the credibility centerpiece of the next release. Ship it with the honest tiered badge.
3. ✅ **Safe-erase** — parked. Design kept in §4, build deferred until the verify gate exists.

**Still open (revisit when relevant):**
4. **MAM ambition:** Stay lean (offload + verify + erase), or move toward Elements-style metadata/thumbnails/JSON handoff to court higher-end DITs?
5. **Suite timing:** Build the shared verify core as an extractable module now (more work up front), or ship it inside CardRunner and extract later? (Leaning: build MHL in a *new testable module*, not deeper into the 15k-line monolith — that keeps the extraction path open for Fetch/FolderSync.)
6. **Safe-erase v1 scope (when unparked):** reversible fake-format vs. green-light-only (no card writes).
