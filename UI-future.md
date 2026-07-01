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

### 1. Beautifully-treated scrollbar — fluidfunctionalism.com/docs/scrolling-list
A refined, self-fading, thin scroll indicator (not the chunky default).
- **Best fit:** the **Log panel** (`v3LogSheet`) — Xavier's pick. Also the **Ingest History** list and the
  **Settings** scroll. Anywhere we currently show a native `ScrollView` scrollbar.
- **How (SwiftUI):** custom overlay scroll indicator that fades in on scroll and out when idle; or
  `.scrollIndicators(.hidden)` + a bespoke thin capsule that tracks scroll offset. Keep it glassy.
- **Priority:** HIGH — cheap, high polish, obvious home (log/history/settings).

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

## Suggested sequencing (when we decide to build)
1. **Scrollbar treatment** (log/history/settings) — highest polish-per-effort, clearest home.
2. **Module transitions** — mine 2 specific ones from transitions.dev (blur-in modules, staggered list insert).
3. **Proximity scaling** on ONE cluster (dest tiles or settings rail) as a prototype to feel it out.
4. **Expandable settings rail** (lab01 #7).
5. **Gradient borders** on the golden default box + ring (the 2 hero surfaces).

Each goes through the usual plan → lead codes → reviewer loop, keeps build+tests green, and respects the
guardrails above (no core-burn, status stays calm, Reduce Motion honored).
