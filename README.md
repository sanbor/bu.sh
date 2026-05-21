# bu.sh

bu.sh: bu is short for BackUp SHell script. Glorified `cp -a`.

`bu.sh <path>` copies any file or directory into a dated, slug-named folder under `~/.backups/`.

No dependencies beyond Bash and coreutils. The source is never moved or modified.

## Install

Clone the repo (or copy `bu.sh` anywhere on your `PATH`):

```bash
git clone https://github.com/sanbor/bu.sh ~/repos/bu.sh
chmod +x ~/repos/bu.sh
ln -s ~/repos/bu.sh/bu.sh ~/.local/bin/bush
```

## Synopsis

```
bu.sh <path>
bu.sh --restore <path> [date]
bu.sh --help
```

Exit codes:

| Code | Meaning                                                          |
|------|------------------------------------------------------------------|
| 0    | Backup or restore written (or help printed)                      |
| 1    | Source/parent unresolvable, slug collision, no backups for slug, |
|      | requested date not found, or restore destination already exists  |
| 2    | Wrong number of arguments                                        |

On success, the absolute path of the new copy (or restored file) is printed to stdout.

## Destination layout

```
~/.backups/backups/<slug>/<YYYY-MM-DD>[-N]/<basename of source>
```

(Today's date is used. `-N` is appended only on same-day collisions, starting at `-2`.)

## Slug rule

The slug is built from the source path:

1. Resolve the source to its absolute path and remove the leading `/`. Tilde and relative paths are expanded first, so `~/.claude` and `/Users/you/.claude` produce the same slug.
2. Split the result on `/`. Encode each segment in this order:
   1. `%` -> `%25` (escape the escape character first).
   2. Each `-` in the leading run and the trailing run of the segment -> `%2D`.
   3. Each remaining internal `-` -> `--` (doubled).
   4. Based on the original first character: `.` -> `_`, or `_` -> prefix one extra `_` (so `_x` becomes `__x`).
3. Join the encoded segments with `-`.

The encoding is injective: distinct paths always produce distinct slugs, so there is no separate collision-detection step. A single `-` in the slug is always a segment separator (encoded segments never start or end with `-`); runs of `-` of length two or more are always an even number from internal-dash doubling.

Examples (assuming `$HOME` is `/Users/you`):

| Source                       | Absolute path (leading `/` stripped) | Slug                                 |
|------------------------------|--------------------------------------|--------------------------------------|
| `~/.claude`                  | `Users/you/.claude`                  | `Users-you-_claude`                  |
| `~/.config/fish/config.fish` | `Users/you/.config/fish/config.fish` | `Users-you-_config-fish-config.fish` |
| `~/repos/bu-command`         | `Users/you/repos/bu-command`         | `Users-you-repos-bu--command`        |
| `~/notes/2026/Q2.md`         | `Users/you/notes/2026/Q2.md`         | `Users-you-notes-2026-Q2.md`         |
| `/etc/hosts`                 | `etc/hosts`                          | `etc-hosts`                          |
| `/var/log/system.log`        | `var/log/system.log`                 | `var-log-system.log`                 |
| `~/.config/.vimrc`           | `Users/you/.config/.vimrc`           | `Users-you-_config-_vimrc`           |
| `~/_x`                       | `Users/you/_x`                       | `Users-you-__x`                      |
| `~/foo/-bar`                 | `Users/you/foo/-bar`                 | `Users-you-foo-%2Dbar`               |
| `~/a%b`                      | `Users/you/a%b`                      | `Users-you-a%25b`                    |

## Why this encoding?

The natural first attempt is "literal `-` doubles to `--`, literal leading `_`
doubles to `__`" (readable, no percent escapes). That rule is ambiguous at
segment boundaries. Concrete counterexample:

- `~/foo/-bar` (file `-bar` inside `foo/`): segments `foo` and `-bar`.
  Encode literal `-` in `-bar` as `--bar`. Join with separator `-`:
  `foo` + `-` + `--bar` = `foo---bar`.
- `~/foo-/bar` (file `bar` inside `foo-/`): segments `foo-` and `bar`.
  Encode literal `-` in `foo-` as `foo--`. Join with `-`:
  `foo--` + `-` + `bar` = `foo---bar`.

Both produce `foo---bar`. When a literal `-` sits next to a separator `-`,
the run of three is parseable two ways.

Underscores are easier than dashes because `_` is not the separator, so
there is no boundary ambiguity to dodge. The symmetric "doubling first,
percent only when needed" rule for the leading character would be:

- Original segment starts with `.` -> rewrite to `_` (existing behavior).
- Original segment starts with `_` -> double the leading `_` to `__`.

So `.x` -> `_x`, `_x` -> `__x`, `__x` -> `___x`. All distinct, no percent
escapes needed for underscores.

Combined with the dash rule (percent at segment boundary, double internally),
the full per-segment encoding is:

1. `%` -> `%25`.
2. Leading and trailing runs of literal `-`: percent-encode each
   (`-` -> `%2D`).
3. Remaining internal `-`: double (`-` -> `--`).
4. Look at the ORIGINAL first character of the segment:
   - `.` -> `_`
   - `_` -> prefix one extra `_`
   - else: leave it.

Then join the encoded segments with `-`. Examples (`$HOME=/Users/you`):

```
~/.claude          -> Users-you-_claude
~/_x               -> Users-you-__x
~/.x               -> Users-you-_x
~/foo/bar          -> Users-you-foo-bar
~/foo-bar          -> Users-you-foo--bar         (internal -)
~/foo/-bar         -> Users-you-foo-%2Dbar       (- at segment start)
~/foo-/bar         -> Users-you-foo%2D-bar       (- at segment end)
~/foo--bar         -> Users-you-foo----bar       (internal --, doubled)
~/repos/bu-command -> Users-you-repos-bu--command
~/a%b              -> Users-you-a%25b
```

## Path resolution

Before computing the slug, `bu.sh` always resolves the input to an absolute
path: tilde at the start of the argument is expanded to `$HOME`, and a
relative path is joined with the current working directory. The slug rule
then runs on that absolute path. As a result, every way of naming the same
file produces the same slug, so a backup taken under one form can be
restored under another and same-day repeats stack as `-2`, `-3`, ... in one
slug folder rather than scattering.

Equivalent forms (with `$HOME` of `/Users/you`, current dir `~`):

| You typed                       | Resolved to            | Slug                |
|---------------------------------|------------------------|---------------------|
| `bu.sh ~/.claude`               | `/Users/you/.claude`   | `Users-you-_claude` |
| `bu.sh /Users/you/.claude`      | `/Users/you/.claude`   | `Users-you-_claude` |
| `bu.sh .claude`                 | `/Users/you/.claude`   | `Users-you-_claude` |
| `bu.sh ./.claude`               | `/Users/you/.claude`   | `Users-you-_claude` |

Worked examples of the slug rule itself:

- `~/.claude` resolves to `/Users/you/.claude`, strips to `Users/you/.claude`, slugs to `Users-you-_claude` (only the leading `.` of the last segment is rewritten).
- `~/.config/fish/config.fish` resolves to `/Users/you/.config/fish/config.fish`, slugs to `Users-you-_config-fish-config.fish` (the inner `.` in `config.fish` survives because it is not at the start of its segment).
- `~/notes/2026/Q2.md` slugs to `Users-you-notes-2026-Q2.md` (no segment starts with `.`, so no `_` rewrite happens).
- `/var/log/system.log` slugs to `var-log-system.log` (paths outside `$HOME` follow the same rule, just without the `Users/you` prefix).
- `~/foo/.bar` slugs to `Users-you-foo-_bar` (only the `.bar` segment is rewritten, not the others).
- `~/repos/bu-command` slugs to `Users-you-repos-bu--command` (the internal `-` in `bu-command` is doubled so it cannot be confused with the segment separator).
- `~/foo/-bar` slugs to `Users-you-foo-%2Dbar` (a `-` at the start of a segment is percent-escaped instead of doubled, so it cannot bleed into the adjacent separator).
- `~/_x` slugs to `Users-you-__x` (a literal leading `_` gains an extra `_` so it stays distinct from the `_` produced by a leading `.`).

Caveats:

- `~user` (other-user shorthand) is not supported. Use the absolute path.
- Symbolic links along the path are NOT resolved. `bu.sh ~/link-to-foo` and `bu.sh ~/foo` produce different slugs even if they point at the same file. To collapse them, pass the resolved target: `bu.sh "$(readlink -f ~/link-to-foo)"`.

## Symlinks

`cp -a` is used for the copy. If the source is itself a symlink, the backup is
also a symlink (the link is copied, not its target). To back up the target,
pass the resolved path (`bu.sh "$(readlink -f ~/link)"`).

## Permissions (umask 077)

The script sets `umask 077` at the top. New backup directories end up `700`
and the copied file content keeps whatever mode it had at the source
(`cp -a` preserves source modes).

If you are not used to umask, the short version is this. When any program
creates a file or directory, it asks the kernel for a default permission set
(typically `666` for files and `777` for directories). The umask is a bitmask
of permission bits to subtract from that request. The system default on most
Unix machines is `022`, which strips the write bit from group and other but
leaves the read bit on. Files end up `644` (anyone on the box can read them)
and directories end up `755` (anyone can list them).

That default is fine for source code or shared documents. It is the wrong
default for backups. A snapshot of `~/.ssh`, a staged `pg_dump`, a `.env`
file, or anything under `~/.config` may contain credentials, tokens, or
otherwise private data. With the default umask, every snapshot directory
`bu.sh` creates would be world-readable.

`umask 077` strips read, write, and execute from both group and other, so
only your user can enter a snapshot directory. The copied file contents
themselves still reflect the source mode, since `cp -a` preserves it. If
the source was world-readable, the backup of it is too; the wrapper
directory around it is not.

Existing backups taken before this change keep their old permissions. To
tighten them in place:

```bash
chmod -R go-rwx ~/.backups/backups
```

## Examples

### Back up `~/.claude` (the original motivating case)

```bash
$ bu.sh ~/.claude
/Users/you/.backups/backups/Users-you-_claude/2026-05-13/.claude
```

Result on disk:

```
~/.backups/backups/Users-you-_claude/2026-05-13/.claude/
  CLAUDE.md
  settings.json
  ...
```

### Back up a single file

```bash
$ bu.sh ~/notes/todo.md
/Users/you/.backups/backups/Users-you-notes-todo.md/2026-05-13/todo.md
```

### Back up something outside your home directory

```bash
$ bu.sh /etc/hosts
/Users/you/.backups/backups/etc-hosts/2026-05-13/hosts
```

### Back up a directory in your home folder

Any directory works the same as a file (the whole tree is copied with `cp -a`):

```bash
$ bu.sh ~/projects/blog
/Users/you/.backups/backups/Users-you-projects-blog/2026-05-13/blog

$ ls /Users/you/.backups/backups/Users-you-projects-blog/2026-05-13/blog
README.md  posts  static
```

Restore the latest snapshot alongside the live tree:

```bash
$ bu.sh --restore ~/projects/blog
/Users/you/projects/blog.restored

$ diff -r ~/projects/blog ~/projects/blog.restored
```

### Back up a directory under `/tmp` (or anywhere on the root partition)

Paths outside `$HOME` use the absolute path (with the leading `/` stripped) for the
slug. Useful for staged dumps or scratch trees:

```bash
$ bu.sh /tmp/scratch
/Users/you/.backups/backups/tmp-scratch/2026-05-13/scratch

$ bu.sh /var/log
/Users/you/.backups/backups/var-log/2026-05-13/log
```

(`/tmp` is wiped on reboot on most systems, so this is also a quick way to keep a copy
of something you staged there before it disappears.)

Restore works against the same path you backed up. After a reboot wipes `/tmp`, the
parent directory (`/tmp`) still exists, so the restore lands at `/tmp/scratch.restored`:

```bash
$ bu.sh --restore /tmp/scratch
/tmp/scratch.restored

$ bu.sh --restore /tmp/scratch 2026-05-13       # latest snapshot taken on that day
/tmp/scratch.restored
```

### Tilde and relative paths both work

```bash
$ bu.sh "~/.ssh/config"
/Users/you/.backups/backups/Users-you-_ssh-config/2026-05-13/config

$ cd ~/repos/bu-command
$ bu.sh bu.sh
/Users/you/.backups/backups/Users-you-repos-bu--command-bu.sh/2026-05-13/bu.sh
```

(The script absolutizes relative paths before computing the slug, so the slug reflects where the file actually lives, not what you typed. `~/x` and `/Users/you/x` produce the same slug.)

### Multiple runs on the same day

```bash
$ bu.sh ~/.claude
/Users/you/.backups/backups/Users-you-_claude/2026-05-13/.claude

$ bu.sh ~/.claude
/Users/you/.backups/backups/Users-you-_claude/2026-05-13-2/.claude

$ bu.sh ~/.claude
/Users/you/.backups/backups/Users-you-_claude/2026-05-13-3/.claude
```

All three snapshots sit side by side under the same slug folder. Nothing is overwritten.

### Capture the destination path in a variable

```bash
$ dest=$(bu.sh ~/.claude)
$ ls "$dest"
CLAUDE.md  settings.json  ...
```

### Quick before/after when editing a config

```bash
$ bu.sh ~/.config/fish/config.fish
$ vim ~/.config/fish/config.fish
$ diff ~/.backups/backups/Users-you-_config-fish-config.fish/2026-05-13/config.fish ~/.config/fish/config.fish
```

### Back up several things at once (with a shell loop)

`bu.sh` only takes one path. Loop in the shell for more:

```bash
for path in ~/.claude ~/.config/fish ~/.ssh; do
  bu.sh "$path"
done
```

### Daily cron snapshot at 3:07 AM

```cron
7 3 * * * /Users/you/repos/bu-command/bu.sh /Users/you/.claude >> /Users/you/.backups/bu.log 2>&1
```

(Cron does not expand `~`. Use absolute paths.)

### List all snapshots of a given source

```bash
$ ls ~/.backups/backups/Users-you-_claude/
2026-05-10  2026-05-11  2026-05-13  2026-05-13-2
```

### See every source you have ever backed up

```bash
$ ls ~/.backups/backups/
Users-you-_claude  Users-you-_config-fish-config.fish  Users-you-notes-todo.md  etc-hosts
```

### Inspect the whole backup tree

`tree` over `~/.backups/` walks slug, date, and contents in one view:

```
$ tree ~/.backups/
/Users/you/.backups/
└── backups
    └── Users-you-_claude-CLAUDE.md
        └── 2026-05-21
            └── CLAUDE.md

4 directories, 1 file
```

Use `tree -a` if you backed up a hidden source (e.g. `~/.claude`, `~/.ssh`): the slug itself never starts with `.`, but the copied basename inside the dated folder does, and `tree` hides those by default.

### Restore from a backup

```
bu.sh --restore <path> [date]
```

The slug is derived from `<path>` exactly as for backup, so you pass the original
source path (not the slug). The source itself does not have to exist anymore (its
parent directory does). The snapshot is copied with `cp -a` to `<path>.restored` and
the absolute destination path is printed to stdout. The live source is never touched.

Date selection:

| `[date]`       | Snapshot picked                                                    |
|----------------|--------------------------------------------------------------------|
| (omitted)      | Latest snapshot for the slug (newest day, highest counter)         |
| `YYYY-MM-DD`   | Latest snapshot taken on that day (e.g. `-3` if it exists)         |
| `YYYY-MM-DD-N` | Exact snapshot directory (e.g. the second snapshot of that day)    |

```bash
$ bu.sh --restore ~/.claude
/Users/you/.claude.restored

$ bu.sh --restore ~/.claude 2026-05-13
/Users/you/.claude.restored

$ bu.sh --restore ~/.claude 2026-05-13-2
/Users/you/.claude.restored
```

If `<path>.restored` already exists, restore refuses (no overwrite, no counter):

```bash
$ bu.sh --restore ~/.claude
bu.sh: destination exists: /Users/you/.claude.restored
$ echo $?
1
```

Rename or remove the existing `.restored` and try again. Restoring on top of the live
source is a destructive choice and is intentionally not automated: the script always
restores alongside, so you can diff and swap manually.

If you would rather not use `--restore` (different destination, scripted pipeline,
just a one-off copy), `cp -a` against the snapshot folder works the same way:

```bash
$ cp -a ~/.backups/backups/Users-you-_claude/2026-05-13/.claude ~/.claude.restored
```

Use `ls ~/.backups/backups/<slug>/` to see the available snapshots.

### Back up the result of a command

The source has to exist on disk. Stage it first:

```bash
$ pg_dump mydb > /tmp/mydb.sql && bu.sh /tmp/mydb.sql
/Users/you/.backups/backups/tmp-mydb.sql/2026-05-13/mydb.sql
```

### Errors look like this

```bash
$ bu.sh
usage: bu.sh <path>
$ echo $?
2

$ bu.sh /does/not/exist
bu.sh: not found: /does/not/exist
$ echo $?
1
```

(When invoked through the `bu` symlink, the program name in error messages is
`bu`, not `bu.sh`.)

## Code review

The script and tests have been through a structured review. The headings
below are the categories the review walked through and the kind of thing
each one covered. Future patches should keep these areas covered (run
`./test_bu.sh` before sending one).

- **Correctness.** Injective slug encoding so distinct paths always
  produce distinct slug folders (no silent mixing), atomic
  `mkdir`-or-fail counter so two same-day runs cannot clobber each other,
  numeric (not lexicographic) comparison of the `-N` counter so `-10`
  sorts after `-9`, `--restore` refuses to overwrite an existing
  `.restored` destination.
- **Conventions.** `set -euo pipefail`, every expansion quoted, `[[ ... ]]`
  throughout, no `eval`, single-file Bash with no external deps beyond
  coreutils.
- **Performance.** Snapshot picker is O(n) over the snapshots in one slug
  and runs in-process (no subshell per entry). `cp -a` is the only real
  bottleneck and is intrinsic to the job.
- **Test coverage.** 52 tests in `test_bu.sh`, each in an isolated
  temporary `$HOME`, with an `EXIT` trap so a crashing test still cleans
  up its temp dirs. Covers happy paths, every documented exit code,
  tilde expansion, symlink preservation, double-digit counter sort,
  injective slug encoding (dash in segment, leading underscore, dash at
  segment boundary, literal `%`), leading-dash basenames, and
  snapshot-dir permissions.
- **Security.** `umask 077` so snapshot dirs are not world-readable (see
  the umask section above), no command-injection surface (no `eval`, all
  expansions quoted), `--restore` never writes on top of the live source,
  atomic `mkdir` prevents racing into a sibling directory.

## Tests

A self-contained test suite lives in `test_bu.sh`. It runs each test in an isolated temporary `$HOME` so it never touches your real `~/.backups/`.

```bash
$ ./test_bu.sh
Running test suite for /Users/you/repos/bu-command/bu.sh
  PASS  test_no_args_exits_2
  PASS  test_too_many_args_exits_2
  ...
Results: 52 passed, 0 failed
```

## What `bu.sh` does not do

- Move (the source is always preserved).
- Compress, encrypt, or deduplicate. Use `tar`, `age`, or `restic` if you need any of those.
- Overwrite the live source on restore. The destination is always `<path>.restored`; swap manually if you want it in place.
- Sync to remote storage. Pair it with `rsync`, `rclone`, or a backup service if you need offsite copies.
- Garbage-collect old snapshots. Prune by hand when the directory grows.

If any of those become annoying, that is the moment to reach for a real backup tool (`restic`, `borg`, Time Machine) rather than growing this script.
