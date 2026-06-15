#!/usr/bin/env bash
# lint-feedback.sh — PostToolUse closed feedback loop (Cursor-style "surface
# lint/type errors after every edit"). After a Write|Edit|MultiEdit|NotebookEdit,
# re-check ONLY the changed file with whatever toolchain is actually installed, and
# feed concise diagnostics back to the agent so it fixes them on the next step.
#
# Feedback channel (PostToolUse, per the hook docs): advisory findings are injected
# via the JSON field `hookSpecificOutput.additionalContext` on stdout with exit 0 —
# Claude Code wraps it in a system-reminder at the point the hook fired. We do NOT
# undo the edit. Under enforce mode we additionally persist the findings so the Stop
# gate (verify-build.sh) won't pass with unaddressed lint/type errors (PostToolUse
# exit 2 is non-blocking and cannot gate completion).
#
# NOT `set -e`: linters exit non-zero ON FINDINGS — that must never abort the loop.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"

MAXLINES=25                 # concise: cap the surfaced findings, summarize the rest
: "${LINT_TIMEOUT:=12}"     # per-tool wall-clock cap (the hook itself also times out)

# feedback_loop master switch (default on); off -> silent no-op.
[ "$(bd_setting feedback_loop true)" = "true" ] || exit 0

bd_load_hook_input
TARGET="$(bd_hook_field tool_input.file_path)"
[ -n "$TARGET" ] || TARGET="$(bd_hook_field tool_input.notebook_path)"
[ -n "$TARGET" ] || exit 0

PROJECT="$(bd_project_dir)"
case "$TARGET" in
  /*) ABS="$TARGET" ;;
  *)  ABS="$PROJECT/$TARGET" ;;
esac
ABS="$(bd_normalize_path "$ABS")"
REL="${ABS#"$PROJECT"/}"

# --- skip rules (avoid noise / feedback loops) -------------------------------
case "$REL" in .claude/*) exit 0 ;; esac          # the plugin's own memory
[ -f "$ABS" ] || exit 0                            # deleted / not a regular file
base="$(basename "$ABS")"
case "$base" in                                    # lockfiles
  package-lock.json|yarn.lock|pnpm-lock.yaml|npm-shrinkwrap.json|Cargo.lock|go.sum|poetry.lock|Pipfile.lock|composer.lock|Gemfile.lock) exit 0 ;;
esac
ext="${base##*.}"
ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
case "$ext" in                                     # non-code files (code only)
  md|markdown|txt|rst|json|jsonc|yaml|yml|toml|ini|cfg|conf|env|xml|html|htm|css|scss|sass|less|svg|png|jpg|jpeg|gif|ico|webp|pdf|csv|tsv|lock|sum|map|gitignore|gitattributes) exit 0 ;;
esac

# --- accumulators ------------------------------------------------------------
FINDINGS=""   # concise diagnostic lines fed back to the agent
SKIPS=""      # "skipped: <tool> not found" notes -> stderr only (keep stdout JSON clean)
ROOT=""       # nearest project root for the file's ecosystem
RAW=""        # scratch for a tool's filtered output
add_find() { FINDINGS="${FINDINGS}$1"$'\n'; }
add_skip() { SKIPS="${SKIPS}skipped: $1"$'\n'; }
emit_lines() {  # prefix each line of $RAW, trimming the project/root prefix for brevity
  local pfx="$1" l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    l="${l#"$PROJECT"/}"; [ -n "$ROOT" ] && l="${l#"$ROOT"/}"
    add_find "$pfx: $l"
  done <<<"$RAW"
}

run_timed() { if bd_have timeout; then timeout "$LINT_TIMEOUT" "$@"; else "$@"; fi; }

find_root() {  # walk up from the file's dir for marker $1; print dir or fail
  local d; d="$(dirname "$ABS")"
  while :; do
    [ -e "$d/$1" ] && { printf '%s' "$d"; return 0; }
    case "$d" in /|.|"") return 1 ;; esac
    local nd; nd="$(dirname "$d")"
    [ "$nd" = "$d" ] && return 1
    d="$nd"
  done
}

# node tools: prefer local node_modules/.bin, then global, then npx --no-install
have_node_tool() {
  { [ -n "$ROOT" ] && [ -x "$ROOT/node_modules/.bin/$1" ]; } && return 0
  bd_have "$1" && return 0
  { bd_have npx && [ -n "$ROOT" ] && [ -d "$ROOT/node_modules" ]; } && return 0
  return 1
}
run_node_tool() {
  local tool="$1"; shift
  if [ -n "$ROOT" ] && [ -x "$ROOT/node_modules/.bin/$tool" ]; then
    run_timed "$ROOT/node_modules/.bin/$tool" "$@"
  elif bd_have "$tool"; then
    run_timed "$tool" "$@"
  elif bd_have npx && [ -n "$ROOT" ] && [ -d "$ROOT/node_modules" ]; then
    run_timed npx --no-install "$tool" "$@"
  else
    return 127
  fi
}

# --- per-ecosystem checks (per-FILE; only run what's installed) --------------
check_jsts() {
  ROOT="$(find_root package.json || true)"; [ -n "$ROOT" ] || ROOT="$(find_root tsconfig.json || true)"
  if have_node_tool eslint; then
    RAW="$(run_node_tool eslint --format unix "$ABS" 2>/dev/null || true)"
    RAW="$(printf '%s' "$RAW" | grep -E ':[0-9]+:[0-9]+:' || true)"
    [ -n "$RAW" ] && emit_lines "eslint"
  else add_skip "eslint"; fi
  case "$ext" in
    ts|tsx)
      if [ -n "$ROOT" ] && [ -e "$ROOT/tsconfig.json" ]; then
        if have_node_tool tsc; then
          local relf="${ABS#"$ROOT"/}"
          RAW="$(cd "$ROOT" && run_node_tool tsc --noEmit --pretty false 2>/dev/null || true)"
          RAW="$(printf '%s' "$RAW" | grep -F "$relf" | grep -E 'error TS' || true)"
          [ -n "$RAW" ] && emit_lines "tsc"
        else add_skip "tsc"; fi
      fi ;;
  esac
  if have_node_tool prettier; then
    run_node_tool prettier --check "$ABS" >/dev/null 2>&1 || add_find "prettier: $REL is not formatted (prettier --write)"
  fi
}

check_py() {
  ROOT="$(find_root pyproject.toml || true)"; [ -n "$ROOT" ] || ROOT="$(find_root setup.cfg || true)"
  if bd_have ruff; then
    RAW="$(run_timed ruff check --quiet "$ABS" 2>/dev/null || true)"
    RAW="$(printf '%s' "$RAW" | grep -E ':[0-9]+:[0-9]+:' || true)"; [ -n "$RAW" ] && emit_lines "ruff"
  elif bd_have flake8; then
    RAW="$(run_timed flake8 "$ABS" 2>/dev/null || true)"
    RAW="$(printf '%s' "$RAW" | grep -E ':[0-9]+:[0-9]+:' || true)"; [ -n "$RAW" ] && emit_lines "flake8"
  else add_skip "ruff/flake8"; fi
  if bd_have mypy; then
    RAW="$(run_timed mypy --no-error-summary --no-color-output "$ABS" 2>/dev/null || true)"
    RAW="$(printf '%s' "$RAW" | grep -E ': (error|warning|note):' || true)"; [ -n "$RAW" ] && emit_lines "mypy"
  elif bd_have pyright; then
    RAW="$(run_timed pyright "$ABS" 2>/dev/null || true)"
    RAW="$(printf '%s' "$RAW" | grep -E ' - (error|warning)' || true)"; [ -n "$RAW" ] && emit_lines "pyright"
  else add_skip "mypy/pyright"; fi
  if bd_have ruff; then
    run_timed ruff format --check "$ABS" >/dev/null 2>&1 || add_find "ruff-format: $REL is not formatted (ruff format)"
  elif bd_have black; then
    run_timed black --check --quiet "$ABS" >/dev/null 2>&1 || add_find "black: $REL is not formatted (black)"
  fi
}

check_go() {
  if bd_have gofmt; then
    RAW="$(run_timed gofmt -l "$ABS" 2>/dev/null || true)"
    [ -n "$RAW" ] && add_find "gofmt: $REL is not formatted (gofmt -w)"
  else add_skip "gofmt"; fi
  if bd_have go; then
    local d; d="$(dirname "$ABS")"
    RAW="$(cd "$d" && run_timed go vet . 2>&1 || true)"
    RAW="$(printf '%s' "$RAW" | grep -F "$base" || true)"; [ -n "$RAW" ] && emit_lines "go vet"
  fi
  if bd_have golangci-lint; then
    RAW="$(run_timed golangci-lint run "$ABS" 2>/dev/null || true)"
    RAW="$(printf '%s' "$RAW" | grep -F "$base" || true)"; [ -n "$RAW" ] && emit_lines "golangci-lint"
  fi
}

check_rust() {
  ROOT="$(find_root Cargo.toml || true)"
  if bd_have rustfmt; then
    run_timed rustfmt --check --edition 2021 "$ABS" >/dev/null 2>&1 || add_find "rustfmt: $REL is not formatted (cargo fmt)"
  else add_skip "rustfmt"; fi
  if [ -n "$ROOT" ] && bd_have cargo; then
    RAW="$(cd "$ROOT" && LINT_TIMEOUT=15 run_timed cargo check --message-format short 2>&1 || true)"
    RAW="$(printf '%s' "$RAW" | grep -F "$base" | grep -E 'error|warning' || true)"; [ -n "$RAW" ] && emit_lines "cargo"
  fi
}

check_generic() {  # other code-ish files: only the project's own pre-commit, per-file
  if [ -e "$PROJECT/.pre-commit-config.yaml" ] && bd_have pre-commit; then
    RAW="$(cd "$PROJECT" && run_timed pre-commit run --files "$ABS" 2>&1 || true)"
    RAW="$(printf '%s' "$RAW" | grep -iE 'failed|error' || true)"; [ -n "$RAW" ] && emit_lines "pre-commit"
  fi
}

case "$ext" in
  js|jsx|ts|tsx|mjs|cjs) check_jsts ;;
  py)  check_py ;;
  go)  check_go ;;
  rs)  check_rust ;;
  *)   check_generic ;;
esac

# --- enforce-mode persistence (Stop gate reads this) -------------------------
record_path() { printf '%s/feedback/%s.txt' "$(bd_builder_dir)" "$(printf '%s' "$REL" | sed 's#[/\\:. ]#_#g')"; }
write_record() {
  bd_feedback_enforce || return 0
  local fb; fb="$(bd_builder_dir)/feedback"; mkdir -p "$fb" 2>/dev/null || true
  printf '%s\n' "$1" > "$(record_path)" 2>/dev/null || true
}
clear_record() { bd_feedback_enforce || return 0; rm -f "$(record_path)" 2>/dev/null || true; }

# --- emit concise advisory feedback via additionalContext --------------------
emit_context() {  # $1 = message -> PostToolUse additionalContext JSON on stdout, exit 0
  if bd_have_python; then
    BD_FB_MSG="$1" $BD_PYTHON -c 'import json,os;print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":os.environ["BD_FB_MSG"]}}))' 2>/dev/null && return 0
  fi
  local e; e="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$e"
}

if [ -n "$FINDINGS" ]; then
  total="$(printf '%s' "$FINDINGS" | grep -c . || true)"
  capped="$(printf '%s' "$FINDINGS" | grep . | head -n "$MAXLINES")"
  extra=$(( total > MAXLINES ? total - MAXLINES : 0 ))
  [ "$extra" -gt 0 ] && capped="$capped"$'\n'"… (+$extra more issue(s))"
  emit_context "[per-edit checks] $REL — $total issue(s); fix before continuing:"$'\n'"$capped"
  write_record "$capped"
else
  clear_record
fi
[ -n "$SKIPS" ] && printf '[lint-feedback] %s' "$SKIPS" >&2
exit 0
