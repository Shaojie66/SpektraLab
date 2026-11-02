<!-- README_SYNC: source=f2aa1b9; updated=2026-11-02 -->
**English** · [简体中文](README.zh-CN.md)

# spektralab-ai

An unofficial fork of [SpektraLab™](https://github.com/JamesQiu2005/SpektraLab),
the macOS film and print simulator, with AI that picks a film, suggests crops,
refines the print and smooths skin — on your Mac with Ollama, or with Claude.

If it is useful to you, a ⭐ [Star](https://github.com/Shaojie66/spektralab-ai/stargazers)
keeps it easy to find again and helps people with the same need discover it.

[![Stars](https://img.shields.io/github/stars/Shaojie66/spektralab-ai?style=flat)](https://github.com/Shaojie66/spektralab-ai/stargazers)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue?style=flat)](license/LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-black?style=flat)
[![Based on](https://img.shields.io/badge/based%20on-SpektraLab-orange?style=flat)](https://github.com/JamesQiu2005/SpektraLab)
[![Last commit](https://img.shields.io/github/last-commit/Shaojie66/spektralab-ai?style=flat)](https://github.com/Shaojie66/spektralab-ai/commits/main)

![spektralab-ai: autumn trees on Kodak Portra 400, printed on Kodak Professional Supra Endura](screenshots/Screenshot_English.png)

Not made or endorsed by SpektraLab's makers. For the official app, without the
AI features, go to [spektralab.app](https://spektralab.app).

## What this fork adds

| | What it does | Runs on |
|---|---|---|
| **Choose a film** | Sets the meter for the scene, proofs every colour film on one contact sheet, and has a vision model pick 3–5 with reasons | your model |
| **Compose** | Measures horizon, salient region and faces, builds 8–12 crops by rule, and has the model pick three; levels a tilted horizon | your model, measurements local |
| **Refine** | Up to three rounds on the existing controls — metering, exposure, filters, grain, grading — never the film, crop or pixels | your model |
| **Skin smoothing** | A Portrait slider that evens out blotches before the film, so grain still lands on the skin; finds the small faces of a group | the Mac, no model |

Every AI change undoes in one step, photos leave the Mac only when you press a
button, and with local Ollama nothing leaves it at all. How each one works,
what it will and will not touch, and what was measured:
[docs/AI.md](docs/AI.md).

## What it is built on

Everything else is SpektraLab 1.3.5, merged from upstream:

- **Spectral, not a LUT.** Light is traced through 81 wavelengths, the film's
  dye layers and the paper's, the way a darkroom does it.
- **Physical units.** Tell it the negative is 120 or 35 mm and the grain,
  halation and coupler diffusion scale with the frame in micrometres.
- **Fast.** A C++ Metal engine compiled into the app: a full-resolution render
  in under a second.
- **The film itself.** Film Edge, Date Back, half-frame pairs, settings sync,
  and a CLI and MCP server — see the
  [SpektraLab README](https://github.com/JamesQiu2005/SpektraLab#readme).

| RAW decode ⟷ film and paper (⌥\\) | grain at 1:1 |
|---|---|
| ![Before and after](screenshots/natural_halation.png) | ![Grain at 1:1](screenshots/physically_accurate_grain.png) |

## Quick start

There are no prebuilt releases of this fork; build it from source. Apple
silicon, macOS 15 or later, Xcode 26 (built and tested here with 26.3).

```bash
git clone https://github.com/Shaojie66/spektralab-ai.git
cd spektralab-ai
engine/build.sh bundle                 # engine, kernels, baked resources
cd modern_UI/Spektrafilm
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
           -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/SpektraLab.app
```

To use a local model, install [Ollama](https://ollama.com) and pull one that
reads images:

```bash
ollama pull gemma4:26b
```

Then in **Settings ▸ AI**: turn it on, choose OpenAI-compatible, base URL
`http://localhost:11434/v1`, model `gemma4:26b`. For Claude, choose Anthropic
and enter your key; it is kept in the macOS Keychain.

Re-run `engine/build.sh bundle` whenever `engine/resources/` changes. If Xcode
suddenly cannot find `metal`, clean the build folder (⇧⌘K).

## Test

```bash
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
           -configuration Debug -derivedDataPath build/DerivedData test
```

629 tests. The camera fixtures are not in this repository: without them 76
skip and the run takes about 45 seconds while still reporting 0 failures —
trust the duration. To put your own photos through open, Process, a
full-size print and an export, each stage timed:

```bash
TEST_RUNNER_SPK_PIPELINE_DIR=~/photos TEST_RUNNER_SPK_PIPELINE_OUT=/tmp/out \
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
           -configuration Debug -derivedDataPath build/DerivedData \
           test -only-testing:SpektrafilmTests/PipelinePhotoTests
```

## Layout

| | |
|---|---|
| `modern_UI/Spektrafilm/` | the app: SwiftUI, AppKit, Metal |
| `modern_UI/Spektrafilm/Spektrafilm/AI/` | this fork's AI: proofs, prompts, crops, face masks, skin smoothing |
| `engine/` | the C++20 render engine, its MSL kernels and C ABI |
| `docs/AI.md` | the AI features in detail |
| `ARCHITECTURE.md` | how it fits together — §7.14 is the AI |
| `AGENTS.md` | conventions and the traps that cost real time |

## This fork and upstream

The AI features were proposed upstream and are maintained here instead.
Fixes to SpektraLab itself go upstream: the sidecar watcher fix found here was
merged there as
[#54](https://github.com/JamesQiu2005/SpektraLab/pull/54). Windows and
Linux work belongs to upstream's `Windows_Linux` branch.

Pull requests about the AI features are welcome here: one change per
commit, with a message that says what it does and why.

## Credits and licence

The film process model, its 28 measured colour profiles and the print LUTs are
[spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato;
4 measured B&W profiles are by Hanze Qiu; SpektraLab is a native C++/Metal
port of that engine and the application built around it.

| | |
|---|---|
| app and engine | GPL-3.0-or-later |
| film and paper profiles, print LUTs | CC BY-SA 4.0 |
| metal-cpp | Apache-2.0 |

All texts ship inside the app, under **About SpektraLab**.

## Trademark

From SpektraLab's own notice:

> SpektraLab™ and the SpektraLab icon are managed by Guangzhou Songzi Intelligent
> Technology Services Co., Ltd.; trademark registration is in progress.
>
> Forks are welcome. You can study, modify, port and redistribute the code under
> its licences, which cover the code and data but not the name or the icon. Keeping
> both in a personal fork is fine. If you publish a build for other people, even a
> free one, please give it its own name and icon. You are welcome to say it is
> based on SpektraLab, as long as it is clear that your project is unofficial.
>
> We reserve the right to act against builds that pass themselves off as official
> or imply our endorsement.

This repository is a personal fork, publishes no builds, and is not official.

---

⭐ [Star](https://github.com/Shaojie66/spektralab-ai/stargazers) if it helps ·
[Open a pull request](https://github.com/Shaojie66/spektralab-ai/pulls) for a
fix or an improvement to the AI features.
