#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

readonly DELIM=$'\t'
readonly PROMPT_REPEAT_THRESHOLD=2

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

preview_header_lines() {
  printf '%s\n' "0"
}

effective_preview_context_lines() {
  local query="$1"
  local context_lines="$2"
  local fill_window="$3"
  local preview_lines fill_context_lines header_lines

  if [ -z "$query" ]; then
    context_lines=$(( context_lines * 2 ))
  fi

  if [ "$fill_window" = "on" ] && [[ "${FZF_PREVIEW_LINES:-}" =~ ^[0-9]+$ ]] && (( FZF_PREVIEW_LINES > 0 )); then
    header_lines="$(preview_header_lines)"
    preview_lines=$(( FZF_PREVIEW_LINES - header_lines ))
    if (( preview_lines < 0 )); then
      preview_lines=0
    fi
    # Keep enough total surrounding context to use the available preview height
    # once the lines are split above and below the match.
    fill_context_lines=$(( preview_lines - 1 ))
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

preview_match_line_number() {
  local pane_text="$1"
  local query="$2"
  local first_token lower_query line
  local line_number=1

  first_token="$(preview_query_token "$query")"
  if [ -z "${first_token:-}" ]; then
    printf '1\n'
    return
  fi

  lower_query="${first_token,,}"
  while IFS= read -r line; do
    if [[ ${line,,} == *"$lower_query"* ]]; then
      printf '%s\n' "$line_number"
      return
    fi
    line_number=$(( line_number + 1 ))
  done <<<"$pane_text"

  printf '1\n'
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

print_preview_header() {
  :
}

print_preview_body_line() {
  local line_number="$1"
  local text="$2"

  printf '%6s  %s\n' "$line_number" "$text"
}

sanitize_field() {
  local text="$1"

  text="${text//$'\t'/ }"
  text="${text//$'\r'/ }"
  printf '%s' "$text"
}

trim_line() {
  local text="$1"

  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

normalize_prompt_signature() {
  local text="$1"

  text="$(trim_line "$text")"
  text="${text,,}"
  text="$(sed -E 's/[[:digit:]]+/0/g; s/[[:space:]]+/ /g' <<<"$text")"
  printf '%s' "$text"
}

prompt_prefix_looks_like_status() {
  local prefix="$1"
  local marker="$2"
  local trimmed_prefix

  trimmed_prefix="$(trim_line "$prefix")"
  if [ -z "$trimmed_prefix" ]; then
    return 0
  fi

  if [[ $trimmed_prefix =~ [~/@:\[\]\(\)] ]]; then
    return 0
  fi

  if [ "$marker" = "%" ] && [ "${#trimmed_prefix}" -le 60 ]; then
    return 0
  fi

  return 1
}

split_prompt_line() {
  local line="$1"
  local trimmed_line marker prefix suffix next_char index
  local line_length max_scan

  trimmed_line="$(trim_line "$line")"
  if [ -z "$trimmed_line" ]; then
    return 1
  fi

  line_length="${#trimmed_line}"
  max_scan=$line_length
  if (( max_scan > 120 )); then
    max_scan=120
  fi

  for ((index = 0; index < max_scan; index++)); do
    marker="${trimmed_line:index:1}"
    if [ "$marker" != '$' ] &&
      [ "$marker" != '#' ] &&
      [ "$marker" != '%' ] &&
      [ "$marker" != '>' ] &&
      [ "$marker" != "❯" ]; then
      continue
    fi

    next_char="${trimmed_line:index + 1:1}"
    if [ -n "$next_char" ] && [[ ! $next_char =~ [[:space:]] ]]; then
      continue
    fi

    prefix="${trimmed_line:0:index}"
    if ! prompt_prefix_looks_like_status "$prefix" "$marker"; then
      continue
    fi

    suffix="${trimmed_line:index + 1}"
    suffix="$(trim_line "$suffix")"
    printf '%s\t%s\n' "$(normalize_prompt_signature "${prefix}${marker}")" "$suffix"
    return 0
  done

  return 1
}

searchable_pane_text() {
  local pane_text="$1"
  local line prompt_signature prompt_suffix normalized_line
  local combined=""
  local -a normalized_lines=()
  local -a prompt_signatures=()
  local -a prompt_suffixes=()
  local -A prompt_counts=()

  while IFS= read -r line; do
    line="$(strip_ansi_from_line "$line")"
    normalized_line="$(sanitize_field "$line")"
    normalized_lines+=("$normalized_line")

    if IFS=$'\t' read -r prompt_signature prompt_suffix < <(split_prompt_line "$normalized_line"); then
      prompt_signatures+=("$prompt_signature")
      prompt_suffixes+=("$prompt_suffix")
      ((prompt_counts["$prompt_signature"] += 1))
    else
      prompt_signatures+=("")
      prompt_suffixes+=("")
    fi
  done <<<"$pane_text"

  for line in "${!normalized_lines[@]}"; do
    normalized_line="${normalized_lines[line]}"
    prompt_signature="${prompt_signatures[line]}"
    prompt_suffix="${prompt_suffixes[line]}"

    if [ -n "$prompt_signature" ] && (( prompt_counts["$prompt_signature"] >= PROMPT_REPEAT_THRESHOLD )); then
      normalized_line="$prompt_suffix"
      if [ -z "$normalized_line" ]; then
        continue
      fi
    fi

    if [ -n "$combined" ]; then
      combined+=" "
    fi
    combined+="$normalized_line"
  done

  printf '%s\n' "$combined"
}

pane_rows() {
  tmux list-panes -a -F "#{pane_id}${DELIM}#{session_name}${DELIM}#{window_index}${DELIM}#{window_name}${DELIM}#{pane_index}${DELIM}#{pane_current_command}"
}

pane_search() {
  local query="${1:-}"
  local row pane_id session_name window_index window_name pane_index pane_current_command
  local pane_text searchable_text match_line_number

  {
    while IFS= read -r row; do
      IFS="$DELIM" read -r pane_id session_name window_index window_name pane_index pane_current_command <<<"$row"
      pane_text="$(tmux capture-pane -p -t "$pane_id")"
      searchable_text="$(searchable_pane_text "$pane_text")"
      match_line_number="$(preview_match_line_number "$pane_text" "$query")"

      printf '%s\t%s\t%s:%s.%s\t%s\t%s\t%s\n' \
        "$(sanitize_field "$pane_id")" \
        "$(sanitize_field "$session_name")" \
        "$(sanitize_field "$window_name")" \
        "$window_index" \
        "$pane_index" \
        "$(sanitize_field "$pane_current_command")" \
        "$match_line_number" \
        "$searchable_text"
    done < <(pane_rows)
  } | if [ -n "$query" ]; then
    fzf --delimiter="$DELIM" --filter "$query"
  else
    cat
  fi
}

pane_preview() {
  local pane_id="$1"
  local query="$2"
  local context_lines="$3"
  local fill_window="${4:-on}"
  local match_line="${5:-1}"
  local pane_text
  local -a lines=()
  local i start end effective_context_lines before_context_lines after_context_lines

  [ -n "$pane_id" ] || exit 0

  pane_text="$(tmux capture-pane -p -t "$pane_id")"
  mapfile -t lines <<<"$pane_text"
  effective_context_lines="$(effective_preview_context_lines "$query" "$context_lines" "$fill_window")"
  if (( ${#lines[@]} == 0 )); then
    exit 0
  fi

  if [[ ! $match_line =~ ^[0-9]+$ ]] || (( match_line < 1 )); then
    match_line=1
  fi
  if (( match_line > ${#lines[@]} )); then
    match_line=${#lines[@]}
  fi

  print_preview_header "$pane_id" "$query" "$match_line"

  if [ "$fill_window" = "on" ]; then
    for i in "${!lines[@]}"; do
      if (( i + 1 == match_line )); then
        printf '\033[1m%6s\033[0m  ' "$(( i + 1 ))"
        highlight_first_match "$(strip_ansi_from_line "${lines[i]}")" "$query"
      else
        print_preview_body_line "$(( i + 1 ))" "$(strip_ansi_from_line "${lines[i]}")"
      fi
    done
    return
  fi

  before_context_lines=$(( effective_context_lines / 2 ))
  after_context_lines=$(( effective_context_lines - before_context_lines ))

  start=$(( match_line - 1 - before_context_lines ))
  if (( start < 0 )); then
    start=0
  fi

  end=$(( match_line - 1 + after_context_lines ))
  if (( end >= ${#lines[@]} )); then
    end=$(( ${#lines[@]} - 1 ))
  fi

  for ((i = start; i <= end; i++)); do
    if (( i + 1 == match_line )); then
      printf '\033[1m%6s\033[0m  ' "$(( i + 1 ))"
      highlight_first_match "$(strip_ansi_from_line "${lines[i]}")" "$query"
    else
      print_preview_body_line "$(( i + 1 ))" "$(strip_ansi_from_line "${lines[i]}")"
    fi
  done
}

run_launcher() {
  local script_path quoted_script popup_width popup_height preview_enabled extra_fzf_options
  local preview_context_lines preview_fill_window
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
  preview_context_lines="$(parse_non_negative_integer "$(get_tmux_option "@omni-search-preview-context-lines" "20")" "20" "@omni-search-preview-context-lines")"
  preview_fill_window="$(get_tmux_option "@omni-search-preview-fill-window" "on")"
  extra_fzf_options="$(get_tmux_option "@omni-search-fzf-options" "")"

  preview_window="hidden"
  if [ "$preview_enabled" = "on" ]; then
    preview_window="right:60%:wrap"
    if [ "$preview_fill_window" = "on" ]; then
      preview_window="right:60%:wrap,+{5}/2"
    fi
  fi

  preview_command="$quoted_script preview {1} {q} $preview_context_lines $preview_fill_window {5}"
  reload_command="$quoted_script search {q}"

  set +e
  # shellcheck disable=SC2086
  selection="$(
    pane_search "" | bash "$fzf_tmux_bin" -p -w "$popup_width" -h "$popup_height" -- \
      --ansi \
      --disabled \
      --delimiter="$DELIM" \
      --with-nth=2,3,4 \
      --accept-nth=1 \
      --preview-window="$preview_window" \
      --preview "$preview_command" \
      --prompt 'Pane text> ' \
      --header 'Type to search across pane contents' \
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
      trap 'exit 0' INT TERM
      shift
      pane_search "${1:-}"
      ;;
    preview)
      trap 'exit 0' INT TERM
      shift
      pane_preview "${1:-}" "${2:-}" "${3:-20}" "${4:-on}" "${5:-1}"
      ;;
    *)
      fail "Unknown mode: $mode"
      ;;
  esac
}

main "$@"
