"""Write the .status report for one notebook run of nb_run.sh.

Called by nb_run.sh after each run (output redirected to <stem>.status). It can also be rerun
by hand for an earlier PBS job, with the env's own python:
    <prefix>/bin/python -I tools/env/nb_status.py --notebook recipes/roms/x.ipynb \
        --executed <out>/x.ipynb --log <out>/x.log --env-name cc-cookbook \
        --prefix <prefix> --jupyter <prefix>/bin/jupyter --exit-code 0 --runtime 540 \
        --job 182990273.gadi-pbs

Sections: Result, Environment used, Clean output, Resources. The first line is a one-line
summary, so `head -qn1 <runs>/nb/*/*/*/*/*.status` gives a pass/fail table. Standard library only.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
## e.g. "ModuleNotFoundError: No module named 'x'" (the kernel's own exception line)
EXCEPTION_LINE = re.compile(r"^\s*([A-Za-z_][\w.]*(?:Error|Exception|Exit|Interrupt))\b:?\s*(.*)$")
MAX_TEXT = 160
MAX_LISTED = 10
QSTAT_FIELDS = (
    "queue", "interactive",
    "resources_used.walltime", "resources_used.mem", "resources_used.cput",
    "Resource_List.walltime", "Resource_List.mem", "Resource_List.ncpus",
)
MEM_UNITS_GB = {"b": 1 / 1024**3, "kb": 1 / 1024**2, "mb": 1 / 1024, "gb": 1, "tb": 1024}
## nbclient's per-cell timing metadata (recorded by default during --execute)
TIMING_START = "iopub.execute_input"
TIMING_END = "shell.execute_reply"
## slack around the run window, in seconds (clock skew, kernel start-up)
WINDOW_MARGIN = 60


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--notebook", required=True, help="source notebook (as given to nb_run.sh)")
    parser.add_argument("--executed", required=True, help="executed copy written by nbconvert")
    parser.add_argument("--log", required=True, help="nb_run.sh log of this run")
    parser.add_argument("--env-name", required=True, help="ENV_NAME given to nb_run.sh")
    parser.add_argument("--prefix", default="", help="conda prefix of the env (empty for modules)")
    parser.add_argument("--jupyter", required=True, help="jupyter executable used for the run")
    parser.add_argument("--exit-code", type=int, required=True, help="nbconvert exit code")
    parser.add_argument("--runtime", type=int, default=0, help="notebook run time in seconds")
    parser.add_argument(
        "--run-start", type=int, default=None,
        help="run start, epoch seconds (`date +%%s`); by hand: `date -d '<log date>' +%%s`",
    )
    parser.add_argument("--job", default="nojob", help="PBS job id")
    return parser.parse_args()


def text_of(output):
    """Return the text of a stream output (str or list of str)."""
    text = output.get("text", "")
    return "".join(text) if isinstance(text, list) else text


def first_line(text):
    """Return the first non-empty line, without ANSI colours, truncated."""
    for line in ANSI.sub("", text).splitlines():
        if line.strip():
            return line.strip()[:MAX_TEXT]
    return ""


def first_error_in_log(log_path):
    """Return the kernel's exception line from a failed run's log, if any."""
    try:
        lines = ANSI.sub("", Path(log_path).read_text(errors="replace")).splitlines()
    except OSError:
        return ""
    found = [
        line.strip() for line in lines
        if EXCEPTION_LINE.match(line) and "CellExecutionError" not in line
    ]
    return found[-1][:MAX_TEXT] if found else ""


def parse_timestamp(value):
    """Return an aware datetime from nbclient's ISO timestamp, or None."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def execution_check(args):
    """Check that the executed copy's outputs were all produced by this run.

    nbclient runs every non-empty code cell in a fresh kernel, clearing its outputs first, and
    stamps it with timing metadata. A cell without a stamp was not run (e.g. tagged
    `skip-execution`) and may still hold outputs saved in the source notebook.
    """
    cells = [c for c in json.loads(Path(args.executed).read_text())["cells"] if c["cell_type"] == "code"]
    expected, not_run, counts, starts, ends = [], [], [], [], []
    for number, cell in enumerate(cells, start=1):
        source = cell.get("source", "")
        source = "".join(source) if isinstance(source, list) else source
        if not source.strip():
            continue  ## empty cells are never executed and hold no outputs
        expected.append(number)
        timing = cell.get("metadata", {}).get("execution", {})
        start, end = parse_timestamp(timing.get(TIMING_START)), parse_timestamp(timing.get(TIMING_END))
        if start is None:
            not_run.append(number)
            continue
        counts.append(cell.get("execution_count"))
        starts.append(start)
        ends.append(end or start)

    problems = []
    if not_run:
        listed = ", ".join(str(n) for n in not_run[:MAX_LISTED])
        problems.append(f"code cells not run in this run (old outputs possible): {listed}")
    if counts != list(range(1, len(counts) + 1)):
        problems.append(f"execution counts not 1..{len(counts)} in order: {counts}")
    window = ""
    if starts:
        first, last = min(starts).astimezone(), max(ends).astimezone()
        window = f", {first:%H:%M:%S}-{last:%H:%M:%S}"
        if args.run_start is not None:
            run_end = args.run_start + args.runtime if args.runtime > 0 else time.time()
            outside = [
                n for n, s, e in zip([n for n in expected if n not in not_run], starts, ends)
                if s.timestamp() < args.run_start - WINDOW_MARGIN or e.timestamp() > run_end + WINDOW_MARGIN
            ]
            if outside:
                listed = ", ".join(str(n) for n in outside[:MAX_LISTED])
                more = ", ..." if len(outside) > MAX_LISTED else ""
                problems.append(f"timestamps outside this run: {len(outside)} code cells ({listed}{more})")
            else:
                started = datetime.fromtimestamp(args.run_start, timezone.utc).astimezone()
                window += f" (inside the run, started {started:%H:%M:%S})"

    ran = f"{len(starts)}/{len(expected)} code cells, counts 1-{len(counts)}{window}"
    if problems:
        return [f"  executed in run: WARNING: {ran}"] + [f"    - {p}" for p in problems]
    return [f"  executed in run: OK: {ran}"]


def section_result(args):
    lines = ["Result"]
    if args.exit_code == 0:
        lines.append("  result:         PASS")
    else:
        lines.append(f"  result:         FAIL (nbconvert exit {args.exit_code})")
        error = first_error_in_log(args.log)
        lines.append(f"  first error:    {error or 'not found; see the log'}")
    if Path(args.executed).is_file():
        lines.append(f"  executed copy:  {args.executed}")
        try:
            lines.extend(execution_check(args))
        except (OSError, KeyError, ValueError) as err:
            lines.append(f"  executed in run: not checked ({err})")
    else:
        lines.append("  executed copy:  not written (nbconvert writes it only when every cell succeeds)")
    lines.append(f"  log:            {args.log}")
    return lines


def python_version(python):
    try:
        out = subprocess.run(
            [python, "-I", "-c", "import platform; print(platform.python_version())"],
            capture_output=True, text=True, timeout=60, check=True,
        )
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def section_environment(args):
    lines = ["Environment used"]
    where = f" ({args.prefix})" if args.prefix else " (module)"
    lines.append(f"  env:            {args.env_name}{where}")
    try:
        out = subprocess.run(
            [args.jupyter, "kernelspec", "list", "--json"],
            capture_output=True, text=True, timeout=120, check=True,
        )
        spec = json.loads(out.stdout)["kernelspecs"]["python3"]
        spec_dir = spec["resource_dir"]
        kernel_python = spec["spec"]["argv"][0]
    except (OSError, subprocess.SubprocessError, KeyError, ValueError) as err:
        lines.append(f"  kernel:         could not read the python3 kernelspec ({err})")
        return lines
    if kernel_python in ("python", "python3"):
        ## jupyter_client replaces a bare `python` with its own interpreter
        kernel_python = sys.executable
    lines.append(f"  kernel python:  {kernel_python} ({python_version(kernel_python)})")
    lines.append(f"  kernelspec:     {spec_dir}")

    usersite_off = os.environ.get("PYTHONNOUSERSITE", "") not in ("", "0")
    jupyter_dir = os.environ.get("JUPYTER_DATA_DIR", "")
    user_kernels_hidden = bool(jupyter_dir) and not jupyter_dir.startswith(str(Path.home()))
    lines.append(
        "  isolation:      user site-packages "
        + ("off" if usersite_off else "ON (~/.local packages visible)")
        + ", user kernelspecs "
        + ("hidden" if user_kernels_hidden else "VISIBLE (~/.local/share/jupyter)")
    )

    problems = []
    if args.prefix:
        prefix = args.prefix.rstrip("/") + "/"
        if not kernel_python.startswith(prefix):
            problems.append("kernel python is outside the env")
        if not spec_dir.startswith(prefix):
            problems.append("kernelspec is outside the env")
    if not usersite_off:
        problems.append("user site-packages on")
    if not user_kernels_hidden:
        problems.append("user kernelspecs visible")
    if problems:
        lines.append("  check:          WARNING: " + "; ".join(problems))
    elif args.prefix:
        lines.append("  check:          OK: kernel and kernelspec inside the env, user setup isolated")
    else:
        lines.append("  check:          OK: user setup isolated (module: kernel runs in the container)")
    return lines


def section_outputs(args):
    lines = ["Clean output"]
    path = Path(args.executed)
    if not path.is_file():
        lines.append("  not checked: no executed copy (see Result and the log)")
        return lines
    try:
        cells = [c for c in json.loads(path.read_text())["cells"] if c["cell_type"] == "code"]
    except (OSError, KeyError, ValueError) as err:
        lines.append(f"  not checked: could not read {path} ({err})")
        return lines

    errors, stderr = [], []
    for number, cell in enumerate(cells, start=1):
        for output in cell.get("outputs", []):
            if output["output_type"] == "error":
                errors.append((number, f"{output.get('ename')}: {output.get('evalue')}"[:MAX_TEXT]))
            elif output["output_type"] == "stream" and output.get("name") == "stderr":
                stderr.append((number, first_line(text_of(output))))

    lines.append(f"  code cells:     {len(cells)}")
    lines.append(f"  error outputs:  {len(errors)}")
    lines.append(f"  stderr outputs: {len(stderr)} (warnings, progress bars, logging)")
    if not errors and not stderr:
        lines.append("  verdict:        clean")
    else:
        lines.append("  verdict:        review the cells below (the run itself still passed)")
        for number, text in (errors + stderr)[:MAX_LISTED]:
            lines.append(f"  - code cell {number}: {text}")
        if len(errors) + len(stderr) > MAX_LISTED:
            lines.append(f"  - ... {len(errors) + len(stderr) - MAX_LISTED} more")
    return lines


def to_seconds(hms):
    try:
        hours, minutes, seconds = (int(part) for part in hms.split(":"))
    except ValueError:
        return None
    return hours * 3600 + minutes * 60 + seconds


def to_gb(value):
    match = re.fullmatch(r"([\d.]+)([a-zA-Z]*)", value or "")
    if not match or match.group(2).lower() not in MEM_UNITS_GB:
        return value or "?"
    return f"{float(match.group(1)) * MEM_UNITS_GB[match.group(2).lower()]:.2f} GB"


def qstat_fields(job):
    out = subprocess.run(
        ["qstat", "-x", "-f", job], capture_output=True, text=True, timeout=60, check=True,
    )
    fields = {}
    for line in out.stdout.splitlines():
        key, sep, value = line.strip().partition(" = ")
        if sep and key in QSTAT_FIELDS:
            fields[key] = value.strip()
    return fields


def section_resources(args):
    lines = ["Resources"]
    lines.append(f"  notebook run:   {args.runtime // 60} min {args.runtime % 60} s")
    if args.job in ("", "nojob"):
        lines.append("  PBS:            n/a (not run as a PBS job)")
        return lines
    try:
        pbs = qstat_fields(args.job)
    except (OSError, subprocess.SubprocessError) as err:
        lines.append(f"  PBS:            n/a (qstat failed: {err}); see the PBS .o file")
        return lines

    if pbs.get("interactive", "").lower() == "true":
        lines.append("  note:           interactive job: usage covers the whole qsub -I session")
    lines.append(f"  queue:          {pbs.get('queue', '?')}")
    lines.append(
        f"  walltime:       {pbs.get('resources_used.walltime', '?')}"
        f" of {pbs.get('Resource_List.walltime', '?')}"
    )
    lines.append(
        f"  memory:         {to_gb(pbs.get('resources_used.mem'))}"
        f" of {to_gb(pbs.get('Resource_List.mem'))}"
    )
    cput = pbs.get("resources_used.cput", "?")
    ncpus = pbs.get("Resource_List.ncpus", "?")
    cpu_line = f"  cpu time:       {cput} on {ncpus} CPUs"
    used, wall = to_seconds(cput), to_seconds(pbs.get("resources_used.walltime", ""))
    if used is not None and wall and ncpus.isdigit():
        cpu_line += f" ({100 * used / (wall * int(ncpus)):.0f}% CPU use)"
    lines.append(cpu_line)
    lines.append("  (PBS sample at report time; final numbers and SU in the PBS .o file)")
    return lines


def main():
    args = parse_args()
    result = "PASS" if args.exit_code == 0 else f"FAIL (exit {args.exit_code})"
    summary = (
        f"{result}  {args.notebook}  env={args.env_name}  job={args.job}"
        f"  {args.runtime // 60} min"
    )
    report = [summary, ""]
    for section in (section_result, section_environment, section_outputs, section_resources):
        report.extend(section(args))
        report.append("")
    print("\n".join(report).rstrip())


if __name__ == "__main__":
    main()
