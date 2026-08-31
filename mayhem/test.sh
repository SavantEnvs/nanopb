#!/usr/bin/env bash
#
# mayhem/test.sh — RUN nanopb's own unit test suite (already built by mayhem/build.sh into
# tests/build-test/*/{decode,encode,common}_unittests). exit 0 = pass.
#
# These are nanopb's REAL known-answer tests: each TEST(expr) macro (tests/common/unittests.h)
# prints "OK: <expr>" to stdout on success or "FAILED: file:line <expr>" to stderr on failure, and
# the binary's own main() returns nonzero iff any assertion failed. Crucially the binaries are
# DYNAMICALLY linked (build.sh asserts this) and print NOTHING until their own main() runs — so if
# the program is neutered (e.g. an LD_PRELOAD constructor that _exit(0)s before main), stdout is
# completely empty and the OK-line count collapses to 0, which this script treats as a hard FAIL.
# That is the point: we assert the exact expected count of behavioral assertions, not just "did the
# binary exit 0" (a no-op/exit(0) program would trivially "pass" an exit-code-only check).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TEST_BUILDDIR="tests/build-test"
declare -A EXPECTED=( [decode_unittests]=109 [encode_unittests]=90 [common_unittests]=112 )

total_expected=0
total_ok=0
total_bad=0
any_missing=0

for t in decode_unittests encode_unittests common_unittests; do
  bin="$TEST_BUILDDIR/$t/$t"
  exp="${EXPECTED[$t]}"
  total_expected=$(( total_expected + exp ))

  if [ ! -x "$bin" ]; then
    echo "FATAL: $bin missing or not executable — mayhem/build.sh must build it" >&2
    any_missing=1
    total_bad=$(( total_bad + exp ))
    continue
  fi

  out="$("$bin" 2>&1)"; rc=$?
  printf '%s\n' "$out"

  # unanchored + no trailing space: each success line is
  # "\033[32;1mOK:\033[22;39m <expr>" — an ANSI color escape sits between "OK:" and the expr, so
  # the line does NOT start with the literal bytes "OK: " (it starts with ESC[32;1m).
  ok=$(printf '%s\n' "$out" | grep -c 'OK:' || true)
  # Never let a stray extra "OK:" line (or a miscount) inflate the pass total past what this binary
  # can legitimately produce.
  [ "$ok" -gt "$exp" ] && ok="$exp"
  bad=$(( exp - ok ))
  # A nonzero exit with an apparently-full OK count still counts as at least one failure — the
  # binary's own main() only returns nonzero when a TEST() actually failed.
  if [ "$rc" -ne 0 ] && [ "$bad" -eq 0 ]; then
    bad=1
  fi

  echo "$t: $ok/$exp assertions OK (rc=$rc)"
  total_ok=$(( total_ok + ok ))
  total_bad=$(( total_bad + bad ))
done

if [ "$any_missing" -eq 1 ]; then
  emit_ctrf "nanopb-unittests" 0 "$total_expected"
  exit 1
fi

emit_ctrf "nanopb-unittests" "$total_ok" "$total_bad"
