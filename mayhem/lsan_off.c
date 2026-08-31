/* mayhem/lsan_off.c
 *
 * Fleet policy: disable LeakSanitizer at build/link time for every ASan-built target, proactively —
 * not just once a leak defect is found. Leaks aren't the bug class this fleet fuzzes for; ASan's own
 * memory-corruption checks and UBSan stay fully active — only leak detection is affected.
 *
 * Plain C (no `extern "C"` needed: a .c file has no name mangling to begin with) because the
 * harness this hook is linked into (tests/fuzztest/fuzztest.c) and the nanopb library itself are
 * both C, built with $CC — see mayhem/build.sh.
 */
int __lsan_is_turned_off(void) {
    return 1;
}
