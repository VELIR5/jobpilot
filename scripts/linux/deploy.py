#!/usr/bin/env python3
"""Credential-free, CI-gated Linux release controller. Python standard library only."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = Path("/opt/jobpilot-deploy")
RELEASES = Path("/opt/jobpilot-releases")
LEGACY = Path("/opt/jobpilot")
DATA = LEGACY / "data/JobPilot"
UPLOADS = LEGACY / "data/uploads"
REPOSITORY = "VELIR5/jobpilot"
ORIGIN = "https://github.com/" + REPOSITORY + ".git"
API = "https://api.github.com/repos/" + REPOSITORY
LOCAL_HEALTH = "http://127.0.0.1:3000/api/health"
PUBLIC_HEALTH = "https://job.vcrelay.com/api/health"
SERVICE = "jobpilot.service"
BUILD_USER = "jobpilot-build"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def log(message):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message, flush=True)


def clean_env():
    # In particular, ignore root's credential-bearing Git URL rewrites and npmrc.
    return {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "NPM_CONFIG_USERCONFIG": "/nonexistent/npm-user.conf",
            "NPM_CONFIG_GLOBALCONFIG": "/nonexistent/npm-global.conf"}


def run(args, *, cwd=None, capture=False, check=True):
    return subprocess.run([str(x) for x in args], cwd=cwd, env=clean_env(),
                          check=check, text=True, capture_output=capture)


def api_json(path):
    request = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "jobpilot-deploy",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def master_tip():
    sha = api_json("/git/ref/heads/master")["object"]["sha"]
    if not SHA_RE.fullmatch(sha):
        raise RuntimeError("GitHub returned an invalid master SHA")
    return sha


def ci_success(sha):
    query = urllib.parse.urlencode({"branch": "master", "event": "push",
                                  "head_sha": sha, "per_page": 100})
    runs = api_json("/actions/workflows/ci.yml/runs?" + query)["workflow_runs"]
    matching = [item for item in runs if item.get("head_sha") == sha
                and item.get("head_branch") == "master" and item.get("event") == "push"
                and item.get("path", "").split("@")[0] == ".github/workflows/ci.yml"
                and item.get("head_repository", {}).get("full_name") == REPOSITORY]
    # A rerun in progress or newer failed run revokes an earlier success.
    if not matching:
        return False
    newest = max(matching, key=lambda item: (item.get("run_number", 0), item.get("run_attempt", 1)))
    return newest.get("status") == "completed" and newest.get("conclusion") == "success"


def atomic_text(path, value):
    descriptor, filename = tempfile.mkstemp(prefix=".deploy-", dir=path.parent)
    temporary = Path(filename)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, path)


def switch(target):
    temporary = ROOT / "current.new"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target, target_is_directory=True)
    os.replace(temporary, ROOT / "current")


def read_sha(release):
    metadata = release / ".release.env"
    if metadata.is_file():
        for line in metadata.read_text().splitlines():
            if line.startswith("JOBPILOT_RELEASE_SHA="):
                sha = line.split("=", 1)[1]
                if SHA_RE.fullmatch(sha):
                    return sha
    result = run(["git", "-C", release, "rev-parse", "HEAD"], capture=True, check=False)
    sha = result.stdout.strip()
    if result.returncode == 0 and SHA_RE.fullmatch(sha):
        return sha
    raise RuntimeError("Current release SHA is unavailable; bootstrap metadata first")


def git(*args, check=True):
    return run(["git", "--git-dir", ROOT / "repository.git", *args], capture=True, check=check)


def update_mirror():
    mirror = ROOT / "repository.git"
    if not mirror.exists():
        run(["git", "init", "--bare", mirror], capture=True)
    # Use an explicit public URL, not any repository-configured remote.
    git("fetch", "--no-tags", ORIGIN, "+refs/heads/master:refs/heads/master")
    return git("rev-parse", "refs/heads/master").stdout.strip()


def forward_only(previous, target):
    result = git("merge-base", "--is-ancestor", previous, target, check=False)
    if result.returncode != 0:
        raise RuntimeError("Non-forward history or unknown deployed commit; manual review required")


def freeze_release(release):
    for directory, dirs, files in os.walk(release, followlinks=False):
        for name in dirs + files:
            os.chown(Path(directory) / name, 0, 0, follow_symlinks=False)
    os.chown(release, 0, 0)
    release.chmod(0o700)


def build_release(sha):
    release = RELEASES / sha
    if release.exists():
        if (release / ".build-complete").is_file():
            log("Reusing previously completed build " + sha)
            return release
        raise RuntimeError("Incomplete release directory exists; review and remove it manually")
    builder = pwd.getpwnam(BUILD_USER)
    release.mkdir(mode=0o700)
    try:
        archive = ROOT / "source.tar"
        with archive.open("wb") as stream:
            subprocess.run(["git", "--git-dir", str(ROOT / "repository.git"), "archive", sha],
                           env=clean_env(), stdout=stream, check=True)
        try:
            with tarfile.open(archive) as source:
                # Runtime environment files must never reach the build environment.
                for member in source.getmembers():
                    name = Path(member.name).name
                    if name == ".env" or (name.startswith(".env.") and name != ".env.example"):
                        raise RuntimeError("Tracked runtime environment file refused")
                source.extractall(release, filter="data")
        finally:
            archive.unlink(missing_ok=True)
        for directory, dirs, files in os.walk(release, followlinks=False):
            for name in dirs + files:
                os.chown(Path(directory) / name, builder.pw_uid, builder.pw_gid, follow_symlinks=False)
        os.chown(release, builder.pw_uid, builder.pw_gid)
        build_env = {"PATH": "/usr/bin:/bin", "HOME": str(release / ".build-home"),
                     "NODE_ENV": "production", "NEXT_TELEMETRY_DISABLED": "1",
                     "JOBPILOT_CATALOG_SCHEDULER": "0", "JOBPILOT_DATA_DIR": str(release / ".build-data"),
                     "JOBPILOT_UPLOAD_DIR": str(release / ".build-uploads"),
                     "NPM_CONFIG_CACHE": str(release / ".build-cache"),
                     "NPM_CONFIG_USERCONFIG": "/nonexistent/npm-user.conf",
                     "NPM_CONFIG_GLOBALCONFIG": "/nonexistent/npm-global.conf",
                     "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                     "GIT_TERMINAL_PROMPT": "0"}
        for step, arguments in [("install", ["ci", "--include=dev"]),
                                ("database", ["run", "db:push"]), ("compile", ["run", "build"])]:
            log("Building " + sha + ": " + step)
            command = ["systemd-run", "--quiet", "--wait", "--pipe", "--collect",
                       "--unit=jobpilot-build-" + sha[:12] + "-" + step,
                       "--property=User=" + BUILD_USER, "--property=UMask=0077",
                       "--property=WorkingDirectory=" + str(release),
                       "--property=ProtectSystem=strict", "--property=ProtectHome=yes",
                       "--property=PrivateTmp=yes", "--property=NoNewPrivileges=yes",
                       "--property=ReadWritePaths=" + str(release),
                       "--property=InaccessiblePaths=" + str(LEGACY) + " " + str(ROOT)]
            command += ["--setenv=" + key + "=" + value for key, value in build_env.items()]
            run(command + ["/usr/bin/npm", *arguments])
        freeze_release(release)
        for name in [".build-home", ".build-data", ".build-uploads", ".build-cache"]:
            shutil.rmtree(release / name, ignore_errors=True)
        # Operator-owned configuration is made available only AFTER compilation.
        feeds = LEGACY / "config/job-feeds.json"
        if feeds.is_file():
            (release / "config").mkdir(exist_ok=True)
            shutil.copyfile(feeds, release / "config/job-feeds.json")
            (release / "config/job-feeds.json").chmod(0o600)
        atomic_text(release / ".release.env", "JOBPILOT_RELEASE_SHA=" + sha + "\n"
                    + "JOBPILOT_RELEASED_AT=" + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n"
                    + "JOBPILOT_DATA_DIR=" + str(DATA) + "\nJOBPILOT_UPLOAD_DIR=" + str(UPLOADS) + "\n")
        atomic_text(release / ".build-complete", sha + "\n")
        return release
    except BaseException:
        freeze_release(release)
        raise


def sqlite_backup(sha):
    database = DATA / "jobpilot.db"
    if not database.is_file():
        raise RuntimeError("Live SQLite file is missing; refusing to initialize an empty database")
    backup = ROOT / "backups" / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + sha + ".db")
    backup.parent.mkdir(mode=0o700, exist_ok=True)
    with contextlib.closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as source:
        with contextlib.closing(sqlite3.connect(backup)) as destination:
            source.backup(destination)
            if destination.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise RuntimeError("SQLite backup integrity check failed")
    backup.chmod(0o600)
    log("Consistent SQLite backup created: " + backup.name)
    return backup


def migrate(release, sha):
    # Let systemd parse the unchanged EnvironmentFile; never shell-source or log secrets.
    run(["systemd-run", "--quiet", "--wait", "--pipe", "--collect",
         "--unit=jobpilot-migrate-" + sha[:12], "--property=UMask=0077",
         "--property=WorkingDirectory=" + str(release),
         "--property=EnvironmentFile=" + str(LEGACY / ".env"),
         "--setenv=JOBPILOT_DATA_DIR=" + str(DATA),
         "--setenv=JOBPILOT_UPLOAD_DIR=" + str(UPLOADS),
         "--setenv=JOBPILOT_CATALOG_SCHEDULER=0", "--setenv=NODE_ENV=production",
         "/usr/bin/npm", "run", "db:push"])


def healthy(url, sha):
    try:
        request = urllib.request.Request(url + "?release=" + sha + "&t=" + str(time.time_ns()),
                                         headers={"Cache-Control": "no-cache", "User-Agent": "jobpilot-deploy"})
        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.load(response)
            return response.status == 200 and body.get("status") == "ok" and body.get("releaseSha") == sha
    except (OSError, ValueError):
        return False


def wait_health(sha, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if healthy(LOCAL_HEALTH, sha) and healthy(PUBLIC_HEALTH, sha):
            return
        time.sleep(3)
    raise RuntimeError("Local/public release health verification failed")


def restore_runtime(previous):
    run(["systemctl", "stop", SERVICE], check=False)
    switch(previous)
    run(["systemctl", "start", SERVICE])
    if (previous / ".release.env").exists():
        wait_health(read_sha(previous))
    else:
        # Bootstrap version predates /api/health. Prove its local HTTP response.
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen("http://127.0.0.1:3000/", timeout=10) as response:
                    if response.status == 200:
                        return
            except OSError:
                pass
            time.sleep(3)
        raise RuntimeError("Legacy rollback did not become HTTP-ready")


def status():
    current = ROOT / "current"
    result = {"enabled": (ROOT / "enabled").is_file(),
              "blockedSha": (ROOT / "blocked-sha").read_text().strip() if (ROOT / "blocked-sha").exists() else None,
              "current": str(current.resolve()) if current.exists() else None}
    if current.exists():
        result["deployedSha"] = read_sha(current.resolve())
    if (ROOT / "transaction.json").exists():
        result["interruptedTransaction"] = json.loads((ROOT / "transaction.json").read_text())
    print(json.dumps(result, indent=2))


def deploy(requested=None, dry_run=False, prepare=False):
    if not dry_run and not prepare and not (ROOT / "enabled").is_file():
        log("Deployment disabled; application unchanged")
        return
    if (ROOT / "transaction.json").exists():
        raise RuntimeError("Interrupted activation recorded; inspect transaction.json and recover manually")
    previous = (ROOT / "current").resolve(strict=True)
    previous_sha = read_sha(previous)
    target = master_tip()
    if requested and requested != target:
        raise RuntimeError("Explicit SHA is not the current master tip")
    if target == previous_sha:
        log("Already serving current master " + target)
        return
    blocked = ROOT / "blocked-sha"
    if blocked.exists() and blocked.read_text().strip() == target:
        log("This SHA is blocked after a failed deployment; manual review required")
        return
    if not ci_success(target):
        log("Current master does not yet have a successful CI push run; unchanged")
        return
    if update_mirror() != target:
        log("Master moved during verification; deferred")
        return
    forward_only(previous_sha, target)
    if dry_run:
        log("DRY RUN: CI verified and fast-forward eligible " + previous_sha + " -> " + target)
        return
    stopped = False
    try:
        if not (DATA / "jobpilot.db").is_file() or not UPLOADS.is_dir():
            raise RuntimeError("Existing production database/uploads must exist")
        release = build_release(target)
        if prepare:
            log("Prepared CI-verified release; no live database or service changes: " + str(release))
            return
        # A long build must not authorize an obsolete commit or a now-disabled deployment.
        if not (ROOT / "enabled").is_file() or master_tip() != target or update_mirror() != target:
            log("Master moved or deployment disabled during build; activation deferred")
            return
        if not ci_success(target):
            log("CI authorization changed during build; activation deferred")
            return
        forward_only(previous_sha, target)
        # A durable marker makes interrupted migrations fail closed on later timer runs.
        atomic_text(ROOT / "transaction.json", json.dumps({"target": target, "previous": str(previous),
                                                          "previousSha": previous_sha}) + "\n")
        stopped = True  # Also recover if systemctl stop itself reports an error.
        run(["systemctl", "stop", SERVICE])
        sqlite_backup(target)
        migrate(release, target)
        switch(release)
        run(["systemctl", "start", SERVICE])
        wait_health(target)
        atomic_text(ROOT / "last-success.json", json.dumps({"sha": target, "previousSha": previous_sha,
                                                           "completedAt": int(time.time())}) + "\n")
        (ROOT / "transaction.json").unlink()
        blocked.unlink(missing_ok=True)
        log("Deployment verified locally and publicly: " + target)
    except BaseException:
        atomic_text(blocked, target + "\n")
        if stopped:
            log("Activation failed; restoring previous code and existing dependencies, never the database")
            restore_runtime(previous)
            (ROOT / "transaction.json").unlink(missing_ok=True)
            log("Previous runtime restored")
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["poll", "deploy", "prepare", "status"])
    parser.add_argument("--sha", help="Exact 40-character current master SHA; CI verification remains mandatory")
    parser.add_argument("--dry-run", action="store_true", help="Verify CI/history only; no build or service changes")
    args = parser.parse_args()
    if args.sha and not SHA_RE.fullmatch(args.sha):
        parser.error("--sha must be a full lowercase 40-character Git SHA")
    if os.geteuid() != 0:
        parser.error("Run as root; deployment files and lock must be root-controlled")
    os.umask(0o077)
    if not ROOT.is_dir() or ROOT.stat().st_uid != 0 or ROOT.stat().st_mode & 0o022:
        parser.error("Create a root-owned, non-group/world-writable /opt/jobpilot-deploy first")
    with (ROOT / "deploy.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Another deployment holds the lock; unchanged")
            return 0
        try:
            if args.command == "status":
                status()
            else:
                deploy(args.sha, args.dry_run, args.command == "prepare")
        except Exception as error:
            # Deliberately omit subprocess output, environment and configuration contents.
            log("ERROR: " + (str(error) if not isinstance(error, subprocess.CalledProcessError)
                              else "A deployment subprocess failed; inspect the relevant unit journal"))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
