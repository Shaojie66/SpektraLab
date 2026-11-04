# AI evaluation

Measures how close the AI assistant gets a photograph to a reference picture, on a real model, and keeps the numbers so the next run can be held against them.

Two bugs passed every unit test and were found only this way: the refiner told the enlarger filters' direction backwards (45bcc2c), and Apply printed the previous film (4dacb23). Each was found by measuring the distance to a reference with a throwaway script. This is that measurement, kept.

## Run it

```bash
modern_UI/Spektrafilm/Tools/ai-eval.sh <manifest.json> <out-folder> \
    --base <URL|anthropic> --model <model> \
    [--baseline <earlier results.json>] [--strict]
```

`--base` is an OpenAI-compatible base URL, such as a local Ollama at `http://localhost:11434/v1`, or `anthropic` to use the key saved in Settings ▸ AI. The script knows no machine's address: pass the one you mean.

The script builds the tests once, runs every case of the manifest, and prints `<out-folder>/summary.md`. The whole `xcodebuild` output goes to `<out-folder>/xcodebuild.log`. It builds into `build/DerivedData`, so do not run it while another `xcodebuild` is using that folder.

A run needs a real model and takes minutes per case. It is not part of the default suite; `AIEvalTests.testEvaluate` skips unless `SPK_AI_E2E` and `SPK_AI_MODEL` are set, and the script sets them.

## When to run it

Run it before and after any change to:

- a prompt in `Spektrafilm/AI/AIPrompts.swift`,
- the model you use,
- the choose or refine flow in `Spektrafilm/AI/AIAssistant.swift`.

Pass the earlier run's `results.json` as `--baseline`. A green unit suite does not cover these changes: the two bugs above were green.

## Manifest

A JSON file listing the photographs, the reference each is brought toward, and how.

```json
{
  "runs": 3,
  "cases": [
    { "name": "warm-portrait", "photo": "/path/to/fivek/a0269.dng", "reference": "refs/ref-warm.jpg",
      "modes": ["refine", "choose+refine"] },
    { "name": "cool-night", "photo": "/path/to/fivek/a4796.dng", "reference": "refs/ref-cool.jpg",
      "modes": ["refine", "choose+refine"] },
    { "name": "muted-landscape", "photo": "/path/to/fivek/a1839.dng", "reference": "refs/ref-muted.jpg",
      "modes": ["refine", "choose+refine"] }
  ]
}
```

This is `example.json` in this folder. Its paths are placeholders.

| Field | Required | Meaning |
|---|---|---|
| `runs` | no, default 5 | How many times each case runs in each mode. Five, because three against a baseline's three cannot be marked (see below). |
| `cases[].name` | yes | Unique. Names the case in the table and its folder in the output. |
| `cases[].photo` | yes | The photograph to edit. |
| `cases[].reference` | no | The picture to bring it toward. Without one nothing is measured. |
| `cases[].intent` | no | What the person wants, in words, given to the assistant as its intent. |
| `cases[].modes` | no, default `["refine"]` | `refine`, or `choose+refine`. |

Paths are absolute or relative to the manifest, and `~` is expanded. Nothing is copied into the repository, so licensed pictures stay where they are.

The two modes:

- `refine`: Process the photo, then Refine toward the reference.
- `choose+refine`: Recommend a film toward the reference, Apply the first pick, then Refine.

The manifest is refused before anything runs, naming the case, when:

- a photo or a reference does not exist,
- `choose+refine` is asked for without a reference,
- two cases have the same name,
- there are no cases, or `runs` is below 1.

## What a run does

Every run starts from a fresh copy of the photo, so it starts from an untouched edit; the copy's sidecar in Application Support is removed afterwards. Per run:

1. Process, and measure the distance to the reference (before).
2. `choose+refine` only: Recommend toward the reference, Apply the first pick, and measure again (after choosing). Also recorded: the pick's film distance, the film distance of the film the photo had, of the nearest proof, and the pick's rank among the proofs.
3. Refine, and measure again (after). Also recorded: the gap in each field, how many rounds ran, how many were retracted, unreadable or refused, and the seconds.

A run that fails (a timeout, an error from the model) is recorded with its error, and the rest continue. A run has 1800 s before it counts as failed.

**Distance** is `ReferenceImage.distance`: the gaps in mean luma, contrast, colourfulness and the two colour casts, each divided by the size of a difference one sees side by side (luma 0.05, contrast 0.03, colourfulness 8, casts 0.02), then summed. Lower is closer; 0 is the same numbers.

**Film distance** is only the contrast and colourfulness terms. Brightness is the enlarger's to set and an overall cast is its filters', so neither counts against a film.

## Output

Everything is in the out folder.

| File | What it is |
|---|---|
| `summary.md` | The table to read, described below. |
| `results.json` | Every number of every run, and the model, machine, manifest and date. Keep it: it is the next run's `--baseline`. |
| `sheet.jpg` | One row per case: the reference, the photo before, and for each mode the picture after choosing and after Refine. The first run of each only. |
| `<case>/<mode>-<run>/` | `reference.jpg`, `before.jpg`, `chosen.jpg` (`choose+refine` only) and `after.jpg` for that run. |
| `xcodebuild.log` | The build and test output. Start here when there is no summary. |

### Reading `summary.md`

The top lists the model and base URL, the machine, the manifest and the date. Numbers are distances to the reference, medians over the runs that finished. Failed runs are counted, not scored: a timeout says nothing about how far a print would have got.

| Column | Meaning |
|---|---|
| Runs | `3` or, if some failed, `2 of 3 (1 failed)`. |
| Start | Distance after Process, before the AI touched it. |
| End (median, range) | Distance after Refine, with the lowest and highest run. The number to watch. |
| After choosing | Distance after the first pick was applied (`choose+refine`; `–` otherwise). |
| Film picked (rank) | The film or films picked, and the pick's median rank among the proofs by film distance. 1 means the nearest proof. |
| Retracted | Rounds Refine took back because they moved the print away from the reference. |
| Unreadable | Rounds whose answer could not be read. |

What to look for:

- End below Start: Refine moved the print toward the reference. End at or above Start means Refine did not help.
- After choosing below Start: the film choice helped. A rank well above 1 means the model picked a film that is not among the nearest.
- A wide range in End means one model varies from run to run; compare medians, not single runs, and keep `runs` at 5 or more.
- Failed runs are listed at the bottom with their errors.

## Baseline and `--strict`

With `--baseline <earlier results.json>` the table gains four columns: the baseline's End median, the change of the mean End, `p`, and a verdict.

`p` comes from a one-sided permutation test. The finished runs of both evaluations are pooled, every way of drawing as many runs as this evaluation has is tried, and `p` is the share of draws whose mean is at least as far from the reference as the one observed. It is the chance of a change that large from the model's own run-to-run spread alone. A row is marked **further** when the mean moved away and `p < 0.05`, and **closer** when it moved toward the reference and its own `p < 0.05`. Above 200,000 draws (about ten runs a side) the test samples 20,000 of them with a fixed seed, so the same results give the same table.

Why not a fixed margin: until 2026-11-04 a row was marked when its median ended more than 0.5 further. On muted-landscape, Refine alone moved 4.01 → 5.08 between two days with its prompt unchanged. Pooling those six runs, a split of three against three moved the median by more than 0.5 in 40 % of draws; on cool-night in all of them; on warm-portrait in none. One margin cannot fit cases this different. The permutation test measures each case against its own spread. The test uses the mean, while the table shows medians: with three or five runs a median moves in steps, and draws tie with the observed one.

**Runs matter.** The smallest `p` a test can give is 1 over the number of draws. Three runs against three give 20 draws, so `p` cannot go below 0.05 and nothing can be marked; the verdict then says *these runs cannot reach p < 0.05*. That is why `runs` defaults to 5: five against a baseline of three allow 0.018, five against five 0.004. A side with fewer than two finished runs is not tested.

The comparison means something only on the same cases (photographs, references and modes; the number of runs may differ), machine and model. When the baseline differs in any of them, the summary says **Not like for like** and names what differs. Do not read a mark then. Results written before the cases were kept are held to the manifest's path.

A small but consistent shift can be marked: the test asks whether the runs moved, not whether the move matters. Look at the change and at `sheet.jpg` before acting on a mark.

By default the evaluation only reports. With `--strict` the test fails, and the script exits non-zero, when any row is marked **further**; **closer** never fails it.

### Summing up again

```bash
modern_UI/Spektrafilm/Tools/ai-eval.sh --resummarize <results.json> <out-folder> [--baseline <earlier results.json>]
```

Writes a new `summary.md` from results already taken, with no model and no engine: after the method changed, or against a different baseline.

## Making references

Neither the photographs nor the references are in the repository: the photographs come from [MIT-Adobe FiveK](https://data.csail.mit.edu/graphics/fivek/), which is under a research licence and not redistributed. This is how the references used so far were made.

Photographs (the DNGs): `a0269` (portrait), `a4796` (night), `a1839` (landscape).

Each reference is a different FiveK photo, converted to an sRGB JPEG at 1600 px on the long edge and graded with a film-simulation HaldCLUT from RawTherapee's collection, applied with trilinear interpolation:

| Reference | Photo | HaldCLUT | Look |
|---|---|---|---|
| `ref-warm.jpg` | `a0114` | Kodak Portra 160 VC 4 ++ | warm |
| `ref-cool.jpg` | `a1806` | Polaroid 690 Cold 5 ++ | cool |
| `ref-muted.jpg` | `a4211` | Fuji 160C 1 - | muted |

Convert the photo:

```bash
sips -s format jpeg -Z 1600 a0114.dng --out a0114.jpg
```

Apply the HaldCLUT. This script needs numpy and Pillow, so it is not shipped in `Tools/` (the scripts there use only the standard library). Run it outside the repository, for example in a scratch folder:

```python
# hald_apply.py <photo.jpg> <haldclut.png> <out.jpg>
import sys

import numpy as np
from PIL import Image

photo, clut, out = sys.argv[1:4]
img = np.asarray(Image.open(photo).convert("RGB"), dtype=np.float64) / 255
hald = np.asarray(Image.open(clut).convert("RGB"), dtype=np.float64) / 255

# A level-L HaldCLUT is L**3 pixels square and holds a cube n = L**2 on a side,
# red varying fastest, then green, then blue.
n = round(hald.shape[1] ** (2 / 3))
lut = hald.reshape(n, n, n, 3)  # indexed [blue, green, red]

x = img * (n - 1)
lo = np.minimum(np.floor(x).astype(int), n - 2)
frac = x - lo
r, g, b = lo[..., 0], lo[..., 1], lo[..., 2]
fr, fg, fb = (frac[..., k, None] for k in range(3))

graded = 0
for dr in (0, 1):
    for dg in (0, 1):
        for db in (0, 1):
            w = (fr if dr else 1 - fr) * (fg if dg else 1 - fg) * (fb if db else 1 - fb)
            graded = graded + w * lut[b + db, g + dg, r + dr]

Image.fromarray((np.clip(graded, 0, 1) * 255 + 0.5).astype(np.uint8)).save(out, quality=95)
```

```bash
python3 -I hald_apply.py a0114.jpg "Kodak Portra 160 VC 4 ++.png" refs/ref-warm.jpg
```

The script was checked with an identity HaldCLUT, which returns the photo unchanged.

Use a different photo for the reference than the one you edit. A reference made from the same photo measures how well the assistant undoes a known grade, which is a different question.

## One case without a manifest

`SPK_AI_IMAGE` and `SPK_AI_REFERENCE` run one case once, in `refine` mode, or in `choose+refine` with `SPK_AI_CHOOSE=1`. `SPK_AI_OUT` is its out folder. This replaced the former `AIReferenceEndToEndTests`. Set them as `TEST_RUNNER_` variables on `xcodebuild`, with `TEST_RUNNER_SPK_AI_E2E` and `TEST_RUNNER_SPK_AI_MODEL`, and `-only-testing:SpektrafilmTests/AIEvalTests`.

## Limits

- Slow. A `choose+refine` run took 336 s on gemma4:26b locally. Earlier runs of an 8B model on a MacBook Air took 3 to 7 minutes, and the first request for a new photo there could exceed the app's 180 s request timeout. Such a run is recorded as failed.
- One model varies from run to run. A single run proves nothing; keep `runs` at 5 or more and read the medians and `p`.
- The distance is five measured numbers, not a judgement of how the picture looks. A smaller distance means the numbers are closer; look at `sheet.jpg` before believing it.
- A baseline compares only on the same manifest, machine and model.
