#!/usr/bin/env bash
set -euo pipefail

# Backup paths and contents may be sensitive (config files, secrets, full
# trees from $HOME). Tighten the umask so newly created snapshot directories
# are not world/group-readable. cp -a still preserves the source modes for
# the copied payload itself.
umask 077

prog="${0##*/}"

# Build a slug from a relative path. Distinct paths always produce distinct
# slugs. Per segment, in order:
#   1. % -> %25 (escape the escape character first).
#   2. Each - in the leading run and the trailing run -> %2D.
#   3. Each remaining internal - -> -- (doubled).
#   4. Based on the original first character of the segment:
#        . -> _   (existing leading-dot rewrite)
#        _ -> prefix one extra _   (so _x becomes __x, __x becomes ___x)
# Segments are then joined with -. A single - in the slug is therefore
# always a separator: encoded segments never start or end with - (boundary
# dashes are percent-escaped), so a run of - of length >= 2 is always an
# even number of internal-doubled dashes.
make_slug() {
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

usage() {
  cat <<EOF
usage: $prog <path>
       $prog -r | --restore <path> [date]
       $prog -h | --help

Backup form copies <path> into
  ~/.backups/backups/<slug>/<YYYY-MM-DD>[-N]/<basename>.
Restore form copies a snapshot back to <path>.restored.
The source is never modified or removed.

Slug rule:
  Resolve <path> to its absolute path, remove the leading /, and split on /.
  Per segment: % -> %25; dashes in the leading and trailing runs -> %2D;
  remaining internal dashes are doubled (- -> --). Based on the original
  first character: . -> _ (so ".claude" becomes "_claude"); _ gets an extra
  leading _ (so "_x" becomes "__x"). Segments are then joined with -.
  The encoding is injective, so distinct paths always produce distinct
  slugs. Example: ~/.claude with $HOME=/Users/you slugs to
  "Users-you-_claude".

Restore date:
  Omitted     latest snapshot for the slug (newest day, highest counter).
  YYYY-MM-DD  latest snapshot taken on that day.
  YYYY-MM-DD-N  exact snapshot directory.
The source path itself need not exist; only its parent directory.
The destination is <path>.restored. If it already exists, restore
refuses (no overwrite, no counter).

Tilde:
  ~ is expanded; ~user is not.

Symlinks:
  cp -a preserves them. The backup of a symlink is a symlink.

Exit codes:
  0  backup or restore written
  1  source/parent unresolvable, no backups, missing date,
     or restore destination already exists
  2  argument error
EOF
}

if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -ge 1 && ( "$1" == "-r" || "$1" == "--restore" ) ]]; then
  shift
  [[ $# -eq 1 || $# -eq 2 ]] || { echo "usage: $prog -r <path> [date]" >&2; exit 2; }

  src_raw="${1/#\~/$HOME}"
  date_arg="${2:-}"

  src_dir="$(cd "$(dirname "$src_raw")" 2>/dev/null && pwd)" || {
    echo "$prog: cannot resolve directory for: $src_raw" >&2
    exit 1
  }
  src="$src_dir/$(basename "$src_raw")"

  rel="${src#/}"
  slug="$(make_slug "$rel")"
  root="$HOME/.backups/backups/$slug"
  [[ -d "$root" ]] || { echo "$prog: no backups for $src" >&2; exit 1; }

  # Pick the snapshot directory whose name has the largest (date, counter) key,
  # optionally restricted to a date prefix. Lexicographic sort breaks for
  # counters above 9 (e.g. -10 < -2), so parse and compare numerically.
  pick_latest() {
    local prefix="$1"
    local best="" best_key=""
    local entry name date_part counter key
    for entry in "$root"/*/; do
      [[ -d "$entry" ]] || continue
      name="${entry%/}"
      name="${name##*/}"
      if [[ "$name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})(-([0-9]+))?$ ]]; then
        date_part="${BASH_REMATCH[1]}"
        counter="${BASH_REMATCH[3]:-1}"
        if [[ -n "$prefix" && "$date_part" != "$prefix" ]]; then
          continue
        fi
        key="$(printf '%s-%05d' "$date_part" "$counter")"
        if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
          best_key="$key"
          best="$name"
        fi
      fi
    done
    printf '%s' "$best"
  }

  if [[ -z "$date_arg" ]]; then
    snap_name="$(pick_latest "")"
    [[ -n "$snap_name" ]] || { echo "$prog: no snapshots in $root" >&2; exit 1; }
  elif [[ "$date_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    snap_name="$(pick_latest "$date_arg")"
    [[ -n "$snap_name" ]] || { echo "$prog: no snapshot for date $date_arg in $root" >&2; exit 1; }
  else
    snap_name="$date_arg"
    [[ -d "$root/$snap_name" ]] || { echo "$prog: no backup at $root/$snap_name" >&2; exit 1; }
  fi

  base="$(basename "$src")"
  payload="$root/$snap_name/$base"
  [[ -e "$payload" ]] || { echo "$prog: snapshot missing: $payload" >&2; exit 1; }

  dest="$src.restored"
  [[ ! -e "$dest" ]] || { echo "$prog: destination exists: $dest" >&2; exit 1; }

  cp -a "$payload" "$dest"
  echo "$dest"
  exit 0
fi

[[ $# -eq 1 ]] || { echo "usage: $prog <path>" >&2; exit 2; }

src_raw="${1/#\~/$HOME}"
[[ -e "$src_raw" ]] || { echo "$prog: not found: $src_raw" >&2; exit 1; }

src_dir="$(cd "$(dirname "$src_raw")" 2>/dev/null && pwd)" || {
  echo "$prog: cannot resolve directory for: $src_raw" >&2
  exit 1
}
src="$src_dir/$(basename "$src_raw")"

rel="${src#/}"
slug="$(make_slug "$rel")"

today="$(date +%F)"
root="$HOME/.backups/backups/$slug"
mkdir -p "$root"

n=1
while :; do
  if (( n == 1 )); then
    dest="$root/$today"
  else
    dest="$root/$today-$n"
  fi
  if mkdir "$dest" 2>/dev/null; then
    break
  fi
  n=$((n+1))
  if (( n > 1000 )); then
    echo "$prog: cannot allocate destination in $root" >&2
    exit 1
  fi
done

cp -a "$src" "$dest/"
echo "$dest/$(basename "$src")"
