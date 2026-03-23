# tmux-omni-search Design Notes

## Search Pipeline

`tmux-omni-search` delegates pane filtering to `fzf`.

The launcher builds one row per pane with visible metadata plus a hidden search corpus. That hidden column starts with higher-priority metadata such as the session name and then appends text derived from the pane capture. On each query change, the active `fzf` instance reloads rows by invoking:

```sh
bin/pane-full-text.sh search {q}
```

Inside `search`, pane rows are piped through:

```sh
fzf --delimiter="$DELIM" --nth=6 --filter "$query"
```

That means the candidate set shown in the picker is defined by `fzf` query semantics over the hidden search corpus, not by a separate shell matcher. The script does not implement its own pane filtering rules.

## Preview Pipeline

Preview rendering has two separate responsibilities:

1. Decide which line inside the selected pane should be treated as the matched line.
2. Paint visible highlighting on that line.

The first responsibility also relies on `fzf`.

When the preview command runs, it captures the selected pane text, prefixes each line with its line number, and runs the lines back through:

```sh
fzf --delimiter="$DELIM" --nth=2.. --filter "$query"
```

The first matching row becomes the preview anchor line. This keeps preview line selection aligned with the same `fzf` query behavior used by the main pane list.

## Why Highlighting Is Local

`fzf --filter` answers whether a row matches, but it does not expose match spans or token-level metadata. In particular, it does not return:

- the character offsets of each match
- which query term matched which substring
- terminal-independent highlight spans for preview rendering

Because of that, the preview highlight pass is local code. It is not the authority for filtering. Its job is only to render a useful visual approximation on the already-selected preview line.

## Current Highlight Model

The highlight pass tokenizes the query into highlight candidates:

- quoted phrases should be treated as one candidate
- unquoted space-separated terms are treated as separate candidates

For the matched preview line, the renderer should:

1. Find candidate spans case-insensitively.
2. Prefer earlier spans over later spans.
3. Prefer more specific overlaps over weaker ones.
4. Prefer phrase spans over individual-term spans when they overlap.
5. Prefer longer spans when competing matches start at the same position.
6. Drop weaker overlapping spans once a stronger span is accepted.

This is intentionally a rendering heuristic, not a second implementation of `fzf` filtering.

## Design Boundary

The intended division of responsibility is:

- `fzf` decides whether a pane row matches.
- `fzf` decides which pane line is the first matching preview line.
- local shell code renders preview context and best-effort highlighting for the selected line.

This boundary keeps the search behavior anchored to `fzf` while avoiding a full reimplementation of `fzf` query parsing in shell.
