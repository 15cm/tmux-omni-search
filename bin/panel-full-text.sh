#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

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

parse_non_negative_integer() {
  local value="$1"
  local default_value="$2"
  local option_name="$3"

  if [ -z "$value" ]; then
    printf '%s\n' "$default_value"
    return
  fi

  if [[ ! $value =~ ^[0-9]+$ ]]; then
    fail "$option_name must be a non-negative integer."
  fi

  printf '%s\n' "$value"
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

strip_ansi_from_line() {
  local line="$1"

  line="${line//$'\033'/}"
  printf '%s\n' "$line"
}

print_preview_text() {
  local text="$1"
  printf '%s\n' "$text"
}

effective_preview_context_lines() {
  local query="$1"
  local context_lines="$2"
  local fill_window="$3"
  local preview_lines fill_context_lines

  if [ -z "$query" ]; then
    context_lines=$(( context_lines * 2 ))
  fi

  if [ "$fill_window" = "on" ] && [[ "${FZF_PREVIEW_LINES:-}" =~ ^[0-9]+$ ]] && (( FZF_PREVIEW_LINES > 0 )); then
    preview_lines=$(( FZF_PREVIEW_LINES - 1 ))
    if (( preview_lines < 0 )); then
      preview_lines=0
    fi
    fill_context_lines=$(( preview_lines / 2 ))
    if (( fill_context_lines > context_lines )); then
      context_lines=$fill_context_lines
    fi
  fi

  printf '%s\n' "$context_lines"
}

preview_query_token() {
  local query="$1"
  local token

  for token in $query; do
    token="${token#[![:alnum:]]}"
    token="${token%[![:alnum:]]}"
    if [ -n "$token" ]; then
      printf '%s\n' "$token"
      return
    fi
  done

  printf '\n'
}

highlight_first_match() {
  local line="$1"
  local query="$2"
  local lower_line lower_query prefix position query_length
  local match suffix
  local first_token

  if [ -z "$query" ]; then
    print_preview_text "$line"
    return
  fi

  # fzf queries can contain multiple terms and operators. For preview purposes,
  # highlight the first plain token if we can derive one.
  first_token="$(preview_query_token "$query")"

  if [ -z "${first_token:-}" ]; then
    print_preview_text "$line"
    return
  fi

  lower_line="${line,,}"
  lower_query="${first_token,,}"
  if [[ $lower_line != *"$lower_query"* ]]; then
    print_preview_text "$line"
    return
  fi

  prefix="${lower_line%%"$lower_query"*}"
  position="${#prefix}"
  query_length="${#first_token}"
  match="${line:position:query_length}"
  suffix="${line:position + query_length}"

  printf '%s' "${line:0:position}"
  printf '\033[1;31m'
  printf '%s' "$match"
  printf '\033[0m'
  print_preview_text "$suffix"
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

sanitize_field() {
  local text="$1"

  text="${text//$'\t'/ }"
  text="${text//$'\r'/ }"
  printf '%s' "$text"
}

searchable_pane_text() {
  local pane_text="$1"
  local line
  local combined=""

  while IFS= read -r line; do
    line="$(strip_ansi_from_line "$line")"
    line="$(sanitize_field "$line")"
    if [ -n "$combined" ]; then
      combined+=" "
    fi
    combined+="$line"
  done <<<"$pane_text"

  printf '%s\n' "$combined"
}

pane_rows() {
  tmux list-panes -a -F "#{pane_id}${DELIM}#{session_name}${DELIM}#{window_index}${DELIM}#{window_name}${DELIM}#{pane_index}${DELIM}#{pane_current_command}"
}

pane_search() {
  local row pane_id session_name window_index window_name pane_index pane_current_command
  local pane_text searchable_text

  while IFS= read -r row; do
    IFS="$DELIM" read -r pane_id session_name window_index window_name pane_index pane_current_command <<<"$row"
    pane_text="$(tmux capture-pane -p -t "$pane_id")"
    searchable_text="$(searchable_pane_text "$pane_text")"

    printf '%s\t%s\t%s:%s.%s\t%s\t%s\n' \
      "$(sanitize_field "$pane_id")" \
      "$(sanitize_field "$session_name")" \
      "$(sanitize_field "$window_name")" \
      "$window_index" \
      "$pane_index" \
      "$(sanitize_field "$pane_current_command")" \
      "$searchable_text"
  done < <(pane_rows)
}

pane_preview() {
  local pane_id="$1"
  local query="$2"
  local context_lines="$3"
  local fill_window="${4:-on}"
  local pane_text
  local -a lines=()
  local i first_match start end effective_context_lines

  [ -n "$pane_id" ] || exit 0

  pane_text="$(tmux capture-pane -p -t "$pane_id")"
  mapfile -t lines <<<"$pane_text"
  first_match=-1
  effective_context_lines="$(effective_preview_context_lines "$query" "$context_lines" "$fill_window")"

  for i in "${!lines[@]}"; do
    if [[ ${lines[i],,} == *"${query,,}"* ]]; then
      first_match="$i"
      break
    fi
  done

  if (( first_match < 0 )); then
    first_match=0
  fi

  start=$(( first_match - effective_context_lines ))
  if (( start < 0 )); then
    start=0
  fi

  end=$(( first_match + effective_context_lines ))
  if (( ${#lines[@]} == 0 )); then
    exit 0
  fi
  if (( end >= ${#lines[@]} )); then
    end=$(( ${#lines[@]} - 1 ))
  fi

  for ((i = start; i <= end; i++)); do
    if (( i == first_match )); then
      printf '> '
      highlight_first_match "$(strip_ansi_from_line "${lines[i]}")" "$query"
    else
      printf '  '
      print_preview_text "$(strip_ansi_from_line "${lines[i]}")"
    fi
  done
}

run_launcher() {
  local script_path quoted_script popup_width popup_height preview_enabled extra_fzf_options
  local preview_context_lines preview_fill_window
  local preview_window preview_command fzf_tmux_bin selection status pane_id

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
  preview_context_lines="$(parse_non_negative_integer "$(get_tmux_option "@omni-search-preview-context-lines" "5")" "5" "@omni-search-preview-context-lines")"
  preview_fill_window="$(get_tmux_option "@omni-search-preview-fill-window" "on")"
  extra_fzf_options="$(get_tmux_option "@omni-search-fzf-options" "")"

  preview_window="hidden"
  if [ "$preview_enabled" = "on" ]; then
    preview_window="right:60%:wrap"
  fi

  preview_command="$quoted_script preview {1} {q} $preview_context_lines $preview_fill_window"

  set +e
  # shellcheck disable=SC2086
  selection="$(
    pane_search | bash "$fzf_tmux_bin" -p -w "$popup_width" -h "$popup_height" -- \
      --ansi \
      --delimiter="$DELIM" \
      --with-nth=2,3,4,5 \
      --accept-nth=1 \
      --preview-window="$preview_window" \
      --preview "$preview_command" \
      --prompt 'Pane text> ' \
      --header 'Type to search across pane contents' \
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
      trap 'exit 0' INT TERM
      shift
      pane_search
      ;;
    preview)
      trap 'exit 0' INT TERM
      shift
      pane_preview "${1:-}" "${2:-}" "${3:-5}" "${4:-on}"
      ;;
    *)
      fail "Unknown mode: $mode"
      ;;
  esac
}

main "$@"
