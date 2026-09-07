# Linux production deployment

JobPilot runs on the existing Debian 13 ARM64 origin with Node
22, `/usr/bin/npm`, and `jobpilot.service`. Cloudflare continues proxying
`https://job.vcrelay.com` to this persistent Node origin. No Cloudflare changes,
GitHub token, persistent Actions runner, or Windows task is involved.

## Release contract

Every three minutes the root-owned controller checks public GitHub `master` and
the latest matching `push` run of `.github/workflows/ci.yml`. It releases only
the exact current tip after successful CI and a fast-forward ancestry check.
An explicit `--sha` does not bypass either check. It checks again after building
and serializes invocations with a nonblocking exclusive file lock.

The bare source repository lives in `/opt/jobpilot-deploy/repository.git` and
uses an explicit public fetch URL with global/system Git configuration disabled.
Source is extracted with `git archive` into `/opt/jobpilot-releases/<full-sha>`;
the live checkout is never pulled, cleaned, rebuilt, or reinstalled. The
controller and systemd templates are manually installed, trusted control-plane
files; application releases cannot automatically replace them. Repository
writers and dependencies remain trusted application-code publishers. Requiring
review, successful CI, and blocking force pushes on `master` is recommended.

Before stopping the application, the controller runs `npm ci --include=dev`,
`npm run db:push`, and `npm run build` as `jobpilot-build` in transient systemd
sandboxes. They can write only the candidate release and private temporary
storage, cannot access `/opt/jobpilot` or `/opt/jobpilot-deploy`, and receive no
production environment file. The build database, uploads and npm cache are
isolated and deleted after success. Compilation or dependency failures leave the
live process untouched. These steps do not send application emails.

Activation stops **only** `jobpilot.service`, creates and integrity-checks a
consistent SQLite backup using Python's SQLite backup API, runs the additive
schema initializer, atomically switches `/opt/jobpilot-deploy/current`, and
starts the same service. Local and public `/api/health` must return `status: ok`
and the exact release SHA. Failed activation switches back to the previous code
and its already-built dependencies. It never automatically restores SQLite:
schema changes must remain backward-compatible with the preceding release.
The bootstrap fallback is the untouched `/opt/jobpilot` installation.

Persistent paths do not move:

- Environment/secrets: `/opt/jobpilot/.env` (runtime/migration only).
- SQLite: `/opt/jobpilot/data/JobPilot/jobpilot.db`.
- Uploaded resumes: `/opt/jobpilot/data/uploads`.
- Optional operator feeds: `/opt/jobpilot/config/job-feeds.json`, copied only
  after the build; it is absent on the current origin.
- Backups and deployment state: `/opt/jobpilot-deploy/` (root-only).

## One-time reviewed installation

First verify the actual unit, Node version, production data, current commit and
available disk space; back up the existing environment and systemd configuration
without displaying their contents. Do not modify the live installation. The
commands below assume a reviewed source checkout in `$SOURCE` and root access.

```sh
SOURCE=/path/to/reviewed/jobpilot
id jobpilot-build >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin jobpilot-build
install -d -m 0700 /opt/jobpilot-deploy /opt/jobpilot-deploy/backups
install -d -m 0711 /opt/jobpilot-releases
install -m 0700 "$SOURCE/scripts/linux/deploy.py" /opt/jobpilot-deploy/deploy.py
install -m 0644 "$SOURCE/scripts/linux/jobpilot-deploy.service" /etc/systemd/system/jobpilot-deploy.service
install -m 0644 "$SOURCE/scripts/linux/jobpilot-deploy.timer" /etc/systemd/system/jobpilot-deploy.timer
# Bootstrap only: do not replace an existing current pointer.
test -e /opt/jobpilot-deploy/current || ln -s /opt/jobpilot /opt/jobpilot-deploy/current
python3 /opt/jobpilot-deploy/deploy.py status
python3 /opt/jobpilot-deploy/deploy.py deploy --dry-run
python3 /opt/jobpilot-deploy/deploy.py prepare
```

`prepare` performs the same CI/history checks and isolated build but never stops
the service or touches the live database. It works while deployment is disabled.
Before the first activation, test the candidate's `db:push` on a separate
SQLite backup, check compatibility with the old runtime, and verify the prepared
application in an isolated test service if needed. Do not point those checks at
production data, enable its scheduler, or submit email/application actions.

Only at the reviewed activation stage, install the additive drop-in; it preserves
the original unit's `ExecStart=/usr/bin/npm run start`, `NODE_ENV`, `PORT`, user,
and restart policy. Existing `/opt/jobpilot/.env` remains unchanged. The optional
release environment supplies the new SHA and persistent paths.

```sh
install -d -m 0755 /etc/systemd/system/jobpilot.service.d
install -m 0644 "$SOURCE/scripts/linux/jobpilot-runtime.conf" /etc/systemd/system/jobpilot.service.d/releases.conf
systemctl daemon-reload
install -m 0600 /dev/null /opt/jobpilot-deploy/enabled
# Replace FULL_SHA with the CI-tested current master SHA confirmed above.
python3 /opt/jobpilot-deploy/deploy.py deploy --sha FULL_SHA
python3 /opt/jobpilot-deploy/deploy.py status
systemctl status jobpilot.service --no-pager
curl --fail https://job.vcrelay.com/api/health
# Enable polling only after successful end-to-end acceptance.
systemctl enable --now jobpilot-deploy.timer
```

The drop-in installation/reload alone does not restart the application. The
deployment command builds first, then performs the brief service cutover.

## Operations and recovery

```sh
python3 /opt/jobpilot-deploy/deploy.py status
systemctl list-timers jobpilot-deploy.timer --no-pager
journalctl -u jobpilot-deploy.service -n 100 --no-pager
# Pause future deployment without stopping the application:
rm /opt/jobpilot-deploy/enabled
```

Any failed candidate is recorded in `blocked-sha` and will not be retried
automatically. A newer CI-passing tip can proceed. To retry the same SHA, first
review the journal and candidate directory, fix the cause, and remove
`blocked-sha`. An incomplete release directory must also be reviewed and removed
manually; the controller never deletes old release directories. Completed builds
are reusable. Release roots are root-owned mode 0700 after compilation;
the parent directory is mode 0711 solely for the isolated build user's traversal.

`transaction.json` means activation started but did not finish cleanly (for
example, power failure or failed rollback). The timer fails closed until an
operator reviews the recorded previous path, current pointer, SQLite backup and
service state. Restore the previous code pointer and start **only** JobPilot if
appropriate; verify its HTTP health before removing the transaction marker.
Do not restore the database automatically or overwrite post-backup user data.
The original bootstrap version lacks `/api/health`, so rollback to it verifies
the local root page; later releases require exact local and public health SHAs.

Keep old releases and database backups until a reviewed retention/cleanup
window. Deployment has no hard build timeout and never restarts SSH, networking,
the proxy, or unrelated services. A public GitHub API failure or rate limit
leaves the current application running and is retried on a later timer tick.

Controller tests (no service, network, or production-data access):

```sh
python3 -m unittest discover -s scripts/linux -p 'test_*.py' -v
```
