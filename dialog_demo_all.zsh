#!/bin/zsh
#
#  dialog_demo_all.zsh
#
#  Runs every `patcher dialog-demo` variant in turn, so each window and notification
#  can be checked on a real Mac (e.g. after a localization or layout change). Nothing is
#  installed, quit or deferred: dialog-demo only reports what patcher would do.
#
#  Usage:
#    sudo ./dialog_demo_all.zsh [options]
#
#  Options:
#    --patcher <path>   patcher binary to run (default: the installed release build,
#                       then the dev build)
#    --step <seconds>   seconds each demo step stays on screen (dialog-demo --step)
#    --countdown <s>    seconds on prompt countdowns (dialog-demo --countdown)
#    --from <n>         start at demo number n (see --list)
#    --only <n>         run only demo number n
#    --no-pause         don't wait for Return between demos
#    --list             list the demos and exit
#
#  Requirements: root, and PatcherNotifier loaded for the console user.
#

set -uo pipefail

script="${0:A}"

# ── Demos: a name, then the dialog-demo arguments ─────────────────────────────

demos=(
  "Large apply window|large"
  "Compact apply window|compact"
  "Scan / check / download progress window|progress"
  "Blocking-app notice (OK)|notice"
  "Blocking-app prompt (Skip Update / Quit, with countdown)|prompt"
  "Deferral prompt, large window|deferral"
  "Deferral prompt, continuing in the compact window|deferral --compact"
  "Deferral prompt at the hard deadline|deferral --deadline"
  "Deferral prompt at the hard deadline, compact|deferral --deadline --compact"
  "Notifications (ApplyDialogSize = notifications)|notifications"
)

# ── Options ───────────────────────────────────────────────────────────────────

patcher=""
extra=()
from=1
only=0
pause=1

usage() { sed -n '9,21p' "$script" | sed -E "s/^#( {1,2}|\$)//"; }

while (( $# > 0 )); do
  case "$1" in
    --patcher)   patcher="$2"; shift 2 ;;
    --step)      extra+=(--step "$2"); shift 2 ;;
    --countdown) extra+=(--countdown "$2"); shift 2 ;;
    --from)      from="$2"; shift 2 ;;
    --only)      only="$2"; shift 2 ;;
    --no-pause)  pause=0; shift ;;
    --list)
      for i in {1..${#demos}}; do
        printf "%2d  %-58s dialog-demo %s\n" $i "${demos[$i]%%|*}" "${demos[$i]#*|}"
      done
      exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$patcher" ]]; then
  for candidate in /usr/local/bin/tpp/patcher /usr/local/bin/tpp_dev/patcher; do
    [[ -x "$candidate" ]] && { patcher="$candidate"; break; }
  done
fi
[[ -n "$patcher" && -x "$patcher" ]] || { echo "patcher not found; pass --patcher <path>." >&2; exit 1; }
(( EUID == 0 )) || { echo "Run with sudo: dialog-demo needs root." >&2; exit 1; }

# ── Run ───────────────────────────────────────────────────────────────────────

echo "Using $patcher"
results=()
total=${#demos}

for i in {1..$total}; do
  (( only > 0 && i != only )) && continue
  (( i < from )) && continue

  name="${demos[$i]%%|*}"
  args=(${=demos[$i]#*|})

  echo
  echo "── $i/$total  $name"
  echo "   patcher dialog-demo ${args[*]} ${extra[*]}"

  if (( pause )); then
    read -r "reply?   Return to run, s to skip, q to quit: " < /dev/tty
    case "$reply" in
      q|Q) results+=("$i|$name|not run"); break ;;
      s|S) results+=("$i|$name|skipped"); continue ;;
    esac
  fi

  "$patcher" dialog-demo "${args[@]}" "${extra[@]}"
  rc=$?
  if (( rc == 0 )); then results+=("$i|$name|ok"); else results+=("$i|$name|exit $rc"); fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "── Summary"
for r in "${results[@]}"; do
  IFS='|' read -r n label outcome <<< "$r"
  printf "%2s  %-58s %s\n" "$n" "$label" "$outcome"
done
