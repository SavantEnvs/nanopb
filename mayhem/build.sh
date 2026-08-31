#!/usr/bin/env bash
#
# mayhem/build.sh — build nanopb's fuzz harnesses + the oracle test build.
#
# nanopb IS an OSS-Fuzz project (google/oss-fuzz projects/nanopb/build.sh literally does
# `source $SRC/nanopb/tests/fuzztest/ossfuzz.sh`), so this reuses that in-tree harness verbatim
# rather than writing a new one: tests/fuzztest/fuzztest.c is compiled 5 ways (one per
# FUZZTEST_* #define) into the 5 real OSS-Fuzz targets:
#   fuzztest_proto2_static / fuzztest_proto2_pointer /
#   fuzztest_proto3_static / fuzztest_proto3_pointer / fuzztest_io_errors
# Each exercises pb_decode()/pb_decode_ex()/pb_encode() round-trips (+ a callback-decode path and
# IO-error injection) over nanopb's own alltypes_* protobuf schemas — the same schemas the upstream
# unit tests use, so it is a broad, representative harness, not a narrow one.
#
# Upstream builds this with scons (tests/SConstruct), which ALSO regenerates the *.pb.c message
# sources from *.proto via protoc + the in-tree nanopb generator — so building "the fuzz harness"
# here also builds "the library" (pb_encode.c/pb_decode.c/pb_common.c or their _with_malloc
# variants), and both get $SANITIZER_FLAGS + -fsanitize=fuzzer-no-link, so the fuzzed CODE is
# instrumented, not just the harness translation unit.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# exports the build contract: CC, CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS, SRC.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC/tests"

# NOTE: intentionally NOT passing scons -jN here. tests/site_scons/site_tools/nanopb.py's
# NanopbProto builder os.chdir()s straight into the (freshly-named, non-default) variant dir to
# invoke protoc; run in parallel that races the variant directory's own creation ("No such file or
# directory") the first time a non-default BUILDDIR is used. Upstream's own tests/fuzztest/ossfuzz.sh
# builds serially for the same reason. The project here is small enough that this costs seconds.

FUZZERS="fuzztest_proto2_static fuzztest_proto2_pointer fuzztest_proto3_static fuzztest_proto3_pointer fuzztest_io_errors"
FUZZ_BUILDDIR="build-fuzz"
TEST_BUILDDIR="build-test"

FUZZ_TARGETS=""
for f in $FUZZERS; do FUZZ_TARGETS="$FUZZ_TARGETS $FUZZ_BUILDDIR/fuzztest/$f"; done

# 1) The 5 libFuzzer targets — same shape as tests/fuzztest/ossfuzz.sh's own scons invocation
#    (LINK=$CXX because $LIB_FUZZING_ENGINE's libFuzzer runtime is C++ even though the harness and
#    nanopb itself are C). -fsanitize=fuzzer-no-link goes on EVERY compile (harness AND the library
#    objects scons pulls in for these targets) so SanCov coverage covers the fuzzed code, not just
#    fuzztest.c. $DEBUG_FLAGS is placed AFTER $SANITIZER_FLAGS so its -gdwarf-3 wins over any -g the
#    base/scons may add. NODEFARGS=1 stops scons injecting its own -Werror/UBSan defaults here (kept
#    for the oracle build below, where they belong).
# shellcheck disable=SC2086
scons BUILDDIR="$FUZZ_BUILDDIR" CC="$CC" CXX="$CXX" LINK="$CXX" \
      CCFLAGS="-Wall -Wextra -DLLVMFUZZER -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS" \
      CXXFLAGS="-Wall -Wextra -DLLVMFUZZER -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS" \
      NODEFARGS="1" \
      LINKFLAGS="-std=c++11 -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS" \
      LINKLIBS="$LIB_FUZZING_ENGINE" \
      $FUZZ_TARGETS

for f in $FUZZERS; do
    cp "$FUZZ_BUILDDIR/fuzztest/$f" "/mayhem/$f"
done

# 2) Standalone (non-fuzzer) reproducer. tests/fuzztest/fuzztest.c ships ITS OWN file-input driver
#    (see the `#ifndef LLVMFUZZER` block at the bottom of the file): built WITHOUT -DLLVMFUZZER its
#    main() reads one input from stdin and calls LLVMFuzzerTestOneInput exactly once — no libFuzzer
#    runtime needed, so we use that instead of $STANDALONE_FUZZ_MAIN (same idea, upstream-shipped).
#    With no FUZZTEST_* #define either, fuzztest.c enables ALL 5 test paths (its own default when
#    none are set — see the file's top), so this one binary exercises the harness's full surface —
#    reuses the "fuzz" scons Program tests/fuzztest/SConscript already defines (no source edits).
#    Still instrumented (fuzzer-no-link + ASan/UBSan) so a crash here reproduces the same defect
#    class the libFuzzer targets would find; just no -fsanitize=fuzzer main this time.
# shellcheck disable=SC2086
scons BUILDDIR="$FUZZ_BUILDDIR" CC="$CC" CXX="$CXX" LINK="$CXX" \
      CCFLAGS="-Wall -Wextra -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS" \
      CXXFLAGS="-Wall -Wextra -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS" \
      NODEFARGS="1" \
      LINKFLAGS="-std=c++11 -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS" \
      LINKLIBS="" \
      "$FUZZ_BUILDDIR/fuzztest/fuzztest"

cp "$FUZZ_BUILDDIR/fuzztest/fuzztest" /mayhem/fuzztest-standalone

# 3) Oracle/test build — nanopb's OWN unit test suite, with the project's NORMAL (unsanitized,
#    non-DWARF3-forced) flags, in a SEPARATE build dir so it doesn't disturb the sanitized fuzz
#    build above. No CCFLAGS/NODEFARGS override here on purpose: scons applies its own per-compiler
#    defaults (warnings-as-errors, clang's own opportunistic UBSan probe) exactly as `scons` alone
#    would for a developer — that is what makes it an honest, independent functional oracle.
#    decode_unittests / encode_unittests / common_unittests are nanopb's real known-answer test
#    programs (309 individual TEST()-macro assertions between them) — dynamically linked binaries
#    that print one "OK: <expr>" line per passing assertion and "FAILED: file:line <expr>" per
#    failing one; mayhem/test.sh counts these lines rather than trusting the exit code.
scons BUILDDIR="$TEST_BUILDDIR" CC="$CC" CXX="$CXX" \
      "$TEST_BUILDDIR/decode_unittests/decode_unittests" \
      "$TEST_BUILDDIR/encode_unittests/encode_unittests" \
      "$TEST_BUILDDIR/common_unittests/common_unittests"

for t in decode_unittests encode_unittests common_unittests; do
    f="file $TEST_BUILDDIR/$t/$t"
    $f | grep -q "dynamically linked" \
        || { echo "build.sh: $t is not dynamically linked (would defeat the sabotage oracle)" >&2; $f >&2; exit 1; }
done

echo "build.sh: done"
