#!/bin/zsh
# ai-eval.sh — the AI evaluation (SpektrafilmTests/AIEvalTests.swift) in one command.
#
#   Tools/ai-eval.sh <manifest.json> <out-folder> --base <URL|anthropic> --model <model>
#                    [--baseline <earlier results.json>] [--strict]
#
# --base is an OpenAI-compatible base URL (e.g. a local Ollama's .../v1) or
# `anthropic` for Claude with the key saved in Settings ▸ AI. Nothing here
# knows a machine's address: pass the one you mean. Builds the tests once,
# runs every case of the manifest, and prints out-folder/summary.md. The
# manifest's format is in Tools/ai-eval/README.md.
set -eu
self=${0:A}
usage() { sed -n '3,6p' "$self" | sed 's/^# \{0,1\}//'; exit 2; }
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
