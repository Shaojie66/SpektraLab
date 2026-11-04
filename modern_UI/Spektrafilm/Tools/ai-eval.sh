#!/bin/zsh
# ai-eval.sh — the AI evaluation (SpektrafilmTests/AIEvalTests.swift) in one command.
#
#   Tools/ai-eval.sh <manifest.json> <out-folder> --base <URL|anthropic> --model <model>
#                    [--baseline <earlier results.json>] [--strict]
#   Tools/ai-eval.sh --resummarize <results.json> <out-folder> [--baseline <earlier results.json>]
#
# --base is an OpenAI-compatible base URL (e.g. a local Ollama's .../v1) or
# `anthropic` for Claude with the key saved in Settings ▸ AI. Nothing here
# knows a machine's address: pass the one you mean. Builds the tests once,
# runs every case of the manifest, and prints out-folder/summary.md. The
# manifest's format is in Tools/ai-eval/README.md.
set -eu
self=${0:A}
usage() { sed -n '3,7p' "$self" | sed 's/^# \{0,1\}//'; exit 2; }
# --resummarize: results already taken, summed up again with no model —
# after the method changed, say. Builds the tests, writes out/summary.md.
if [[ ${1:-} == --resummarize ]]; then
  [[ $# -ge 3 ]] || usage
  results=${2:A}; out=${3:A}; shift 3; baseline=""
  while [[ $# -gt 0 ]]; do
    case $1 in --baseline) baseline=${2:A}; shift 2 ;; *) usage ;; esac
  done
  [[ -f $results ]] || { echo "No results at $results" >&2; exit 2; }
  [[ -z $baseline || -f $baseline ]] || { echo "No baseline at $baseline" >&2; exit 2; }
  cd "${self:h}/.."; mkdir -p "$out"; log=$out/xcodebuild.log
  xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -configuration Debug \
    -derivedDataPath build/DerivedData build-for-testing > "$log" 2>&1 \
    || { echo "The tests did not build; see $log" >&2; exit 1; }
  vars=(TEST_RUNNER_SPK_AI_EVAL_RESULTS=$results TEST_RUNNER_SPK_AI_EVAL_OUT=$out)
  if [[ -n $baseline ]]; then vars+=(TEST_RUNNER_SPK_AI_EVAL_BASELINE=$baseline); fi
  rc=0
  env "${vars[@]}" xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -configuration Debug \
    -derivedDataPath build/DerivedData test-without-building \
    -only-testing:SpektrafilmTests/AIEvalTests >> "$log" 2>&1 || rc=$?
  if [[ -f $out/summary.md ]]; then cat "$out/summary.md"; else echo "No summary was written; see $log" >&2; fi
  exit $rc
fi
[[ $# -ge 2 ]] || usage
manifest=${1:A}; out=${2:A}; shift 2
base="" model="" baseline="" strict=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --base) base=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --baseline) baseline=${2:A}; shift 2 ;;
    --strict) strict=1; shift ;;
    *) usage ;;
  esac
done
[[ -n $base && -n $model ]] || usage
[[ -f $manifest ]] || { echo "No manifest at $manifest" >&2; exit 2; }
[[ -z $baseline || -f $baseline ]] || { echo "No baseline at $baseline" >&2; exit 2; }

cd "${self:h}/.."
mkdir -p "$out"
log=$out/xcodebuild.log
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -configuration Debug \
  -derivedDataPath build/DerivedData build-for-testing > "$log" 2>&1 \
  || { echo "The tests did not build; see $log" >&2; exit 1; }

rc=0
# Through env(1): an assignment that comes out of an expansion is a command
# to zsh, not an assignment.
vars=(TEST_RUNNER_SPK_AI_E2E=$base TEST_RUNNER_SPK_AI_MODEL=$model
      TEST_RUNNER_SPK_AI_EVAL=$manifest TEST_RUNNER_SPK_AI_EVAL_OUT=$out)
if [[ -n $baseline ]]; then vars+=(TEST_RUNNER_SPK_AI_EVAL_BASELINE=$baseline); fi
if [[ -n $strict ]]; then vars+=(TEST_RUNNER_SPK_AI_EVAL_STRICT=1); fi
env "${vars[@]}" xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -configuration Debug \
  -derivedDataPath build/DerivedData test-without-building \
  -only-testing:SpektrafilmTests/AIEvalTests >> "$log" 2>&1 || rc=$?

grep -E '^EVAL ' "$log" || true
if [[ -f $out/summary.md ]]; then
  echo; cat "$out/summary.md"
else
  echo "No summary was written; see $log" >&2
  grep -E 'error: -\[|skipped' "$log" | head -5 >&2 || true
fi
exit $rc
