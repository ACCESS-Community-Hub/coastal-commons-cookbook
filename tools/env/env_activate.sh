## Activate a test environment built by env_build.sh in the current shell.
## It must be *sourced* (a script that is run cannot change your shell):
##   source tools/env/env_activate.sh cc-cookbook
## Login node: fine for light checks (imports, versions). Anything heavier: inside a `qsub -I` session.
## Leave the environment with: micromamba deactivate
##
## Claude does not use this (its shell state does not persist); it calls
## $ENVS_DIR/test-<name>/bin/python directly.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Source this file: source ${BASH_SOURCE[0]} <env_name>" >&2
    exit 2
fi

## No `set -e/-u` and `return` instead of `exit`: this runs in the user's own shell.
if [[ -z "${1:-}" ]]; then
    echo "Usage: source ${BASH_SOURCE[0]} <env_name>" >&2
    return 2
fi
source "$(dirname "${BASH_SOURCE[0]}")/env_common.sh" || return 2
if [[ ! -d "$ENVS_DIR/test-$1" ]]; then
    echo "No test env at $ENVS_DIR/test-$1 (build it first with env_build.sh)" >&2
    return 2
fi

eval "$("$MAMBA_EXE" shell hook --shell bash --root-prefix "$MAMBA_ROOT_PREFIX")"
micromamba activate "$ENVS_DIR/test-$1"
## As in the container: ignore packages in ~/.local
export PYTHONNOUSERSITE=1
echo "Activated $ENVS_DIR/test-$1 ($(python --version 2>&1)); user site-packages disabled."
