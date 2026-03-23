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
set -g @omni-search-fzf-options "--border rounded"
```

- `@omni-search-launch-key`: key passed to `bind-key`
- `@omni-search-popup-width`: popup width for `fzf-tmux`
- `@omni-search-popup-height`: popup height for `fzf-tmux`
- `@omni-search-preview`: `on` or `off`
- `@omni-search-fzf-options`: extra arguments appended to `fzf`

## Usage

Source the plugin and press the configured launch key.

- Empty query shows no rows.
- Non-empty query scans all panes with `tmux capture-pane -ep`.
- Search is case-insensitive fixed-string matching.
- Preview shows nearby context with the first match highlighted.
- `Enter` switches to the selected pane.
- `Ctrl-/` toggles preview.
