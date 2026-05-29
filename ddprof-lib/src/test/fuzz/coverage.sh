#!/usr/bin/env bash
#
# Source-based code-coverage for the libFuzzer harnesses.
#
# Builds every fuzz_*.cpp target with clang coverage instrumentation
# (-fprofile-instr-generate -fcoverage-mapping), replays each target's corpus
# (or fuzzes it for a while), then produces an llvm-cov report + browsable HTML.
#
# Usage:
#   coverage.sh [duration_seconds]
#     duration_seconds = 0  -> replay the existing corpus once (default, fast)
#                      > 0  -> fuzz each target for that long first (discovers
#                              newly-reachable paths before measuring)
#
# Env overrides: CXX, LLVM_COV, LLVM_PROFDATA, JAVA_HOME (required).
#
# Invoked by the Gradle task :ddprof-lib:fuzz:fuzzCoverage
# (pass -Pfuzz-cov-duration=N to set the duration).
set -euo pipefail

DURATION="${1:-0}"
CXX="${CXX:-clang++}"
LLVM_COV="${LLVM_COV:-llvm-cov}"
LLVM_PROFDATA="${LLVM_PROFDATA:-llvm-profdata}"

# Resolve the repo root from this script's location: <root>/ddprof-lib/src/test/fuzz/coverage.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/../../../.." && pwd)"
SRC="$ROOT/ddprof-lib/src/main/cpp"
FUZZ="$ROOT/ddprof-lib/src/test/fuzz"
CORPUS="$FUZZ/corpus"
COV="$ROOT/ddprof-lib/fuzz/build/coverage"
OBJ="$COV/obj"; BIN="$COV/bin"; PROF="$COV/prof"; HTML="$COV/html"

for tool in "$CXX" "$LLVM_COV" "$LLVM_PROFDATA"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found in PATH"; exit 1; }
done
[ -n "${JAVA_HOME:-}" ] || { echo "ERROR: JAVA_HOME must be set"; exit 1; }

mkdir -p "$OBJ" "$BIN" "$PROF" "$HTML"

case "$(uname -s)" in
  Linux)  PLAT_INC="linux";  EXTRA_LIBS=(-ldl -lpthread -lm -lrt) ;;
  Darwin) PLAT_INC="darwin"; EXTRA_LIBS=(-ldl -lpthread -lm) ;;
  *) echo "ERROR: unsupported platform $(uname -s)"; exit 1 ;;
esac

INCLUDES=(-I"$SRC" -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/$PLAT_INC"
          -I"$ROOT/malloc-shim/src/main/public")
COMMON=(-O1 -g -fno-omit-frame-pointer -fvisibility=hidden -std=c++17
        -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DPROFILER_VERSION="coverage"
        -fprofile-instr-generate -fcoverage-mapping)
SAN_OBJ=(-fsanitize=fuzzer-no-link,address,undefined)
SAN_LINK=(-fsanitize=fuzzer,address,undefined)
command -v ld.lld >/dev/null 2>&1 && SAN_LINK+=(-fuse-ld=lld)

# ---- 1. Compile shared profiler objects once -------------------------------
nsrc=$(find "$SRC" -name '*.cpp' | wc -l | tr -d ' ')
nobj=$(find "$OBJ" -name '*.o' ! -name 'harness_*.o' 2>/dev/null | wc -l | tr -d ' ')
if [ "$nobj" -lt "$nsrc" ]; then
  echo "==> Compiling $nsrc profiler sources with coverage instrumentation..."
  # None of these flags contain spaces, so a flat string that bash word-splits
  # inside the worker is sufficient (and simpler than exporting arrays).
  export CXX OBJ SRC
  export CFLAGS_STR="${COMMON[*]} ${SAN_OBJ[*]} ${INCLUDES[*]}"
  compile_one() {
    local f="$1"
    local o="$OBJ/$(echo "$f" | sed "s#$SRC/##; s#/#__#g; s#\.cpp#.o#")"
    "$CXX" $CFLAGS_STR -c "$f" -o "$o"
  }
  export -f compile_one
  find "$SRC" -name '*.cpp' | xargs -P"$(getconf _NPROCESSORS_ONLN)" -I{} bash -c 'compile_one "$@"' _ {}
else
  echo "==> Reusing $nobj already-compiled coverage objects (delete $OBJ to force rebuild)."
fi
mapfile -t POBJ < <(find "$OBJ" -name '*.o' ! -name 'harness_*.o')

# ---- 2. Per target: link, run corpus, per-target profile -------------------
declare -a NAMES=()
for harness in "$FUZZ"/fuzz_*.cpp; do
  full="$(basename "$harness" .cpp)"; name="${full#fuzz_}"; NAMES+=("$name")
  echo "==> [$name] link + $( [ "$DURATION" -gt 0 ] && echo "fuzz ${DURATION}s" || echo "replay corpus" )"
  "$CXX" "${COMMON[@]}" "${SAN_OBJ[@]}" "${INCLUDES[@]}" -c "$harness" -o "$COV/harness_$name.o"
  "$CXX" "${COMMON[@]}" "${SAN_LINK[@]}" "${POBJ[@]}" "$COV/harness_$name.o" "${EXTRA_LIBS[@]}" -o "$BIN/$name"

  corpus_dirs=()
  [ -d "$CORPUS/$name" ]      && corpus_dirs+=("$CORPUS/$name")
  [ -d "$CORPUS/$full" ]      && corpus_dirs+=("$CORPUS/$full")   # committed seeds (fuzz_<name>)
  run_args=("${corpus_dirs[@]}")
  if [ "$DURATION" -gt 0 ]; then run_args+=(-max_total_time="$DURATION"); else run_args+=(-runs=0); fi

  ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=0 \
  LLVM_PROFILE_FILE="$PROF/$name.profraw" \
    "$BIN/$name" "${run_args[@]}" >/dev/null 2>&1 || true
  "$LLVM_PROFDATA" merge -sparse "$PROF/$name.profraw" -o "$PROF/$name.profdata"
done

# ---- 3. Reports ------------------------------------------------------------
echo; echo "================= PER-TARGET COVERAGE (code under test) ================="
for name in "${NAMES[@]}"; do
  full="fuzz_$name"
  # Files under test = the local headers the harness #includes, plus matching .cpp
  mapfile -t hdrs < <(grep -oE '#include "[A-Za-z0-9_./]+\.h"' "$FUZZ/$full.cpp" | sed -E 's/#include "(.*)"/\1/' | sort -u)
  files=()
  for h in "${hdrs[@]}"; do
    [ -f "$SRC/$h" ] && files+=("$SRC/$h")
    [ -f "$SRC/${h%.h}.cpp" ] && files+=("$SRC/${h%.h}.cpp")
  done
  [ ${#files[@]} -eq 0 ] && files+=("$SRC")
  echo; echo "----- fuzz_$name -----"
  "$LLVM_COV" report "$BIN/$name" -instr-profile "$PROF/$name.profdata" "${files[@]}" 2>/dev/null \
    | sed "s#$SRC/##"
done

echo; echo "==> Merging all targets..."
"$LLVM_PROFDATA" merge -sparse "$PROF"/*.profraw -o "$COV/fuzz.profdata"
# HTML over the whole profiler, using one binary (all embed the same sources).
"$LLVM_COV" show "$BIN/${NAMES[0]}" -instr-profile "$COV/fuzz.profdata" \
  -format=html -output-dir="$HTML" -show-line-counts-or-regions "$SRC" >/dev/null 2>&1 || true
echo "==> HTML report: $HTML/index.html"
echo "==> Merged profile: $COV/fuzz.profdata"
