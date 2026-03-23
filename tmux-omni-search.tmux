#!/bin/sh

CURRENT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SCRIPT_PATH="${CURRENT_DIR}/bin/panel-full-text.sh"
SCRIPT_PATH_SQ="$(printf "%s\n" "$SCRIPT_PATH" | sed "s/'/'\\\\''/g")"

get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local value

  value="$(tmux show-option -gqv "$option")"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$default_value"
  fi
}

launch_key="$(get_tmux_option "@omni-search-launch-key" "F")"

tmux bind-key "$launch_key" run-shell -b "sh -c '$SCRIPT_PATH_SQ; status=\$?; [ \$status -eq 130 ] && exit 0; exit \$status'"
