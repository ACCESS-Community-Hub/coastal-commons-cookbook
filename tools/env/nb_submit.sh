#!/bin/bash
## Submit tools/env/nb_run.sh jobs for many notebooks, with per-notebook options from nb_jobs.conf.
## Runs on the login node (not a PBS job). Run from the cookbook root.
##
## Usage:
##   tools/env/nb_submit.sh [-n | -y] [-e ENV_NAME] <dir|notebook> [...] [-- <extra qsub options>]
##   tools/env/nb_submit.sh -n recipes/roms                          ## dry run: print commands only
##   tools/env/nb_submit.sh -e staging:cc-cookbook/<ver> recipes/roms  ## print, ask, submit
## Options:
##   -n   dry run (print the qsub commands, submit nothing)
##   -y   submit without asking
##   -e   environment, as in nb_run.sh: <name> (test env) | module:<name/ver> (production) |
##        staging:<name/ver> (staging) | /abs/prefix. Default: $ENV_NAME, else cc-cookbook.
## Extra qsub options after `--` apply to every job and come last (they override the conf).
## Notebooks failing a pre-check (env missing, storage project not in your groups) are skipped.
## Submitted jobs are listed in $RUNS_DIR/nb/submissions/<YYYYmmddTHHMM>.txt.

set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TOOLS_DIR/env_common.sh"
RUNNER="tools/env/nb_run.sh"
CONF="$TOOLS_DIR/nb_jobs.conf"

if [[ ! -f "$RUNNER" ]]; then
    echo "Run from the cookbook root ($RUNNER not found)" >&2
    exit 2
fi

usage() { sed -n '5,9p' "${BASH_SOURCE[0]}" | sed 's/^## \{0,1\}//' >&2; exit 2; }

## ---- arguments
MODE="ask"
ENV="${ENV_NAME:-cc-cookbook}"
TARGETS=()
EXTRA=()
while (( $# )); do
    case "$1" in
        -n) MODE="dry" ;;
        -y) MODE="yes" ;;
        -e) shift; ENV="${1:-}"; [[ -z "$ENV" ]] && usage ;;
        -h | --help) usage ;;
        --) shift; EXTRA=("$@"); break ;;
        -*) echo "Unknown option: $1" >&2; usage ;;
        *) TARGETS+=("$1") ;;
    esac
    shift
done
(( ${#TARGETS[@]} )) || usage

## ---- notebooks: directories searched recursively, sorted, duplicates removed
NOTEBOOKS=()
for t in "${TARGETS[@]}"; do
    t="${t#./}"
    if [[ -d "$t" ]]; then
        while IFS= read -r f; do NOTEBOOKS+=("${f#./}"); done < <(
            find "$t" -name '*.ipynb' -not -path '*/.ipynb_checkpoints/*')
    elif [[ -f "$t" && "$t" == *.ipynb ]]; then
        NOTEBOOKS+=("$t")
    else
        echo "skip: $t (not a directory or notebook)" >&2
    fi
done
mapfile -t NOTEBOOKS < <(printf '%s\n' "${NOTEBOOKS[@]}" | sed 's#//*#/#g' | sort -u | sed '/^$/d')
(( ${#NOTEBOOKS[@]} )) || { echo "No notebooks found" >&2; exit 2; }

## ---- config: join continuation lines, drop comments and blank lines
CONF_PREFIX=()
CONF_OPTS=()
if [[ -f "$CONF" ]]; then
    while IFS= read -r line; do
        read -r prefix opts <<< "$line"
        CONF_PREFIX+=("$prefix")
        CONF_OPTS+=("$opts")
    done < <(sed -e 's/[[:space:]]*#.*$//' "$CONF" | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' |
             sed -e '/^[[:space:]]*$/d')
fi

## ---- environment pre-check (once)
ENV_PROBLEM=""
case "$ENV" in
    module:* | staging:*)
        [[ "$ENV" == staging:* ]] && MDIR="$STAGING_MODULE_DIR" || MDIR="$MODULE_USE_DIR"
        MOD="${ENV#*:}"
        [[ -e "$MDIR/$MOD" || -e "$MDIR/$MOD.lua" ]] || ENV_PROBLEM="module $MOD not found in $MDIR"
        ;;
    /*) [[ -x "$ENV/bin/jupyter" ]] || ENV_PROBLEM="no jupyter in $ENV" ;;
    *) [[ -x "$ENVS_DIR/test-$ENV/bin/jupyter" ]] || ENV_PROBLEM="test env $ENVS_DIR/test-$ENV missing" ;;
esac
if [[ -n "$ENV_PROBLEM" ]]; then
    echo "Environment problem: $ENV_PROBLEM" >&2
    exit 2
fi

## header default storage list of nb_run.sh (used when no -l storage= is given)
DEFAULT_STORAGE="$(sed -n 's/^#PBS -l storage=//p' "$RUNNER")"
MY_GROUPS=" $(id -Gn) "

## ---- build one command per notebook
CMDS=()
CMD_NB=()
CMD_OPTS=()
for nb in "${NOTEBOOKS[@]}"; do
    ## longest matching prefix
    best=-1; best_len=0
    for i in "${!CONF_PREFIX[@]}"; do
        p="${CONF_PREFIX[$i]}"
        if [[ "$nb" == "$p"* && ${#p} -gt $best_len ]]; then best=$i; best_len=${#p}; fi
    done
    opts=""
    (( best >= 0 )) && opts="${CONF_OPTS[$best]}"

    ## split: NAME=value -> -v list, the rest -> qsub options
    read -r -a tokens <<< "$opts"
    qopts=(); vlist="NB=$nb,ENV_NAME=$ENV"
    for tok in "${tokens[@]}"; do
        if [[ "$tok" =~ ^[A-Z_][A-Z0-9_]*= ]]; then vlist+=",$tok"; else qopts+=("$tok"); fi
    done
    qopts+=("${EXTRA[@]}")

    ## storage pre-check: every project in the effective storage list must be one of my groups
    storage="$DEFAULT_STORAGE"
    for tok in "${qopts[@]}"; do
        [[ "$tok" == *storage=* ]] && storage="$(sed 's/.*storage=\([^,]*\).*/\1/' <<< "$tok")"
    done
    missing=""
    for s in ${storage//+/ }; do
        proj="${s#*/}"
        [[ "$MY_GROUPS" == *" $proj "* ]] || missing+=" $proj"
    done
    if [[ -n "$missing" ]]; then
        echo "skip: $nb (not a member of:$missing)" >&2
        continue
    fi

    parent="$(basename "$(dirname "$nb")")"
    name="nb_${parent}_$(basename "$nb" .ipynb)"
    cmd=(qsub -N "$name" "${qopts[@]}" -v "$vlist" "$RUNNER")
    ## options contain no spaces, so the plain join is a valid, readable command
    CMDS+=("${cmd[*]}")
    CMD_NB+=("$nb")
    CMD_OPTS+=("${qopts[*]:-defaults}")
done

(( ${#CMDS[@]} )) || { echo "Nothing to submit" >&2; exit 1; }
echo "## env: $ENV   (${#CMDS[@]} job(s))"
printf '%s\n' "${CMDS[@]}"

case "$MODE" in
    dry) exit 0 ;;
    ask)
        read -r -p "Submit ${#CMDS[@]} job(s)? [y/N] " ans
        [[ "$ans" == [yY]* ]] || { echo "Nothing submitted"; exit 0; }
        ;;
esac

## ---- submit and write the manifest
MANIFEST="$RUNS_DIR/nb/submissions/$(date +%Y%m%dT%H%M).txt"
mkdir -p "$(dirname "$MANIFEST")"
echo "## env: $ENV   submitted $(date '+%F %T')" >> "$MANIFEST"
for i in "${!CMDS[@]}"; do
    if job="$(eval "${CMDS[$i]}")"; then
        printf '%s | %s | %s\n' "$job" "${CMD_NB[$i]}" "${CMD_OPTS[$i]}" | tee -a "$MANIFEST"
    else
        echo "FAILED to submit: ${CMD_NB[$i]}" | tee -a "$MANIFEST" >&2
    fi
done
echo "manifest: $MANIFEST"
case "$ENV" in
    module:* | staging:*) label="${ENV%%:*}_$(tr / _ <<< "${ENV#*:}")" ;;
    /*) label="$(basename "$ENV")" ;;
    *) label="test-$ENV" ;;
esac
echo "results when done: head -qn1 $RUNS_DIR/nb/$label/*/*/*/*.status"
