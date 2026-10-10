#!/bin/sh
# Two complete, independently rooted disposable runs. No live model/service calls.
# Requires an exact committed source revision, private copied deps/tool caches, strace.
set -eu
: "${NANO_TEST_PAIR_ROOT:?}" "${NANO_TEST_PAIR_TMP:?}" "${NANO_TEST_REVISION:?}"
: "${NANO_TEST_DEPS_SOURCE:?}" "${NANO_TEST_MIX_SOURCE:?}" "${NANO_TEST_HEX_SOURCE:?}" "${NANO_TEST_STRACE:?}"
case "$NANO_TEST_REVISION" in *[!0-9a-f]*|'') exit 2;; esac
[ ${#NANO_TEST_REVISION} -eq 40 ]
[ ! -e "$NANO_TEST_PAIR_ROOT" ]
mkdir -p "$NANO_TEST_PAIR_ROOT" "$NANO_TEST_PAIR_TMP"
source=$(pwd)
run_one() (
  name=$1
  root="$NANO_TEST_PAIR_ROOT/$name"
  tmp=$(mktemp -d "$NANO_TEST_PAIR_TMP/$name-XXXXXXXX")
  mkdir -p "$root/tree" "$root/home" "$root/mix" "$root/hex"
  git -C "$source" archive "$NANO_TEST_REVISION" | tar -x -C "$root/tree"
  cp -RL "$NANO_TEST_DEPS_SOURCE" "$root/tree/deps"
  cp -RL "$NANO_TEST_MIX_SOURCE/." "$root/mix/"
  cp -RL "$NANO_TEST_HEX_SOURCE/." "$root/hex/"
  export MIX_ENV=test MIX_BUILD_ROOT="$root/build" MIX_BUILD_PATH="$root/build/test"
  export MIX_DEPS_PATH="$root/tree/deps" HOME="$root/home" MIX_HOME="$root/mix" HEX_HOME="$root/hex"
  export TMPDIR="$tmp" ERL_CRASH_DUMP="$root/crash.dump" ERL_FLAGS='+S 2:2'
  export PYTHONDONTWRITEBYTECODE=1 NANO_TEST_PRIVATE_ROOT="$root" NANO_TEST_PATH_REPORT="$root/paths.json"
  # Hostile inherited store overrides must be ignored by test runtime configuration.
  export NANO_SAFETY_DIR=/data/u02-forbidden-safety NANO_WEB_CACHE_DIR=/data/u02-forbidden-web
  cd "$root/tree"
  calls=$(python3 test/flywheel/u02/audit_writes.py --calls)
  printf '%s\n' "$NANO_TEST_REVISION" > "$root/revision.txt"
  printf '%s\n' "$tmp" > "$root/tmp.txt"
  # Include compilation/dependency outputs, application boot, all children and both suites.
  "$NANO_TEST_STRACE" -f -qq -yy -s 4096 -e "trace=$calls" -o "$root/writes.strace" \
    sh -c 'mix deps.compile && mix run --no-start test/flywheel/u02/run.exs --full && mix test --seed 17 && unset MIX_BUILD_PATH && NANO_SAFETY_BEAM_TEST=1 python3 -m unittest discover -s scripts/safety -p "test_*.py" -v' \
    > "$root/tests.log" 2>&1
  python3 test/flywheel/u02/audit_writes.py "$root/writes.strace" "$root/tree" "$root/writes.json" "$root" "$tmp" > "$root/audit.log"
)
run_one a & a=$!
run_one b & b=$!
result=0
wait "$a" || result=1
wait "$b" || result=1
exit "$result"
