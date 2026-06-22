# unfold

Resolve a Claude Code `CLAUDE.md` `@import` chain into the single,
flattened instruction set a session actually inherits.

Claude Code lets a `CLAUDE.md` pull in other files with `@path` imports,
recursively, up to a depth limit. So a three-line project file —

```
# Project notes
@~/dev/standards/base.md
@~/dev/standards/device-thisbox.md
```

— looks tiny, but the model reads the *union* of all three, inlined in
order. When you're debugging "why is the agent doing X," or "did my import
even load," or "how much of the context window do my always-on
instructions cost," the thing you actually want to see is that union.
`unfold` prints it.

It is the companion to a `CLAUDE.md` *linter*: a linter checks one file;
`unfold` assembles the whole chain so you can read it, grep it, and diff it.

## Background

unfold was conceived and written by Claude in claude-expo — a private
workshop where Claude picks and builds small utilities under operator
oversight. Correctness- and security-sensitive changes get a cross-vendor
second read from Codex (OpenAI's GPT) before they land; this tool's
public-readiness security pass was one of those. More on the workshop in
[claude-journal](https://github.com/kVadrum/claude-journal).

## What it does

- Starts from a root file (default `./CLAUDE.md`, or `<dir>/CLAUDE.md` if
  you pass a directory) and inlines every `@import` at the point it appears.
- Wraps each included file in provenance markers (HTML comments, so the
  output stays valid markdown) showing the import path and its depth.
- Breaks import cycles, honors a max recursion depth (default 5, matching
  Claude Code), and marks missing imports instead of crashing.
- Prints a footer summarizing each file's size and an estimated token cost
  for the whole resolved chain.

## Usage

```
unfold [OPTIONS] [FILE|DIR]

  FILE   a CLAUDE.md (or any markdown using @imports). Default: ./CLAUDE.md
  DIR    a directory; unfold reads <DIR>/CLAUDE.md

  --bare          emit only the resolved content, no provenance markers
                  (the literal bytes a session inherits)
  --no-footer     suppress the size / token summary footer
  --max-depth N   max import recursion depth (default 5)
  --max-files N   cap total import expansions (default 1000)
  --max-bytes N   cap cumulative inlined bytes (default 50 MiB)
  --no-escape     refuse imports that resolve outside the root file's dir
  --strict        exit 2 on any missing / cyclic / too-deep / escaping /
                  blocked / over-budget import
  -h, --help      show help
  --version       print version
```

Examples:

```sh
# See the full resolved instruction set for the current directory
unfold

# Just the bytes a session inherits — pipe to a pager or a tokenizer
unfold --bare | less

# Diff the effective CLAUDE.md across two machines (per-device imports)
unfold --bare ./CLAUDE.md > /tmp/here.md

# Fail CI if a referenced import is missing
unfold --strict path/to/CLAUDE.md
```

A real chain often surprises you: a 600-byte root `CLAUDE.md` that imports
a shared base and a per-device file can resolve to ~50 KB / ~12k tokens of
always-on context. `unfold` makes that floor visible before a session even
starts.

## Import semantics

`unfold` follows Claude Code's `@import` rules as closely as a standalone
tool can:

- An import is `@` followed by a path, where the `@` is at the start of a
  line or preceded by whitespace. An `@` preceded by a non-space (e.g.
  `name@example.com`) is **not** an import.
- Paths may be relative (resolved against the importing file's directory),
  absolute, or `~/`-prefixed (home).
- `@` tokens inside fenced code blocks (``` ``` ``` / `~~~`) or inline-code
  spans (`` `...` ``) are left untouched — they're code, not imports.
- Recursion stops at `--max-depth` (default 5). A file already on the
  current import path is a cycle: it's marked and not re-expanded.

These are heuristics applied by a text tool, not Claude Code's own parser,
so treat the output as a faithful rendering rather than a byte-exact
guarantee. The token figure is a `chars / 4` estimate, not a real
tokenizer count.

## Security

unfold reads and inlines whatever the imports point at. That's the whole
job, and it's safe on your own files — but if you run it on a `CLAUDE.md`
you did *not* write (a cloned repo, a gist, a PR), the import chain and the
imported content are attacker-controlled, and the resolved output is
something you might paste, commit, or share. unfold defends that case:

- **Out-of-root imports are visible.** Claude Code permits absolute and `~`
  imports, so unfold mirrors that — but an import that resolves outside the
  root file's directory (`@/etc/passwd`, `@~/.ssh/id_rsa`, `@../../secret`,
  or a symlink that escapes) is flagged with a `unfold:escape` marker and a
  stderr warning, and trips `--strict`. Use `--no-escape` to refuse them
  outright. Pseudo-filesystem paths (`/proc`, `/sys`, `/dev` — e.g.
  `/proc/self/environ`, which leaks live environment secrets) are **always**
  refused.
- **No amplification bombs.** A small file that imports a few others, nested
  a few levels, can expand combinatorially. `--max-files` (default 1000) and
  `--max-bytes` (default 50 MiB) bound the total; hitting either warns and
  trips `--strict`.
- **Markers prove structure, not authorship.** Provenance markers show the
  import *tree*; imported *content* is shown verbatim. A hostile filename
  can't break out of a marker (paths are sanitized), and content that mimics
  a marker is defanged in marker mode — but under `--bare` content is fully
  literal. Treat the resolved output of an untrusted chain as untrusted; in
  particular, don't render it as HTML unreviewed.

unfold never writes, never executes an import, and never touches the
network — it only reads and prints.

## Exit codes

- `0` — resolved (any warnings go to stderr)
- `1` — usage error / root file not found
- `2` — `--strict` and at least one import was missing / cyclic / too deep /
  escaping the root / blocked / over budget

## Stack

Bash plus coreutils (`wc`, `dirname`, `readlink`). No runtime dependencies,
no install step, no network, no writes — drop it next to a `CLAUDE.md` and
run it. Bash is the right fit precisely because this is a config-
introspection tool: it should run wherever a `CLAUDE.md` lives, without a
toolchain. Note: symlink-safe path canonicalization uses `readlink -f`,
which is GNU coreutils (Linux) or macOS 12.3+.

## Tests

```sh
bash tests/run.sh
```

Behavioral assertions over fixtures (the resolved output embeds absolute
paths, so the suite checks the contract — substrings, marker counts, exit
codes — rather than golden files).

## Status

v0.2.0. Extracted from the claude-expo workshop as a standalone repo
(fresh history, current state). Bash + coreutils.

## License

MIT — see [`LICENSE`](./LICENSE). "unfold" as a name and the KeMeK Network
identity are not covered by the code license.

---

KeMeK Network © 2026
