# CardRunner — UI Future / Design North Star

**Not a build queue.** A curated set of interaction/motion references Xavier likes, mapped to concrete
CardRunner surfaces, so we build the *best* version deliberately rather than bolting things on. We chat
these over and cherry-pick — restraint is the whole point.

## Taste we've already locked (the guardrails)
- **Liquid-glass + restrained neon.** Frosted glass + ONE purposeful accent (brand purple→cyan→magenta);
  let content provide color. Don't neon everything.
- **Every control reacts** (the `.v3Hover` idiom) — hover, press, and transitions should feel tactile;
  the UI should never feel static.
- **No always-on animation.** One-shot (`withAnimation` + delayed clear / KeyframeAnimator), never a
  `TimelineView(.animation)`/timer — that once burned a whole core and starved the ingest pipe. Any new
  motion must respect this and **Reduce Motion**.
- **Footage-safety status must never fidget.** Motion on a *status* element (the active ring, a
  "SAFE TO PULL" badge, a failure strip) reads as instability. Decorate the idle/ambient states; keep
  the load-bearing status calm.
- **Rounded corners + escape/click-outside on every module** (already the `v3ModalOverlay` standard).

## The references

### 1. Edge-aware scroll affordance — fluidfunctionalism.com/docs/scrolling-list
**Reframe (reviewer):** it's not just a thin fading thumb — the real treatment is **edge-aware**: a
surface-matched gradient fade + chevron at any edge that has *more content beyond it* ("there's more
below"). That's the higher-value half — CardRunner's real problem isn't ugly scrollbars, it's *hidden
content* (a 500-line log, 80 history rows).
- **Best fit / HERO:** the **Log panel** (`v3LogSheet`) bottom-edge fade + chevron + **jump-to-tail** —
  load-bearing (find the tail of a live log under stress), not decorative. Then **History** + **Settings**
  scroll edges. Skip the short DEV/failure strips.
- **How (SwiftUI):** `.scrollIndicators(.hidden)` + a `LinearGradient` mask fading to the surface color
  (`#0c0822`) at the edge with more content + a chevron; thin capsule thumb tracking `contentOffset`,
  faded via a **debounced `DispatchWorkItem`** (NOT a Timer). `.onScrollGeometryChange` if we ever bump to
  macOS 15; else a `GeometryReader` offset read.
- **Priority:** HIGH — highest value-per-effort, load-bearing.

### 2. Real transition assets — transitions.dev
A catalog of well-tuned transitions across 5 params (duration, easing, distance, blur, scale), plus
origin-aware animation and staggering.
- **Best fit:** module open/close (Add/Edit/History/Log/Date — currently a simple scale+opacity),
  settings category switches, list item enter/leave (destination tiles, awaiting lanes, history rows),
  and the completion styles. Blur-on-enter + origin-aware would elevate the modules a lot.
- **Caution:** keep the ingest/ring status transitions calm (safety rule above).
- **Priority:** MEDIUM — mine 2-3 specific transitions (module enter with blur; staggered list insert)
  rather than a global overhaul.

### 3. Gradient borders — gradient-border.floriankiem.com
Animated/static gradient outlines (can't do with a plain border — needs a masked gradient / gradient
stroke). **"Not every button — a couple key ones."**
- **Best fit (a FEW only):** the **DEFAULT DESTINATION** golden box (a slow brand-gradient outline would
  make it feel alive/primary), the **center ring** (a subtle gradient stroke on the idle/armed state),
  and maybe the primary **Add destination** CTA on hover. Possibly an animated gradient border on a card
  lane while it's *actively copying* (draws the eye to live work) — but test against the "status calm"
  rule.
- **How (SwiftUI):** `.overlay(RoundedRectangle().strokeBorder(AngularGradient(...)))`, optionally a slow
  rotating `AngularGradient` for the animated version (one-shot / gated, not always-on).
- **Priority:** MEDIUM-LOW — 2-3 hero surfaces max. Overuse kills it.

### 4. Draggable/expandable side drawer — lab01.dev (UI experiment #7)
A side menu you drag to expand and reveal more.
- **Best fit:** the **Settings icon-rail** — drag/click to expand from icons-only to icons+labels (and
  maybe descriptions). Currently it's a fixed 78pt icon rail; an expandable rail is a natural, discoverable
  upgrade (and helps new users who don't know the icons). Also possibly the **destinations column** or a
  future "details" drawer.
- **Priority:** MEDIUM — nice, self-contained; do after the higher-polish quick wins.

### 5. Proximity scaling (Dock-style falloff) — the pointer-move snippet
Cursor distance drives subtle scale/darken on nearby elements: `scale = 1 + (1 - dist/120) * amp`,
cache `getBoundingClientRect`.
- **Best fit:** the **destinations column** tiles (acts as aim-assist toward the tile you're reaching for),
  the **Settings rail** icons, and the **bottom-bar chips**. Very faintly on the **idle/armed ring**.
- **Hard rules:** amplitude TINY (~×1.03–1.05 + slight brightness), NOT the Dock's ×1.5 — "responsive but
  composed." Do **NOT** apply to the active ring or any mid-transfer status element. Must be event-driven
  (`onContinuousHover` for local cursor coords + each element's frame via a named coordinate space →
  distance → scale/brightness) with no always-on loop.
- **Priority:** MEDIUM — genuinely delightful, but easy to overdo; prototype on ONE cluster (dest tiles or
  the settings rail) and judge.

## Suggested sequencing (reviewer-refined — build the safe/high-value first, proximity LAST)
1. **Log-panel edge fade + jump-to-tail** (the functional half of #1) — load-bearing, clear home.
2. **Origin-aware blur-in module transition** — modules grow *from the clicked tile* (reuse `destFrames`);
   elevates every module at once.
3. **Golden-box gradient sweep on promotion** — one-shot sweep when a tile becomes the default; ties into
   the make-default gesture already shipped (`v3DefaultPop` trigger). One surface, one-shot.
4. **Thin fading thumb + History/Settings edges** — roll the scrollbar treatment to the other lists.
5. **Expandable settings rail** (lab01 #7) — bigger interaction; do when there's room.
6. **Proximity scaling on dest tiles** — LAST. Delightful but the ONLY item that can regress the
   core-burn guardrail (`onContinuousHover` fires a lot): throttle (only recompute on >N-pt move), gate
   OFF while `runningCount > 0`, reuse `destFrames`, disable under Reduce Motion. Prototype one cluster;
   be willing to cut it.

**Honest meta-note:** 5 references is a lot of surface for an app whose superpower is *calm trust*.
Recommendation: ship 1-3, live with them, THEN decide if proximity/drawer earn their complexity.

## Do NOT (where the reference would hurt — every one is a STATUS element)
- **Gradient border on the center ring** — the ring is load-bearing status (idle/armed/copying/done/failed,
  each a meaningful color). A gradient muddies the color semantics + reads as motion-on-status. Keep it a
  solid semantic color.
- **Gradient border / any animation on an active-copying lane** — the most safety-critical status in the
  app; it must read as steady progress, not a shimmering party.
- **transitions.dev error-shake / success-bounce / status-badge motion** — motion on status = reads as
  instability in a footage tool. Decline.
- **Proximity scaling on the ring** — even "very faintly": the armed→copying transition can happen while
  the cursor is near it, animating a status element at the worst moment.

Adopt the transitions.dev principle **"appear gently, dismiss instantly"** app-wide (help text / hover
glows ease in but cut out instantly — right instinct for a tool where the operator wants to act).

Each goes through the usual plan → lead codes → reviewer loop, keeps build+tests green, and respects the
guardrails above (no core-burn, status stays calm, Reduce Motion honored).

## Open questions to settle before building
- Does a destination **"details" drawer** (lab01 idea) compete with the click-to-Edit modal already built?
  (If clicking a tile opens Edit, a drawer needs a different trigger — a chevron — or it's redundant.)
- Reduce-Motion for proximity scaling: disable entirely (recommended) or keep the brightness lift without scale?
- Confirm the **ring stays a solid semantic color** (no gradient border / no proximity) — or does Xavier
  specifically want it decorated (then we design a version that can't be confused with the status colors)?
- **lab01 experiments beyond #7:** the page is JS-rendered — grab 2-3 screenshots/GIFs of the ones that
  caught the eye so we map them concretely instead of guessing.
