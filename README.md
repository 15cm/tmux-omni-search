# tmux-omni-search

`tmux-omni-search` is a standalone tmux plugin for full-text searching across all tmux panes and jumping to the selected match from an `fzf-tmux` popup.

## Demo

[![asciicast](https://asciinema.org/a/861902.svg)](https://asciinema.org/a/861902)

## Dependencies

- `bash`
- `tmux >= 3.2`
- `fzf`
- `fzf-tmux`

## Install

### TPM

Add the plugin to your tmux config:

```tmux
set -g @plugin '15cm/tmux-omni-search'
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux or install via TPM.

### Nix Flake

This repo exposes `packages.<system>.default` and `packages.<system>.tmux-omni-search`.

Example consumer flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    tmux-omni-search.url = "github:15cm/tmux-omni-search";
  };

  outputs = { self, nixpkgs, tmux-omni-search }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      packages.${system}.default = tmux-omni-search.packages.${system}.default;
    };
}
```

You can then build it with:

```sh
nix build .#default
```

Or install it from another flake output with:

```nix
tmux-omni-search.packages.${pkgs.system}.default
```

## tmux Options

```tmux
set -g @omni-search-launch-key "F"
set -g @omni-search-popup-width "62%"
set -g @omni-search-popup-height "38%"
set -g @omni-search-preview "on"
set -g @omni-search-preview-context-lines "20"
set -g @omni-search-preview-fill-window "on"
set -g @omni-search-pane-capture-limit "3000"
set -g @omni-search-fzf-options "--border rounded"
```

- `@omni-search-launch-key`: key passed to `bind-key`
- `@omni-search-popup-width`: popup width for `fzf-tmux`
- `@omni-search-popup-height`: popup height for `fzf-tmux`
- `@omni-search-preview`: `on` or `off`
- `@omni-search-preview-context-lines`: non-negative total number of surrounding lines shown around the first match in preview, split across before and after
- `@omni-search-preview-fill-window`: `on` expands preview context to use the current `fzf` preview height when possible
- `@omni-search-pane-capture-limit`: non-negative number of pane-history lines captured from the tail of scrollback for search and preview; `0` disables the limit
- `@omni-search-fzf-options`: extra arguments appended to `fzf`

## Usage

Source the plugin and press the configured launch key.

- The launcher loads pane contents, including scrollback history, into `fzf` up front using `tmux capture-pane -S -`, then keeps only the last `@omni-search-pane-capture-limit` lines by default.
- Search semantics come from `fzf`, applied to a hidden search corpus that starts with session metadata before pane text.
- Session-name matches are intentionally weighted above weaker pane-text matches.
- Repeated shell prompt/status prefixes are de-emphasized during indexing so they rank below pane output more often.
- The candidate list shows session, window, pane, and current command; pane text still participates in matching and preview.
- Empty query shows all panes.
- Preview shows numbered pane text with all matched query terms highlighted on the selected line.
- When the query is empty, preview doubles the configured context and still expands to fill the preview window when enabled.
- `Enter` switches to the selected pane.
- `Ctrl-/` toggles preview.
