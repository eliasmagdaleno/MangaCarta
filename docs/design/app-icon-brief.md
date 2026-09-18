# App icon — commissioning brief

**Status:** ready to send. Written 2026-09-16 so that ordering the icon is a copy-paste, not a
thirteenth handoff line. The placeholder (#165, `scripts/make-app-icon.swift`) is what ships until
this lands; **replace it, do not refine it.**

Owner of the *visual system* this must fit is `DESIGN.md` ("Ink & Seal"). This brief restates only
what a designer outside the repository needs.

## The app, in two sentences

MangaCarta is a native iOS manga reader — a client for MangaDex with an extension seam for other
sources. It is designed to feel like a carefully printed reading companion: warm paper, dark ink,
one vermilion seal.

## What we are ordering

One iOS app icon, with the word or mark reading unmistakably as **MangaCarta**.

Deliverables:

1. **1024×1024 PNG, sRGB, no alpha** (the App Store rejects transparency). Square, unrounded — iOS
   applies its own mask; design so nothing important sits in the outer ~10% of the corners.
2. **Dark and tinted variants** (iOS 18+): a dark-appearance version on the Night Ink ground, and a
   single-layer tinted version (monochrome mark on transparent, iOS applies the tint). Same
   composition as the primary.
3. **Source file** (Figma, Sketch, Affinity or layered PSD/SVG) so we can regenerate.
4. Optional but welcome: a 180×180 preview screenshot on an iPhone home screen among real icons.

## Direction

- **Language:** Ink & Seal. Warm paper ground, near-black ink, one vermilion seal accent used
  *once*. Flat, no gloss, no gradients as decoration, no drop shadows.
- **Mark:** a type-led or emblem-led mark that says *MangaCarta* — either the full wordmark set in a
  serif with print character, or a monogram (MC, or a single letter) presented as a printer's plate
  with a seal. The placeholder uses 漫 in a red seal on a hairline plate; you are free to keep the
  seal idea, drop the kanji, and make the name the subject.
- **Tone:** quiet, editorial, a well-set title page. Not neon, not anime-eyes, not a stack of
  comics, not a speech bubble. It should sit comfortably next to Books, Kindle and Apollo-class
  indie icons and look like the most carefully typeset one.
- **Legibility:** must read at 60×60 (home screen) and at 29×29 (Settings). If the wordmark cannot
  hold at 60px, the monogram carries it and the wordmark is dropped — do not shrink text into noise.

## Tokens (from `DESIGN.md`)

| Role | Light | Dark |
|---|---|---|
| Paper (ground) | `#FBFAF8` | `#141318` (Night Ink) |
| Ink (mark) | `#17140F` | `#F3F1EC` |
| Hairline | `#E5E0D7` | `#2E2C34` |
| Seal (the one accent) | `#B93624` | `#FF6B55` |
| Seal wash | `#FBE7E2` | `#3A1F1B` |

The One Seal Rule: vermilion is the only accent. No second color.

## Do not

- Use the MangaDex logo, colours or any third-party site's mark — the app is a client, not an
  affiliate, and the icon must not imply otherwise.
- Depict adult content or anything that would move the age rating.
- Use stock manga panel art, screentone as the *subject*, or characters.
- Round the corners yourself, add alpha, or bake in a bevel.

## Process

- Two concept directions at first round (one wordmark-led, one monogram/seal-led), each shown at
  1024 and at 60px on a home-screen mock.
- One revision round on the chosen direction.
- Final delivery as listed above.

## Where to order

Any of: a Dribbble/Behance icon specialist with a shipped iOS icon portfolio; 99designs "app icon"
brief (paste this file); or a direct commission. Budget guidance for a single-mark icon with
variants is typically a few hundred USD; the deliverables list above is what to hold them to.

## Acceptance (us, not the designer)

- `AppIcon.appiconset/` gets the 1024 PNG (and dark/tinted slots filled); `Contents.json` updated.
- `xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
  succeeds; icon visible on the simulator home screen in light and dark.
- `scripts/make-app-icon.swift` and #165's placeholder are removed in the same PR.
