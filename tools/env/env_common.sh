## Shared settings for the tools/env scripts. Sourced by them, not run directly.
## Override any of these by exporting it before calling a script, or with `qsub -v NAME=value`.

## micromamba shipped with the ACCESS-NRI containerised environments (needs vk83 membership)
: "${MAMBA_EXE:=/g/data/vk83/apps/base_conda/bin/micromamba}"
## package cache and micromamba root (large; on scratch)
: "${MAMBA_ROOT_PREFIX:=/scratch/${PROJECT}/${USER}/micromamba_cache}"
## test environments are built here as test-<ENV_NAME>
: "${ENVS_DIR:=/scratch/${PROJECT}/${USER}/envs}"
## build logs and executed notebooks
: "${RUNS_DIR:=/scratch/${PROJECT}/${USER}/env_runs}"
## local clone of ACCESS-NRI/containerised-environments-infra
: "${INFRA_DIR:=/g/data/${PROJECT}/users/${USER}/source/access-nri/containerised-environments-infra}"
## module path, used only by `nb_run.sh` with `ENV_NAME=module:<name>` (local test envs ignore it).
## Default: production (released cc-* modules). Override to test other builds:
##   /g/data/vk83/staging/modules   staging build of an open PR
##   /g/data/yj27/public/modules    old venv baseline (module:pyvenv/coastal-commons-recipes)
: "${MODULE_USE_DIR:=/g/data/vk83/modules}"
## module path for `ENV_NAME=staging:<name/ver>` (staging builds of open PRs; not the production dir)
: "${STAGING_MODULE_DIR:=/g/data/vk83/staging/modules}"

export MAMBA_EXE MAMBA_ROOT_PREFIX ENVS_DIR RUNS_DIR INFRA_DIR MODULE_USE_DIR STAGING_MODULE_DIR
