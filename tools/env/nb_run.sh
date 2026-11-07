#!/bin/bash
#PBS -N nb_run
#PBS -P yj27
#PBS -q normal
#PBS -l ncpus=4
#PBS -l mem=16GB
#PBS -l walltime=01:00:00
#PBS -l storage=gdata/vk83+gdata/yj27+scratch/yj27
#PBS -l wd
#PBS -j oe

## Execute one notebook headless against an environment and record PASS/FAIL.
## The source notebook is never modified: the executed copy goes to $RUNS_DIR/nb/.
##
## Usage (from the cookbook root):
##   qsub -v NB=recipes/roms/sst_model_evaluation.ipynb,ENV_NAME=cc-cookbook tools/env/nb_run.sh
##   bash tools/env/nb_run.sh recipes/roms/sst_model_evaluation.ipynb cc-cookbook   ## inside qsub -I
## ENV_NAME:
##   <name>              test env built by env_build.sh ($ENVS_DIR/test-<name>)
##   module:<name/ver>   a module from $MODULE_USE_DIR (production), e.g. module:cc-cookbook/dev
##   staging:<name/ver>  a module from $STAGING_MODULE_DIR (staging build of an open PR)
##   /abs/path           any other conda prefix
## Optional: CELL_TIMEOUT (seconds per cell, default 1800).
##
## Queue: compute nodes on `normal` have NO internet. Notebooks that download data (Argo, ERDDAP,
## THREDDS, Copernicus) need `qsub -q copyq -l ncpus=1 ...`. Command-line options override the
## header, e.g. extra `-l storage=...` for data in other projects.
##
## Result: $RUNS_DIR/nb/<env label>/<notebook dir>/<stem>/ holds the executed notebook (on
## success), <stem>.log and <stem>.status, e.g. nb/test-cc-cookbook/recipes/roms/model_eval_argo/.
## The status (written by nb_status.py) opens with a one-line PASS/FAIL summary, then sections
## Result, Environment used, Clean output, Resources.
## Pass/fail table of all runs: head -qn1 $RUNS_DIR/nb/*/*/*/*/*.status
## An earlier run in the same folder is moved to previous_<job id>/ first.
## Many notebooks at once, with per-notebook options: tools/env/nb_submit.sh.

set -uo pipefail

for dir in "$(dirname "${BASH_SOURCE[0]}")" "${PBS_O_WORKDIR:-.}/tools/env" "${PBS_O_WORKDIR:-.}"; do
    if [[ -f "$dir/env_common.sh" ]]; then
        source "$dir/env_common.sh"
        TOOLS_DIR="$dir"
        break
    fi
done
if [[ -z "${ENVS_DIR:-}" ]]; then
    echo "env_common.sh not found: submit from the cookbook root or from tools/env/" >&2
    exit 2
fi

NB="${1:-${NB:-}}"
ENV_NAME="${2:-${ENV_NAME:-}}"
if [[ -z "$NB" || -z "$ENV_NAME" ]]; then
    echo "Usage: qsub -v NB=<notebook>,ENV_NAME=<env> nb_run.sh   |   bash nb_run.sh <notebook> <env>" >&2
    exit 2
fi
if [[ ! -f "$NB" ]]; then
    echo "Notebook not found: $NB (relative paths are from the submission directory)" >&2
    exit 2
fi

## Resolve the environment
case "$ENV_NAME" in
    module:* | staging:*)
        KIND="${ENV_NAME%%:*}"
        MODULE="${ENV_NAME#*:}"
        [[ "$KIND" == staging ]] && MODULE_DIR="$STAGING_MODULE_DIR" || MODULE_DIR="$MODULE_USE_DIR"
        ## the module function may reference unset variables: relax nounset around it
        set +u
        module use "$MODULE_DIR"
        module load "$MODULE" || { echo "module load $MODULE ($MODULE_DIR) failed" >&2; exit 2; }
        set -u
        JUPYTER="$(command -v jupyter)"
        PYTHON="$(command -v python)"
        LABEL="${KIND}_${MODULE//\//_}"
        ;;
    /*)
        PREFIX="$ENV_NAME"
        LABEL="$(basename "$PREFIX")"
        ;;
    *)
        PREFIX="$ENVS_DIR/test-$ENV_NAME"
        LABEL="test-$ENV_NAME"
        ;;
esac
if [[ -n "${PREFIX:-}" ]]; then
    JUPYTER="$PREFIX/bin/jupyter"
    PYTHON="$PREFIX/bin/python"
    ## Put the env first on PATH, so `python` and subprocesses resolve to it.
    export PATH="$PREFIX/bin:$PATH"
fi
if [[ ! -x "${JUPYTER:-}" ]]; then
    echo "jupyter not found for ENV_NAME=$ENV_NAME" >&2
    exit 2
fi

## Isolate the run from the user's own setup, as in the container:
## - ~/.local site-packages would hide missing dependencies;
## - ~/.local/share/jupyter/kernels/python3 points to another venv and would take precedence
##   over the env's own python3 kernel.
export PYTHONNOUSERSITE=1
unset PYTHONPATH JUPYTER_PATH
export JUPYTER_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nb_run_jupyter.XXXXXX")"
trap 'rm -rf -- "$JUPYTER_DATA_DIR"' EXIT

NB_REL="${NB#./}"
STEM="$(basename "$NB_REL" .ipynb)"
## one folder per notebook: <env label>/<notebook dir>/<notebook name>/
OUT_DIR="$RUNS_DIR/nb/$LABEL/$(dirname "$NB_REL")/$(basename "$NB_REL" .ipynb)"
LOG="$OUT_DIR/$STEM.log"
STATUS="$OUT_DIR/$STEM.status"
EXECUTED="$OUT_DIR/$STEM.ipynb"
JOB="${PBS_JOBID:-nojob}"
mkdir -p "$OUT_DIR"
## keep an earlier run: move its files to previous_<old job id>/ (fallback: the old log's time),
## so a failed run cannot show an old executed copy and comparisons stay possible
if compgen -G "$OUT_DIR/$STEM.*" > /dev/null; then
    OLD_ID=""
    [[ -f "$STATUS" ]] && OLD_ID="$(head -n1 "$STATUS" | grep -o 'job=[^ .]*' | cut -d= -f2)"
    if [[ -z "$OLD_ID" || "$OLD_ID" == nojob ]]; then
        OLD_ID="$(date -r "$(ls -t "$OUT_DIR/$STEM".* | head -n1)" +%Y%m%dT%H%M)"
    fi
    mkdir -p "$OUT_DIR/previous_$OLD_ID"
    mv -- "$OUT_DIR/$STEM".* "$OUT_DIR/previous_$OLD_ID/"
fi
exec > >(tee "$LOG") 2>&1

echo "## nb_run: $NB_REL"
echo "date: $(date '+%F %T')   host: $(hostname)   job: $JOB   queue: ${PBS_QUEUE:-none}"
echo "env:  $ENV_NAME"
echo "jupyter: $JUPYTER"
echo "---- kernel used (python3 must be inside the env above)"
"$JUPYTER" kernelspec list
echo "----"

RUN_START="$(date +%s)"
SECONDS=0
## The notebook's own kernel metadata is ignored (it names other envs); the kernel runs in the
## notebook's directory, so relative data paths behave as in an interactive session.
"$JUPYTER" nbconvert --to notebook --execute \
    --ExecutePreprocessor.kernel_name=python3 \
    --ExecutePreprocessor.timeout="${CELL_TIMEOUT:-1800}" \
    --output-dir "$OUT_DIR" --output "$STEM" "$NB"
rc=$?
RUNTIME=$SECONDS

## Status report: Result, Environment used, Clean output, Resources (first line = summary)
echo "---- status ($STATUS)"
if ! "$PYTHON" -I "$TOOLS_DIR/nb_status.py" \
        --notebook "$NB_REL" --executed "$EXECUTED" --log "$LOG" \
        --env-name "$ENV_NAME" --prefix "${PREFIX:-}" --jupyter "$JUPYTER" \
        --exit-code "$rc" --runtime "$RUNTIME" --run-start "$RUN_START" --job "$JOB" > "$STATUS"; then
    ## fallback: keep at least the one-line summary
    (( rc == 0 )) && RESULT="PASS" || RESULT="FAIL (exit $rc)"
    echo "$RESULT  $NB_REL  env=$ENV_NAME  job=$JOB  $((RUNTIME / 60)) min  (nb_status.py failed)" > "$STATUS"
fi
cat "$STATUS"
exit "$rc"
