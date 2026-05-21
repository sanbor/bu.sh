#!/usr/bin/env bash
# Test suite for bu.sh. Each test runs in an isolated $HOME.
# Run: ./test_bu.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BU="$SCRIPT_DIR/bu.sh"
TODAY="$(date +%F)"

PASS=0
FAIL=0
FAILED=()

setup() {
  TEST_HOME="$(mktemp -d)"
  TEST_OUTSIDE="$(mktemp -d)"
  export HOME="$TEST_HOME"
}

teardown() {
  cd /
  rm -rf "$TEST_HOME" "$TEST_OUTSIDE"
}

run_bu() {
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  BU_RC=0
  "$BU" "$@" >"$out_file" 2>"$err_file" || BU_RC=$?
  BU_OUT=$(<"$out_file")
  BU_ERR=$(<"$err_file")
  rm -f "$out_file" "$err_file"
}

run_cmd() {
  # Same capture pattern but invokes any executable (e.g. a symlink to bu.sh).
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  BU_RC=0
  "$@" >"$out_file" 2>"$err_file" || BU_RC=$?
  BU_OUT=$(<"$out_file")
  BU_ERR=$(<"$err_file")
  rm -f "$out_file" "$err_file"
}

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "    assert_eq failed" >&2
    echo "      expected: $2" >&2
    echo "      actual:   $1" >&2
    return 1
  fi
}

assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    echo "    assert_contains failed" >&2
    echo "      needle: $2" >&2
    echo "      in:     $1" >&2
    return 1
  fi
}

assert_not_contains() {
  if [[ "$1" == *"$2"* ]]; then
    echo "    assert_not_contains failed" >&2
    echo "      forbidden: $2" >&2
    echo "      in:        $1" >&2
    return 1
  fi
}

assert_file() {
  if [[ ! -e "$1" ]]; then
    echo "    assert_file failed: $1 does not exist" >&2
    return 1
  fi
}

assert_not_file() {
  if [[ -e "$1" ]]; then
    echo "    assert_not_file failed: $1 should not exist" >&2
    return 1
  fi
}

assert_symlink() {
  if [[ ! -L "$1" ]]; then
    echo "    assert_symlink failed: $1 is not a symlink" >&2
    return 1
  fi
}

run_test() {
  local name=$1
  setup
  if "$name"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED+=("$name")
    echo "  FAIL  $name"
  fi
  teardown
}

# Last-resort cleanup: if the script aborts (set -e, exit, signal) mid-test,
# the per-test teardown never runs. Wipe whatever the current setup created.
cleanup_on_exit() {
  cd /
  [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
  [[ -n "${TEST_OUTSIDE:-}" && -d "$TEST_OUTSIDE" ]] && rm -rf "$TEST_OUTSIDE"
  return 0
}
trap cleanup_on_exit EXIT

test_no_args_exits_2() {
  run_bu
  assert_eq "$BU_RC" "2" || return 1
  assert_contains "$BU_ERR" "usage" || return 1
}

test_too_many_args_exits_2() {
  run_bu a b
  assert_eq "$BU_RC" "2" || return 1
}

test_missing_source_exits_1() {
  run_bu "$TEST_HOME/nope"
  assert_eq "$BU_RC" "1" || return 1
  assert_contains "$BU_ERR" "not found" || return 1
}

test_copies_directory_under_home() {
  mkdir -p "$HOME/.claude"
  echo hello > "$HOME/.claude/a.txt"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1
  local dest="$HOME/.backups/backups/$(slug_of "$HOME/.claude")/$TODAY/.claude/a.txt"
  assert_file "$dest" || return 1
  assert_eq "$(cat "$dest")" "hello" || return 1
}

test_copies_single_file() {
  echo content > "$HOME/note.txt"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/note.txt")/$TODAY/note.txt" || return 1
}

test_slug_for_nested_home_path() {
  mkdir -p "$HOME/repos/bu-command"
  touch "$HOME/repos/bu-command/x"
  run_bu "$HOME/repos/bu-command"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/repos/bu-command")/$TODAY/bu-command/x" || return 1
}

# Compute the expected slug. Mirrors make_slug in bu.sh exactly.
# Per segment: % -> %25; leading and trailing runs of - -> %2D each;
# remaining internal - doubles to --; based on the original first character,
# . -> _ and _ -> prefix one extra _. Segments joined with -.
expected_slug() {
  local path="$1"
  local IFS=/
  local -a parts
  read -r -a parts <<< "$path"
  local out="" part first lead trail
  for part in "${parts[@]}"; do
    first="${part:0:1}"
    part="${part//%/%25}"
    lead=""
    while [[ "$part" == -* ]]; do
      lead="${lead}%2D"
      part="${part#-}"
    done
    trail=""
    while [[ "$part" == *- ]]; do
      trail="%2D${trail}"
      part="${part%-}"
    done
    part="${part//-/--}"
    part="${lead}${part}${trail}"
    case "$first" in
      .) part="_${part#.}" ;;
      _) part="_${part}" ;;
    esac
    out="${out:+$out-}$part"
  done
  printf '%s' "$out"
}

# Slug for an absolute path: strip the leading / and apply expected_slug.
slug_of() {
  expected_slug "${1#/}"
}

test_slug_for_path_outside_home() {
  echo data > "$TEST_OUTSIDE/file"
  run_bu "$TEST_OUTSIDE/file"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$TEST_OUTSIDE/file")/$TODAY/file" || return 1
}

test_tilde_in_arg_is_expanded() {
  mkdir -p "$HOME/.claude"
  touch "$HOME/.claude/a"
  run_bu "~/.claude"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/.claude")/$TODAY/.claude/a" || return 1
}

test_collision_appends_counter() {
  mkdir -p "$HOME/.claude"
  echo v1 > "$HOME/.claude/a.txt"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1

  echo v2 > "$HOME/.claude/a.txt"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1

  echo v3 > "$HOME/.claude/a.txt"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1

  local root="$HOME/.backups/backups/$(slug_of "$HOME/.claude")"
  assert_eq "$(cat "$root/$TODAY/.claude/a.txt")" "v1" || return 1
  assert_eq "$(cat "$root/$TODAY-2/.claude/a.txt")" "v2" || return 1
  assert_eq "$(cat "$root/$TODAY-3/.claude/a.txt")" "v3" || return 1
}

test_does_not_modify_or_remove_source() {
  mkdir -p "$HOME/.claude"
  echo keep > "$HOME/.claude/a.txt"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.claude/a.txt" || return 1
  assert_eq "$(cat "$HOME/.claude/a.txt")" "keep" || return 1
}

test_preserves_file_mode() {
  echo x > "$HOME/script.sh"
  chmod 755 "$HOME/script.sh"
  run_bu "$HOME/script.sh"
  assert_eq "$BU_RC" "0" || return 1
  local dest="$HOME/.backups/backups/$(slug_of "$HOME/script.sh")/$TODAY/script.sh"
  assert_file "$dest" || return 1
  local mode
  mode="$(stat -f '%Lp' "$dest" 2>/dev/null || stat -c '%a' "$dest")"
  assert_eq "$mode" "755" || return 1
}

test_prints_destination_path() {
  echo x > "$HOME/note.txt"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$BU_OUT" "$HOME/.backups/backups/$(slug_of "$HOME/note.txt")/$TODAY/note.txt" || return 1
}

test_relative_path_resolves_to_absolute() {
  mkdir -p "$HOME/work"
  echo x > "$HOME/work/file"
  cd "$HOME/work"
  run_bu "file"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/work/file")/$TODAY/file" || return 1
}

# --- new tests below ---

test_help_short_flag_exits_0() {
  run_bu -h
  assert_eq "$BU_RC" "0" || return 1
  assert_contains "$BU_OUT" "usage" || return 1
}

test_help_long_flag_exits_0() {
  run_bu --help
  assert_eq "$BU_RC" "0" || return 1
  assert_contains "$BU_OUT" "usage" || return 1
}

test_path_with_spaces_in_name() {
  mkdir -p "$HOME/dir with space"
  echo hi > "$HOME/dir with space/note.txt"
  run_bu "$HOME/dir with space/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  local dest="$HOME/.backups/backups/$(slug_of "$HOME/dir with space/note.txt")/$TODAY/note.txt"
  assert_file "$dest" || return 1
  assert_eq "$(cat "$dest")" "hi" || return 1
}

test_slug_dash_in_segment() {
  # ~/foo-bar (file with a literal dash) and ~/foo/bar (file inside dir)
  # used to collide under the old slug rule. The new injective encoding
  # doubles internal dashes, so both sources back up to distinct folders.
  mkdir -p "$HOME/foo"
  echo from_dir > "$HOME/foo/bar"
  echo from_file > "$HOME/foo-bar"

  run_bu "$HOME/foo-bar"
  assert_eq "$BU_RC" "0" || return 1
  run_bu "$HOME/foo/bar"
  assert_eq "$BU_RC" "0" || return 1

  local file_slug="$(slug_of "$HOME/foo-bar")"
  local dir_slug="$(slug_of "$HOME/foo/bar")"
  if [[ "$file_slug" == "$dir_slug" ]]; then
    echo "    slugs collided: $file_slug" >&2
    return 1
  fi
  assert_eq "$(cat "$HOME/.backups/backups/$file_slug/$TODAY/foo-bar")" "from_file" || return 1
  assert_eq "$(cat "$HOME/.backups/backups/$dir_slug/$TODAY/bar")" "from_dir" || return 1
}

test_slug_leading_underscore() {
  # ~/_x and ~/.x used to collide under the old slug rule (both -> _x).
  # The new encoding doubles a leading literal _ so the two sources land
  # in distinct folders.
  echo from_under > "$HOME/_x"
  echo from_dot > "$HOME/.x"

  run_bu "$HOME/_x"
  assert_eq "$BU_RC" "0" || return 1
  run_bu "$HOME/.x"
  assert_eq "$BU_RC" "0" || return 1

  local under_slug="$(slug_of "$HOME/_x")"
  local dot_slug="$(slug_of "$HOME/.x")"
  if [[ "$under_slug" == "$dot_slug" ]]; then
    echo "    slugs collided: $under_slug" >&2
    return 1
  fi
  assert_eq "$(cat "$HOME/.backups/backups/$under_slug/$TODAY/_x")" "from_under" || return 1
  assert_eq "$(cat "$HOME/.backups/backups/$dot_slug/$TODAY/.x")" "from_dot" || return 1
}

test_slug_dash_at_segment_boundary() {
  # ~/foo/-bar (literal - at start of segment) and ~/foo-/bar (literal -
  # at end of segment) would also collide if the encoder only doubled
  # dashes. Boundary dashes must percent-escape so the two stay distinct.
  mkdir -p "$HOME/foo" "$HOME/foo-"
  echo at_start > "$HOME/foo/-bar"
  echo at_end > "$HOME/foo-/bar"

  run_bu "$HOME/foo/-bar"
  assert_eq "$BU_RC" "0" || return 1
  run_bu "$HOME/foo-/bar"
  assert_eq "$BU_RC" "0" || return 1

  local start_slug="$(slug_of "$HOME/foo/-bar")"
  local end_slug="$(slug_of "$HOME/foo-/bar")"
  if [[ "$start_slug" == "$end_slug" ]]; then
    echo "    slugs collided: $start_slug" >&2
    return 1
  fi
  assert_eq "$(cat "$HOME/.backups/backups/$start_slug/$TODAY/-bar")" "at_start" || return 1
  assert_eq "$(cat "$HOME/.backups/backups/$end_slug/$TODAY/bar")" "at_end" || return 1
}

test_slug_percent_in_segment() {
  # Literal % must be escaped to %25 so it cannot be confused with the
  # %2D / %5F escapes the encoder uses for boundary dashes.
  echo data > "$HOME/a%b"
  run_bu "$HOME/a%b"
  assert_eq "$BU_RC" "0" || return 1
  local dest="$HOME/.backups/backups/$(slug_of "$HOME/a%b")/$TODAY/a%b"
  assert_file "$dest" || return 1
  # Sanity: the slug actually contains the percent escape.
  assert_contains "$(slug_of "$HOME/a%b")" "a%25b" || return 1
}

test_same_source_twice_lands_in_one_slug() {
  echo a > "$HOME/note.txt"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  echo b > "$HOME/note.txt"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  local root="$HOME/.backups/backups/$(slug_of "$HOME/note.txt")"
  assert_file "$root/$TODAY/note.txt" || return 1
  assert_file "$root/$TODAY-2/note.txt" || return 1
}

test_program_name_via_symlink_uses_argv0() {
  ln -s "$BU" "$HOME/bu"
  run_cmd "$HOME/bu"
  assert_eq "$BU_RC" "2" || return 1
  assert_contains "$BU_ERR" "usage" || return 1
  # Error must not refer to "bu.sh" when invoked as "bu".
  assert_not_contains "$BU_ERR" "bu.sh" || return 1
}

test_symlink_source_is_preserved_as_link() {
  echo target > "$HOME/target.txt"
  ln -s "$HOME/target.txt" "$HOME/link.txt"
  run_bu "$HOME/link.txt"
  assert_eq "$BU_RC" "0" || return 1
  local dest="$HOME/.backups/backups/$(slug_of "$HOME/link.txt")/$TODAY/link.txt"
  assert_symlink "$dest" || return 1
}

test_pre_existing_today_dir_increments_counter_atomically() {
  # Pre-create the destination dir to simulate a concurrent write that
  # claimed the slot between -e and mkdir. Atomic mkdir-or-fail must skip
  # past it without clobbering.
  echo v1 > "$HOME/note.txt"
  local root="$HOME/.backups/backups/$(slug_of "$HOME/note.txt")"
  mkdir -p "$root/$TODAY"
  echo squatter > "$root/$TODAY/squatter"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  # The new backup must land in $TODAY-2, not inside the pre-existing dir.
  assert_file "$root/$TODAY-2/note.txt" || return 1
  assert_file "$root/$TODAY/squatter" || return 1
  assert_not_file "$root/$TODAY/note.txt" || return 1
}

# --- restore tests ---

# Seed a single snapshot directory under the slug for $HOME/note.txt with the
# given snapshot dir name and file content. Bypasses bu.sh so we can craft any
# date or counter cheaply.
seed_snapshot() {
  local slug=$1 snap=$2 base=$3 content=$4
  local dir="$HOME/.backups/backups/$slug/$snap"
  mkdir -p "$dir"
  printf '%s' "$content" > "$dir/$base"
}

test_restore_no_path_exits_2() {
  run_bu -r
  assert_eq "$BU_RC" "2" || return 1
  assert_contains "$BU_ERR" "usage" || return 1
}

test_restore_too_many_args_exits_2() {
  run_bu -r "$HOME/note.txt" 2026-05-13 extra
  assert_eq "$BU_RC" "2" || return 1
}

test_restore_no_backups_exits_1() {
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "1" || return 1
  assert_contains "$BU_ERR" "no backups" || return 1
}

test_restore_latest_when_no_date_given() {
  local slug; slug="$(slug_of "$HOME/note.txt")"
  seed_snapshot "$slug" 2026-05-10 note.txt v1
  seed_snapshot "$slug" 2026-05-11 note.txt v2
  seed_snapshot "$slug" 2026-05-13 note.txt v3
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/note.txt.restored" || return 1
  assert_eq "$(cat "$HOME/note.txt.restored")" "v3" || return 1
}

test_restore_latest_handles_double_digit_counter() {
  # Lexicographic sort would put "-9" after "-12". The picker must treat the
  # counter numerically.
  local slug; slug="$(slug_of "$HOME/note.txt")"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if (( i == 1 )); then
      seed_snapshot "$slug" 2026-05-13 note.txt "v$i"
    else
      seed_snapshot "$slug" "2026-05-13-$i" note.txt "v$i"
    fi
  done
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$(cat "$HOME/note.txt.restored")" "v12" || return 1
}

test_restore_specific_date_picks_latest_counter_of_that_day() {
  local slug; slug="$(slug_of "$HOME/note.txt")"
  seed_snapshot "$slug" 2026-05-13 note.txt v1
  seed_snapshot "$slug" 2026-05-13-2 note.txt v2
  seed_snapshot "$slug" 2026-05-13-3 note.txt v3
  seed_snapshot "$slug" 2026-05-14 note.txt v4
  run_bu -r "$HOME/note.txt" 2026-05-13
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$(cat "$HOME/note.txt.restored")" "v3" || return 1
}

test_restore_exact_dated_directory() {
  local slug; slug="$(slug_of "$HOME/note.txt")"
  seed_snapshot "$slug" 2026-05-13 note.txt v1
  seed_snapshot "$slug" 2026-05-13-2 note.txt v2
  seed_snapshot "$slug" 2026-05-13-3 note.txt v3
  run_bu -r "$HOME/note.txt" 2026-05-13-2
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$(cat "$HOME/note.txt.restored")" "v2" || return 1
}

test_restore_missing_date_exits_1() {
  seed_snapshot "$(slug_of "$HOME/note.txt")" 2026-05-13 note.txt v1
  run_bu -r "$HOME/note.txt" 2026-05-14
  assert_eq "$BU_RC" "1" || return 1
}

test_restore_destination_already_exists_exits_1() {
  seed_snapshot "$(slug_of "$HOME/note.txt")" 2026-05-13 note.txt v1
  echo keep > "$HOME/note.txt.restored"
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "1" || return 1
  assert_contains "$BU_ERR" "exists" || return 1
  # Existing file must be left alone.
  assert_eq "$(cat "$HOME/note.txt.restored")" "keep" || return 1
}

test_restore_does_not_modify_source() {
  echo live > "$HOME/note.txt"
  seed_snapshot "$(slug_of "$HOME/note.txt")" 2026-05-13 note.txt v1
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$(cat "$HOME/note.txt")" "live" || return 1
}

test_restore_directory_contents() {
  mkdir -p "$HOME/.claude"
  echo a > "$HOME/.claude/a.txt"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1
  run_bu -r "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1
  local rest="$HOME/.claude.restored"
  assert_file "$rest/a.txt" || return 1
  assert_eq "$(cat "$rest/a.txt")" "a" || return 1
}

test_restore_path_outside_home() {
  echo data > "$TEST_OUTSIDE/file"
  run_bu "$TEST_OUTSIDE/file"
  assert_eq "$BU_RC" "0" || return 1
  run_bu -r "$TEST_OUTSIDE/file"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$TEST_OUTSIDE/file.restored" || return 1
  assert_eq "$(cat "$TEST_OUTSIDE/file.restored")" "data" || return 1
}

test_restore_preserves_file_mode() {
  echo x > "$HOME/script.sh"
  chmod 755 "$HOME/script.sh"
  run_bu "$HOME/script.sh"
  assert_eq "$BU_RC" "0" || return 1
  run_bu -r "$HOME/script.sh"
  assert_eq "$BU_RC" "0" || return 1
  local mode
  mode="$(stat -f '%Lp' "$HOME/script.sh.restored" 2>/dev/null || stat -c '%a' "$HOME/script.sh.restored")"
  assert_eq "$mode" "755" || return 1
}

test_restore_prints_destination_path() {
  seed_snapshot "$(slug_of "$HOME/note.txt")" 2026-05-13 note.txt v1
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$BU_OUT" "$HOME/note.txt.restored" || return 1
}

test_restore_tilde_expansion() {
  seed_snapshot "$(slug_of "$HOME/note.txt")" 2026-05-13 note.txt v1
  run_bu -r "~/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/note.txt.restored" || return 1
}

test_restore_works_when_source_deleted() {
  echo live > "$HOME/note.txt"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  rm "$HOME/note.txt"
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/note.txt.restored" || return 1
  assert_eq "$(cat "$HOME/note.txt.restored")" "live" || return 1
}

test_restore_long_flag() {
  seed_snapshot "$(slug_of "$HOME/note.txt")" 2026-05-13 note.txt v1
  run_bu --restore "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/note.txt.restored" || return 1
}

test_help_mentions_restore() {
  run_bu --help
  assert_eq "$BU_RC" "0" || return 1
  assert_contains "$BU_OUT" "--restore" || return 1
}

test_pick_latest_ignores_non_snapshot_dirs() {
  # A stray directory (e.g. left by a manual cp) must not be picked or
  # interfere with sorting.
  local slug; slug="$(slug_of "$HOME/note.txt")"
  seed_snapshot "$slug" 2026-05-13 note.txt v1
  mkdir -p "$HOME/.backups/backups/$slug/scratch"
  echo junk > "$HOME/.backups/backups/$slug/scratch/x"
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_eq "$(cat "$HOME/note.txt.restored")" "v1" || return 1
}

test_pick_latest_no_snapshots_when_only_junk() {
  local slug; slug="$(slug_of "$HOME/note.txt")"
  mkdir -p "$HOME/.backups/backups/$slug/scratch"
  run_bu -r "$HOME/note.txt"
  assert_eq "$BU_RC" "1" || return 1
  assert_contains "$BU_ERR" "no snapshots" || return 1
}

test_backup_basename_starting_with_dash() {
  # A source whose basename starts with "-" must not be parsed as a flag by
  # cp or basename. The slug also exercises a leading-dash component.
  echo data > "$TEST_OUTSIDE/-weird"
  run_bu "$TEST_OUTSIDE/-weird"
  assert_eq "$BU_RC" "0" || return 1
  local dest="$HOME/.backups/backups/$(slug_of "$TEST_OUTSIDE/-weird")/$TODAY/-weird"
  assert_file "$dest" || return 1
  assert_eq "$(cat "$dest")" "data" || return 1
}

test_backup_dir_is_not_world_readable() {
  # Backups may contain sensitive paths or content. The snapshot directory
  # itself must not leak read access to other users.
  echo secret > "$HOME/secret.txt"
  run_bu "$HOME/secret.txt"
  assert_eq "$BU_RC" "0" || return 1
  local snap="$HOME/.backups/backups/$(slug_of "$HOME/secret.txt")/$TODAY"
  local mode
  mode="$(stat -f '%Lp' "$snap" 2>/dev/null || stat -c '%a' "$snap")"
  # Other-bits must be zero.
  if [[ "${mode: -1}" != "0" ]]; then
    echo "    snapshot dir mode is $mode (other bits set)" >&2
    return 1
  fi
}

test_slug_keeps_internal_dots() {
  # Dots that are not the first character of a path segment are preserved.
  mkdir -p "$HOME/notes"
  echo x > "$HOME/notes/Q2.md"
  run_bu "$HOME/notes/Q2.md"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/notes/Q2.md")/$TODAY/Q2.md" || return 1
}

test_slug_replaces_leading_dot_with_underscore() {
  # The leading "." of a hidden segment becomes "_" in the slug.
  mkdir -p "$HOME/.claude"
  echo x > "$HOME/.claude/a"
  run_bu "$HOME/.claude"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/.claude")/$TODAY/.claude/a" || return 1
}

test_slug_rewrites_each_hidden_segment() {
  # Every segment that starts with "." gets the rewrite, not just the first.
  mkdir -p "$HOME/.config"
  echo x > "$HOME/.config/.vimrc"
  run_bu "$HOME/.config/.vimrc"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/.config/.vimrc")/$TODAY/.vimrc" || return 1
}

test_slug_keeps_dots_inside_hidden_dir() {
  # A hidden directory keeps internal dots in later segments.
  mkdir -p "$HOME/.config/fish"
  echo x > "$HOME/.config/fish/config.fish"
  run_bu "$HOME/.config/fish/config.fish"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/.config/fish/config.fish")/$TODAY/config.fish" || return 1
}

test_slug_uses_full_absolute_path_for_home_paths() {
  # Pin the no-special-case-for-HOME rule. The slug must include the
  # absolute prefix, never the bare basename of a HOME-relative segment.
  echo x > "$HOME/note.txt"
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  assert_file "$HOME/.backups/backups/$(slug_of "$HOME/note.txt")/$TODAY/note.txt" || return 1
  assert_not_file "$HOME/.backups/backups/note.txt" || return 1
}

test_tilde_and_absolute_produce_same_slug() {
  # The same physical file, addressed two ways, must land in one slug.
  echo x > "$HOME/note.txt"
  run_bu "~/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  run_bu "$HOME/note.txt"
  assert_eq "$BU_RC" "0" || return 1
  local root="$HOME/.backups/backups/$(slug_of "$HOME/note.txt")"
  assert_file "$root/$TODAY/note.txt" || return 1
  assert_file "$root/$TODAY-2/note.txt" || return 1
}

main() {
  echo "Running test suite for $BU"
  run_test test_no_args_exits_2
  run_test test_too_many_args_exits_2
  run_test test_missing_source_exits_1
  run_test test_copies_directory_under_home
  run_test test_copies_single_file
  run_test test_slug_for_nested_home_path
  run_test test_slug_for_path_outside_home
  run_test test_tilde_in_arg_is_expanded
  run_test test_collision_appends_counter
  run_test test_does_not_modify_or_remove_source
  run_test test_preserves_file_mode
  run_test test_prints_destination_path
  run_test test_relative_path_resolves_to_absolute
  run_test test_help_short_flag_exits_0
  run_test test_help_long_flag_exits_0
  run_test test_path_with_spaces_in_name
  run_test test_slug_dash_in_segment
  run_test test_slug_leading_underscore
  run_test test_slug_dash_at_segment_boundary
  run_test test_slug_percent_in_segment
  run_test test_same_source_twice_lands_in_one_slug
  run_test test_program_name_via_symlink_uses_argv0
  run_test test_symlink_source_is_preserved_as_link
  run_test test_pre_existing_today_dir_increments_counter_atomically
  run_test test_restore_no_path_exits_2
  run_test test_restore_too_many_args_exits_2
  run_test test_restore_no_backups_exits_1
  run_test test_restore_latest_when_no_date_given
  run_test test_restore_latest_handles_double_digit_counter
  run_test test_restore_specific_date_picks_latest_counter_of_that_day
  run_test test_restore_exact_dated_directory
  run_test test_restore_missing_date_exits_1
  run_test test_restore_destination_already_exists_exits_1
  run_test test_restore_does_not_modify_source
  run_test test_restore_directory_contents
  run_test test_restore_path_outside_home
  run_test test_restore_preserves_file_mode
  run_test test_restore_prints_destination_path
  run_test test_restore_tilde_expansion
  run_test test_restore_works_when_source_deleted
  run_test test_restore_long_flag
  run_test test_help_mentions_restore
  run_test test_pick_latest_ignores_non_snapshot_dirs
  run_test test_pick_latest_no_snapshots_when_only_junk
  run_test test_backup_basename_starting_with_dash
  run_test test_backup_dir_is_not_world_readable
  run_test test_slug_keeps_internal_dots
  run_test test_slug_replaces_leading_dot_with_underscore
  run_test test_slug_rewrites_each_hidden_segment
  run_test test_slug_keeps_dots_inside_hidden_dir
  run_test test_slug_uses_full_absolute_path_for_home_paths
  run_test test_tilde_and_absolute_produce_same_slug

  echo
  echo "Results: $PASS passed, $FAIL failed"
  if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
}

main "$@"
