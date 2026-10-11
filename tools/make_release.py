#!/usr/bin/env python3
"""Makes a numbered release from the build artifacts of a CI run, like releases/v1.0 and v1.1.

    vlc-hddvd# tools/make_release.py --job-id JOB_ID --version VERSION [--force]

    tools/make_release.py --job-id 38037000000 --version v1.2

--job-id is a job of the workflow run to package (e.g. its macOS or Windows build job); the artifacts of the
whole *run* are downloaded, since the GitHub artifacts API does not tie artifacts to jobs. Pass a run id and
it is used directly. --version names the directory to make below releases/ ("v1.2").

Downloaded artifacts (all but the excluded `vlc-sdk`) become one zip each, named after the artifact, with the
plugin binary at the zip root:  releases/v1.2/hddvd-macos-aarch64.zip.

`gh` must be installed and signed in; the repo is taken from this repo's git remote.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# The SDK artifact is an input to the other jobs, not a release piece.
EXCLUDE = {"vlc-sdk"}


def fail(msg):
    print(f"make_release: {msg}", file=sys.stderr)
    sys.exit(1)


class GhError(Exception):
    """A `gh` command exited nonzero."""


def gh(*args, cwd=REPO):
    proc = subprocess.run(["gh", *args], cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise GhError(f"gh {' '.join(args)} failed:\n{proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def repo():
    return json.loads(gh("repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]


def run_of(ref):
    """The workflow run of job `ref`, or `ref` itself if it already is a run id."""
    try:
        job = json.loads(gh("api", f"/repos/{repo()}/actions/jobs/{ref}"))
    except GhError as e:
        if "404" not in str(e):
            raise
        job = None
    if job is not None:
        print(f"job {ref}: {job.get('name', '?')!r} of run {job['run_id']}")
        return job["run_id"]
    try:
        gh("api", f"/repos/{repo()}/actions/runs/{ref}")
        print(f"run {ref}")
    except GhError:
        fail(f"{ref} is neither a job id nor a run id")
    return ref


def artifacts(run):
    """The run's live (name, size) artifact pairs, minus the excluded ones."""
    out = json.loads(gh("api", f"/repos/{repo()}/actions/runs/{run}/artifacts"))
    found = [(a["name"], a["size_in_bytes"]) for a in out["artifacts"]]
    skipped = [n for n, _ in found if n in EXCLUDE]
    if not found:
        sys.exit(f"make_release: run {run} has no artifacts")
    if skipped:
        print(f"skipped {' and '.join(skipped)}")
    return [(n, s) for n, s in found if n not in EXCLUDE]


def download(run, name, into):
    gh("run", "download", str(run), "--name", name, "--dir", into)


def zip_dir(src, dst):
    files = []
    for root, _, names in os.walk(src):
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), src)
            files.append(rel.replace(os.sep, "/"))
    if not files:
        sys.exit(f"make_release: artifact {os.path.basename(src)} downloaded empty")
    # The release zips hold the plugin binary at the root; a multi-file artifact keeps its paths.
    arc = {f: os.path.basename(f) for f in files} if len(files) == 1 else {f: f for f in files}
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(files):
            z.write(os.path.join(src, f), arc[f])
    return arc


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[1], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--job-id", required=True, help="a job id of the run (a run id also works)")
    ap.add_argument("--version", required=True, help='release directory, as in "v1.2"')
    ap.add_argument("--force", action="store_true", help="replace an existing releases/VERSION")
    args = ap.parse_args()

    run = run_of(args.job_id)
    arts = artifacts(run)  # validated before anything is created

    out = os.path.join(REPO, "releases", args.version)
    if os.path.exists(out):
        if not args.force:
            fail(f"{args.version}: already exists (use --force to replace)")
        subprocess.run(["rm", "-rf", out], check=True)
    os.makedirs(out)

    with tempfile.TemporaryDirectory() as tmp:
        for name, size in arts:
            into = os.path.join(tmp, name)
            print(f"downloading {name} ({size / 2**20:.1f} MiB)…")
            download(run, name, into)
            print("packing…")
            arc = zip_dir(into, os.path.join(out, name + ".zip"))
            for f in sorted(arc):
                print(f"  {arc[f]}")
    print(f"\nvlc-hddvd/releases/{args.version}:")
    for z in sorted(os.listdir(out)):
        print(f"  {z} ({os.path.getsize(os.path.join(out, z)) / 2**20:.1f} MiB)")


if __name__ == "__main__":
    try:
        main()
    except GhError as e:
        fail(str(e))
