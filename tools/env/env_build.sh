#!/bin/bash
#PBS -N env_build
#PBS -P yj27
#PBS -q copyq
#PBS -l ncpus=1
#PBS -l mem=50GB
#PBS -l walltime=01:30:00
#PBS -l storage=gdata/vk83+gdata/yj27+scratch/yj27
#PBS -l wd
#PBS -j oe

## Build a test conda environment from a containerised-environments-infra environment.yml,
## to check that the spec solves and installs before opening a PR (each staging build needs
## admin approval).
##
## Usage (from the cookbook root):
##   qsub -v ENV_NAME=cc-cookbook tools/env/env_build.sh     ## batch job (user or Claude)
##   bash tools/env/env_build.sh cc-cookbook                  ## inside a `qsub -I` session on copyq
## Optional variables:
##   ENV_FILE=<path>   environment.yml to build (default: $INFRA_DIR/environments/$ENV_NAME/environment.yml)
##
## Result: env at $ENVS_DIR/test-$ENV_NAME (rebuilt from scratch every time), log and package list
## in $RUNS_DIR/build/. The last log line is `BUILD OK` or `BUILD FAILED`.
## copyq is used because it is the queue with internet access (package downloads).

set -uo pipefail

## Under PBS the script runs from a spool copy, so look for env_common.sh next to the original
## script, then relative to the submission directory.
for dir in "$(dirname "${BASH_SOURCE[0]}")" "${PBS_O_WORKDIR:-.}/tools/env" "${PBS_O_WORKDIR:-.}"; do
    if [[ -f "$dir/env_common.sh" ]]; then
        source "$dir/env_common.sh"
        break
    fi
done
if [[ -z "${ENVS_DIR:-}" ]]; then
    echo "env_common.sh not found: submit from the cookbook root or from tools/env/" >&2
    exit 2
fi

ENV_NAME="${1:-${ENV_NAME:-}}"
if [[ ! "$ENV_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Usage: qsub -v ENV_NAME=<name> env_build.sh   |   bash env_build.sh <name>" >&2
    exit 2
fi
ENV_FILE="${ENV_FILE:-$INFRA_DIR/environments/$ENV_NAME/environment.yml}"
PREFIX="$ENVS_DIR/test-$ENV_NAME"
STAMP="$(date +%Y%m%dT%H%M)"
JOB="${PBS_JOBID:-nojob}"
LOG="$RUNS_DIR/build/${ENV_NAME}_${STAMP}_${JOB%%.*}.log"

mkdir -p "$ENVS_DIR" "$RUNS_DIR/build"
exec > >(tee -a "$LOG") 2>&1

echo "## env_build: $ENV_NAME"
echo "date:     $(date '+%F %T')   host: $(hostname)   job: $JOB"
echo "env file: $ENV_FILE"
echo "prefix:   $PREFIX"
echo "log:      $LOG"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "BUILD FAILED: environment file not found"
    exit 2
fi

## Record exactly what was built (the file may be uncommitted in the infra repo).
ENV_FILE_DIR="$(dirname "$ENV_FILE")"
if git -C "$ENV_FILE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "infra repo: branch $(git -C "$ENV_FILE_DIR" branch --show-current)," \
         "HEAD $(git -C "$ENV_FILE_DIR" log -1 --format=%h)," \
         "file status: '$(git -C "$ENV_FILE_DIR" status --short -- "$ENV_FILE")'"
fi
echo "---- environment.yml"
cat "$ENV_FILE"
echo "----"

## Rebuild from scratch, so the spec alone reproduces the environment.
## Only ever delete a test-* env inside ENVS_DIR.
if [[ -d "$PREFIX" ]]; then
    case "$PREFIX" in
        "$ENVS_DIR"/test-?*) echo "removing previous build $PREFIX"; rm -rf -- "$PREFIX" ;;
        *) echo "BUILD FAILED: refusing to delete $PREFIX"; exit 2 ;;
    esac
fi

SECONDS=0
"$MAMBA_EXE" create --prefix "$PREFIX" --no-rc -y \
    -c accessnri -c conda-forge -c nodefaults -f "$ENV_FILE"
rc=$?

if (( rc == 0 )); then
    LIST="${LOG%.log}.list.txt"
    "$MAMBA_EXE" list --prefix "$PREFIX" > "$LIST"
    echo "python: $("$PREFIX/bin/python" --version 2>&1)"
    echo "package list: $LIST"
    echo "BUILD OK: $PREFIX ($((SECONDS / 60)) min)"
else
    echo "BUILD FAILED: micromamba exit $rc ($((SECONDS / 60)) min)"
fi
exit "$rc"
