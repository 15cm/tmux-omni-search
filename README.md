# tmux-omni-search

`tmux-omni-search` is a standalone tmux plugin for full-text searching across all tmux panes and jumping to the selected match from an `fzf-tmux` popup.

## Dependencies

- `bash`
- `tmux >= 3.2`
- `fzf`
- `fzf-tmux`

## Install

### TPM

Add the plugin to your tmux config:

```tmux
set -g @plugin 'sinkerine/tmux-omni-search'
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
    tmux-omni-search.url = "github:sinkerine/tmux-omni-search";
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
set -g @omni-search-fzf-options "--border rounded"
```

- `@omni-search-launch-key`: key passed to `bind-key`
- `@omni-search-popup-width`: popup width for `fzf-tmux`
- `@omni-search-popup-height`: popup height for `fzf-tmux`
- `@omni-search-preview`: `on` or `off`
- `@omni-search-preview-context-lines`: non-negative total number of surrounding lines shown around the first match in preview, split across before and after
- `@omni-search-preview-fill-window`: `on` expands preview context to use the current `fzf` preview height when possible
- `@omni-search-fzf-options`: extra arguments appended to `fzf`

## Usage

Source the plugin and press the configured launch key.

- The launcher loads all panes into `fzf` up front using `tmux capture-pane`.
- Search semantics come from `fzf` itself.
- Repeated shell prompt/status prefixes are de-emphasized during indexing so they rank below pane output more often.
- The candidate list shows session, window, pane, and current command; pane text still participates in matching and preview.
- Empty query shows all panes.
- Preview shows a fixed 5-line header plus numbered pane text with the first match highlighted.
- When the query is empty, preview doubles the configured context and still expands to fill the preview window when enabled.
- `Enter` switches to the selected pane.
- `Ctrl-/` toggles preview.
