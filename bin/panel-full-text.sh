#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

readonly PREVIEW_CONTEXT=3
readonly DELIM=$'\t'

ensure_utf8_locale() {
  local current_locale locale_bin locale_list candidate

  current_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ ${current_locale,,} == *"utf-8"* || ${current_locale,,} == *"utf8"* ]]; then
    return
  fi

  locale_bin="$(command -v locale || true)"
  if [ -n "$locale_bin" ]; then
    locale_list="$("$locale_bin" -a 2>/dev/null || true)"
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
      if grep -Fqx "$candidate" <<<"$locale_list"; then
        export LC_CTYPE="$candidate"
        return
      fi
    done
  fi

  # Most modern distros provide C.UTF-8 even when locale(1) is unavailable.
  export LC_CTYPE="C.UTF-8"
}

get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local value

  value="$(tmux show-option -gqv "$option")"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Missing required command: $command_name"
  fi
}

require_tmux_context() {
  if [ -z "${TMUX:-}" ]; then
    fail "tmux-omni-search must run inside tmux."
  fi
}

require_tmux_version() {
  local version major minor

  version="$(tmux -V)"
  if [[ ! $version =~ ([0-9]+)\.([0-9]+) ]]; then
    fail "Unable to parse tmux version from: $version"
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  if (( major < 3 || (major == 3 && minor < 2) )); then
    fail "tmux-omni-search requires tmux >= 3.2."
  fi
}

escape_preview_line() {
  local line="$1"
  line="${line//$'\033'/}"
  printf '%s\n' "$line"
}

highlight_first_match() {
  local line="$1"
  local query="$2"
  local lower_line lower_query prefix position query_length

  if [ -z "$query" ]; then
    printf '%s\n' "$line"
    return
  fi

  lower_line="${line,,}"
  lower_query="${query,,}"
  if [[ $lower_line != *"$lower_query"* ]]; then
    printf '%s\n' "$line"
    return
  fi

  prefix="${lower_line%%"$lower_query"*}"
  position="${#prefix}"
  query_length="${#query}"

  printf '%s\033[1;31m%s\033[0m%s\n' \
    "${line:0:position}" \
    "${line:position:query_length}" \
    "${line:position + query_length}"
}

first_matching_line() {
  local query="$1"
  local line
  local lower_query="${query,,}"

  while IFS= read -r line; do
    if [[ ${line,,} == *"$lower_query"* ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done

  return 1
}

pane_rows() {
  tmux list-panes -a -F "#{pane_id}${DELIM}#{session_name}${DELIM}#{window_index}${DELIM}#{window_name}${DELIM}#{pane_index}${DELIM}#{pane_title}"
}

pane_search() {
  local query="$1"
  local row pane_id session_name window_index window_name pane_index pane_title
  local pane_text matched_line snippet

  if [ -z "$query" ]; then
    exit 0
  fi

  while IFS= read -r row; do
    IFS="$DELIM" read -r pane_id session_name window_index window_name pane_index pane_title <<<"$row"
    pane_text="$(tmux capture-pane -ep -t "$pane_id")"
    if ! matched_line="$(first_matching_line "$query" <<<"$pane_text")"; then
      continue
    fi

    snippet="$matched_line"
    if ((${#snippet} > 160)); then
      snippet="${snippet:0:157}..."
    fi

    printf '%s\t%s\t%s:%s.%s\t%s\n' \
      "$pane_id" \
      "$session_name" \
      "$window_index" \
      "$window_name" \
      "$pane_index" \
      "$snippet"
  done < <(pane_rows)
}

pane_preview() {
  local pane_id="$1"
  local query="$2"
  local pane_text
  local -a lines=()
  local i first_match start end

  [ -n "$pane_id" ] || exit 0

  pane_text="$(tmux capture-pane -ep -t "$pane_id")"
  mapfile -t lines <<<"$pane_text"
  first_match=-1

  for i in "${!lines[@]}"; do
    if [[ ${lines[i],,} == *"${query,,}"* ]]; then
      first_match="$i"
      break
    fi
  done

  if (( first_match < 0 )); then
    first_match=0
  fi

  start=$(( first_match - PREVIEW_CONTEXT ))
  if (( start < 0 )); then
    start=0
  fi

  end=$(( first_match + PREVIEW_CONTEXT ))
  if (( ${#lines[@]} == 0 )); then
    exit 0
  fi
  if (( end >= ${#lines[@]} )); then
    end=$(( ${#lines[@]} - 1 ))
  fi

  for ((i = start; i <= end; i++)); do
    if (( i == first_match )); then
      printf '> '
      highlight_first_match "$(escape_preview_line "${lines[i]}")" "$query"
    else
      printf '  %s\n' "$(escape_preview_line "${lines[i]}")"
    fi
  done
}

run_launcher() {
  local script_path quoted_script popup_width popup_height preview_enabled extra_fzf_options
  local preview_window preview_command reload_command fzf_tmux_bin selection status pane_id

  require_tmux_context
  require_tmux_version
  require_command tmux
  require_command fzf
  require_command fzf-tmux

  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  printf -v quoted_script '%q' "$script_path"
  fzf_tmux_bin="$(command -v fzf-tmux)"

  popup_width="$(get_tmux_option "@omni-search-popup-width" "62%")"
  popup_height="$(get_tmux_option "@omni-search-popup-height" "38%")"
  preview_enabled="$(get_tmux_option "@omni-search-preview" "on")"
  extra_fzf_options="$(get_tmux_option "@omni-search-fzf-options" "")"

  preview_window="hidden"
  if [ "$preview_enabled" = "on" ]; then
    preview_window="right:60%:wrap"
  fi

  reload_command="$quoted_script search {q}"
  preview_command="$quoted_script preview {1} {q}"

  set +e
  # shellcheck disable=SC2086
  selection="$(
    bash "$fzf_tmux_bin" -p -w "$popup_width" -h "$popup_height" -- \
      --ansi \
      --disabled \
      --delimiter="$DELIM" \
      --with-nth=2,3,4 \
      --preview-window="$preview_window" \
      --preview "$preview_command" \
      --prompt 'Pane text> ' \
      --header 'Type to search across pane contents' \
      --bind "start:reload:$reload_command" \
      --bind "change:reload:$reload_command" \
      --bind 'ctrl-/:toggle-preview' \
      ${extra_fzf_options:+$extra_fzf_options}
  )"
  status=$?
  set -e

  case "$status" in
    0)
      ;;
    130)
      exit 0
      ;;
    *)
      exit "$status"
      ;;
  esac

  [ -n "$selection" ] || exit 0
  IFS="$DELIM" read -r pane_id _ <<<"$selection"
  [ -n "$pane_id" ] || exit 0
  tmux switch-client -t "$pane_id"
}

main() {
  local mode="${1:-launch}"

  ensure_utf8_locale

  case "$mode" in
    launch)
      run_launcher
      ;;
    search)
      shift
      pane_search "${1:-}"
      ;;
    preview)
      shift
      pane_preview "${1:-}" "${2:-}"
      ;;
    *)
      fail "Unknown mode: $mode"
      ;;
  esac
}

main "$@"
