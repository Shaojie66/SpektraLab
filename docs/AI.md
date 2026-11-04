<!-- README_SYNC: source=480a1a7; updated=2026-11-04 -->
**English** · [简体中文](AI.zh-CN.md) · [Back to the README](../README.md)

# The AI features

Four tools on the Parameters rail's **AI** tab and the Pre-Dev tab's **Portrait**
section. Choose a film, Compose and Refine use a vision model; skin smoothing
and the face and horizon measurements run on the Mac with Apple's Vision
framework and need no model at all.

- [Setup](#setup)
- [Choose a film](#choose-a-film)
- [Compose](#compose)
- [Refine](#refine)
- [Skin smoothing](#skin-smoothing)
- [Privacy and cost](#privacy-and-cost)

## Setup

The AI tab is off by default. Turn it on in **Settings ▸ AI**, choose a
provider and enter its key:

| Provider | What to enter |
|---|---|
| Local Ollama | OpenAI-compatible, base URL `http://localhost:11434/v1`, no key, a model that accepts images (`gemma4:26b` is what this fork is tested with) |
| Any OpenAI-compatible `/chat/completions` service | its base URL, key and an image-capable model |
| Anthropic Claude | the key; `claude-opus-5-5` by default, `claude-sonnet-5-5`, `claude-fable-5-1` and `claude-haiku-5-5` also offered |

Every AI change goes into one step of **Undo AI changes**; ⌘Z undoes that
restoration. None of the tools work on a half-frame pair yet.

## Choose a film

**Exposure first.** If the photo is still on the default (balanced automatic
metering, no compensation), the current film is proofed under the balanced,
centre, protect-highlights and protect-shadows meters, and the model picks the
meter the scene wants: protect highlights for night, fireworks, stage and
backlight; protect shadows for snow, beaches and bright skies. Average metering
can turn a night scene grey, and then comparing films means nothing. A photo
whose exposure is not on the default keeps it, and the panel says whether AI
chose or your setting was kept. An answer that cannot be read keeps the
existing setting.

**Then the films.** Each colour film is proofed with its declared paper
(slides are scanned), push variants skipped, the current pair first; black and
white can be included. Every proof uses the photo's exposure and otherwise
neutral settings: a neutral filter pack, no Scene Placement, grain, glare or
grading. The model gets a numbered contact sheet plus measurements of
clipping, brightness, contrast, colourfulness, cast and latitude coverage, and
returns 3–5 choices with scores and reasons. **Apply** selects the film and
paper and presses Process.

Proofs run in their own engine instance, so the canvas, the edit and its undo
history are untouched. 19 films at 768 px took about 3 seconds on an M-series
Mac.

**Toward a reference.** Under the intent field, **Reference image…** opens a file
panel, or you drop a picture on that row. It then shows as a thumbnail with its
file name, **Change…** and **Remove**. Any file macOS can read works (JPEG,
PNG, HEIC, TIFF; a RAW gives its embedded preview). It is read upright, scaled
to 1024 px and converted to sRGB; a file that is not an image is refused with a
message naming it. Choose a film and [Refine](#refine) share this one
reference, as they share the intent; Compose does not use it.

With a reference, the films' request sends it, labelled "Reference:", ahead of
the contact sheet, labelled "Contact sheet:". The model is told to rank first
the films whose own rendering comes closest to the reference's look —
saturation, contrast, palette, how skin, foliage and sky render — and not its
subject or framing. It is told not to rule a film printed on paper out for overall
brightness or an overall cast, which Refine sets afterwards (print brightness, the enlarger's
filters), and to follow your intent where the two disagree. Each tile also
carries a "film distance": how far its contrast and colourfulness are from the
reference's (lower is closer). For a film printed on paper, brightness and
overall cast are deliberately not counted. A slide film is scanned and has no
print stage, so no enlarger to move them afterwards: its distance counts them
too, and the tile says so. The distances are whole-frame averages, so skin, sky and foliage are
left to the model's eye. The exposure step above is done without the reference:
the meter is the scene's.

A reference with no colour (colourfulness under 4) brings black-and-white films
in for that run even if **Include black and white** is off, and the line under
the ranking says so. With a reference that line reads, for example, "19 films
compared on one neutral print, against the reference." Without a reference,
the request is unchanged. In a test on a small local model (`qwen3-vl` 8B on a
MacBook Air), the film picked was closer to the reference than the current
Portra 400 in all three photo and reference pairs tried (film distance 0.82
against 2.06, 2.59 against 3.70, 2.20 against 5.67).

## Compose

**Recommend crops** measures one whole-frame proof on the Mac (Vision): the
horizon's tilt, the salient region and the faces. Then 8–12 crops are built by
rule:

- A salient region up to 35% of the frame is a subject: on a third, or centred.
- A larger one, as in a landscape or a cityscape, is the scene: the largest
  crop at each ratio, that crop slid to keep the top or the bottom (more sky
  or more foreground) or one side, and a slightly tighter centred crop.
- Ratios follow the picture's orientation — landscape: original, 3:2, 5:4,
  1:1, 16:9; portrait: original, 2:3, 4:5, 1:1, 9:16.
- Crops are levelled when the horizon is off by more than 0.5°.
- Tile 1 is always the current framing.
- Never a cut face; at least 90% of a subject's salient region (60% of a
  scene's); at least 40% of the original; near-identical crops merged.

The crops are rendered as a numbered sheet and the model only picks the best
three and says why. It never names coordinates: vision models compare pictures
well and place a rectangle badly. Each tile uses the same transform **Apply**
does, so what you see is what you get. Apply crops and levels the photo and
keeps your earlier 90° turns and flips. Not available with Film Edge on.

## Refine

The model sees the print at 1024 px and gets up to three rounds to adjust the
metering, Film Exposure, paper brightness, the enlarger's Y/M filters,
pre-flash, grain, halation, Scene Placement, Post-Dev grading and skin
smoothing. It cannot change the film, the paper, the crop, Film Edge, Date
Back or the decode; changes out of scope or out of range are refused and the
refusal is sent back to it. This is not generative retouching: it moves
existing controls, never the film model or the print's pixels, and the result
is saved in the ordinary sidecar.

On a slide film (scanned, no print) paper brightness, the Y/M filters and
pre-flash do nothing, and the model is told so: brightness is then set with
Film Exposure, which on a scan is the light into the film, and colour with
Post-Dev.

Refine can also follow a reference picture: the one chosen under the intent in
[Choose a film](#choose-a-film), which describes what files it takes.

With a reference, every round sends it, labelled "Reference:", ahead of the
print, labelled "Current print:". The model is told to bring the print's look
toward the reference — white balance and colour lean, saturation, brightness,
contrast, how highlights and shadows are rendered — and not its subject,
framing or content, so the reference can be another scene, another film or a
digital photo. It is asked to get as close as the existing fields allow and
stop there, to keep skin and neutral greys believable, and to follow your intent
where the two disagree. Both pictures are measured (brightness, contrast, colourfulness,
magenta/green and warm/cool cast) and the gap is given to the model in
numbers. The limits above still hold: a reference shot on another film, or on
a digital camera, can only be approached within the current film's range.

With a reference, brightness is matched with print brightness, the enlarger's
exposure: Film Exposure and the meter move the scene along the film's curve —
its contrast and the colour in the toe and shoulder — far more than they move
the print's brightness, and Scene Placement is for a scene the medium cannot
hold. Each round's print is also measured against the reference, and a round
that leaves it noticeably further away is taken back; the panel marks it
"Taken back", and the next round is told. The last round is measured too, so
a run toward a reference does not end further from it than it began.

The reference, shared by Choose a film and Refine, is held in memory only. It
stays when you switch photos, so a roll can be refined toward one reference; it
is never saved in a photo's sidecar and is gone when the app quits. Without a
reference, Refine's request is unchanged.

It is told how many faces were found, how many could not be read, and whether
they are all small. It uses skin smoothing only when there is a face —
usually 0.2–0.4 for a natural portrait, none when people are small or only in
the background — and turns Soft skin on only when you ask for clean, soft or
beauty-style skin. In a test, local `gemma4:26b` set 0.3 for the intent
"natural portrait skin".

## Skin smoothing

In the Pre-Dev tab, under **Portrait**: a 0–100 slider, 0 (off) by default,
applied when you release it. No key needed.

**Before the film.** The decode is smoothed and then handed to the engine, so
grain, halation and the paper curve still fall on the skin, and a face does not
become a smooth patch in a grained picture. It is this fork's one exception to
"nothing is edited after the print". Changing the strength re-prints the
photo, about 1–2 seconds for a large image. The slider is disabled, with the
reason under it, when no face is found and when **Don't Apply Film Simulation**
is on (the canvas then shows the untouched photo).

**Finding faces.** Faces are looked for on the whole picture and on
overlapping tiles of it, and each face's landmarks are read on its own
enlarged crop. In tests: 19 faces in a group of about 25 people (7 when looking
at the whole picture only), 8 in a group of 10 (6). Faces mostly hidden behind
someone, or turned far away, are not found. A face found but whose features
cannot be read — too small, turned too far or covered — is left as it is, and
the line under the slider says how many, e.g. "19 faces · 1 more with features
that cannot be read, left as they are". When even the largest face is under 5%
of the photo's long edge (a group of about 25 at 1440 px, largest face 3.4%),
the line adds "all small, so it barely shows".

**What is smoothed.** The mask covers the face outline with the forehead,
cuts out the eyes, brows and lips, and is pulled in and feathered at the edge,
leaving the hairline and the background alone. Neck and body skin are not
touched. The smoothing removes mid-scale blotches and unevenness and keeps the
coarser light and shade of the face and, by default, the pores. How much of a
swing goes depends on its size against the skin around it:

- a blotch, an acne mark or redness (10–20% of the skin's brightness) is removed;
- a swing of 50% or more — the ridge of a nose, the shading beside it, the crease of a nostril's wing — is the face's shape and is kept, so the nose is smoothed with the face;
- one in between is removed in part.

Each face is worked at its own size, so a small face at the back of a group
is not over-smoothed. Strong lines (glasses frames, strands of hair) and the
pixels beside them are protected; pores are not affected by that protection.
Anything much darker or lighter than the skin around it (under about a third
of its brightness, or nearly twice as bright) is an object, not a blotch, and
is left as it is: glasses' nose pads stay solid, a lens's glare stays, a very
dark mole is kept. At 100 about 93% of a medium blotch goes. Suggested: 30–60
for small faces in a group shot, up to 100 for a close-up.

**Soft skin**, the switch under the slider (strength above 0), also softens
the pores, with the film's grain still on top. Grain is what puts texture back,
so how much of Soft skin applies follows how coarse the grain lands: 35 mm at
the film's own grain gets all of it, finer grain (medium format, a lower Grain
slider) less, grain off 40%, in steps of 10%. Coarseness is Grain on/off × the
Grain slider × the film's own grain (only the four black-and-white films
differ) ÷ the film format against 35 mm. The panel says when it is held back
(e.g. "Held to 70%"). With Soft skin on, a change of grain, film or format that
moves the cap re-develops the frame (a second or two); small nudges usually do
not. On a 12 MP portrait with grain off, Soft skin at full kept 51% of the fine
skin texture uncapped and 82% capped, close to the 88% a 35 mm grained print
keeps.

Strength and Soft skin are saved with the photo and can be undone. Copy and
paste settings does not copy them: every photo has different faces.

## Privacy and cost

- Photos leave the Mac only when you press **Recommend**, **Recommend crops** or
  **Refine**, together with exposure data and edit values; when you have chosen
  a reference image, Recommend and Refine send it too, at 1024 px, so each
  request to a cloud model costs one more image. The connection test sends text
  only. With local Ollama nothing leaves the Mac.
- Usage of a cloud model is billed to your own account.
- Keys are stored in the macOS Keychain, never in settings, sidecars or logs.
- Face, horizon and saliency detection always run locally.
- The MCP tool `compare_stocks` lets Claude Code or Claude Desktop compare films
  without an in-app key; the CLI form is
  `spektralab compare photo.NEF --mono --preview sheet.jpg`. The CLI and MCP
  server are off until enabled in **Settings ▸ Agents**.
