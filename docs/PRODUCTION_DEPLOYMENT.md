# Production deployment

JobPilot is deployed as a persistent Node.js application. Cloudflare remains the
DNS/TLS proxy in front of the existing origin; it is not the application
runtime. The application currently relies on local SQLite, persistent uploaded
files, and an in-process catalog scheduler, so it must not be connected directly
to Cloudflare Pages or Workers without first migrating those three facilities.

## Automatic release flow

1. A commit is pushed to `master`.
2. The existing `CI` workflow validates that exact commit on GitHub-hosted
   infrastructure.
3. Every three minutes, a credential-free scheduled task on the production
   computer reads the public GitHub API and compares the current `master` tip
   with the deployed SHA.
4. Only when that exact tip has a successful `push` run of `.github/workflows/ci.yml`
   does the production task release it. Older CI completions cannot downgrade
   production, and non-forward or force-pushed histories are rejected.
5. The deploy script stops JobPilot, backs up SQLite, installs locked
   dependencies, builds against an isolated temporary database, applies additive
   schema initialization to production, and starts the application again.
6. Both the local origin and `https://job.vcrelay.com/api/health` must report the
   exact SHA. A failed release restores the preceding Git commit and build before
   restarting the task. Database migrations are deliberately not reversed.

The pull model avoids a persistent GitHub Actions runner on a public repository.
No GitHub or Cloudflare credential is stored on the origin or in the repository.

## One-time origin setup

Run these steps on the Windows computer that already hosts JobPilot. Use the
same low-privilege Windows account that owns the existing production checkout
and data. The scheduled tasks use an interactive logon, so this account must be
logged in after a reboot.

1. Confirm Node.js 22, Git, the existing `.env`, and the real production data
   directory are present. Do not move or commit `.env`,
   `config/job-feeds.json`, `data/uploads`, or the SQLite files.
2. Protect `master`: require the `CI / validate` check, require pull requests,
   and block force pushes. The repository is public, so do this before enabling
   unattended deployment.
3. Schedule a short maintenance window and stop the old manually managed
   JobPilot process so that only one process can bind the production port.
4. From an up-to-date checkout, install both the application and deployment
   scheduled tasks. The path passed to `DataDir` must contain the existing
   `jobpilot.db` and must be outside the Git checkout; the installer refuses to
   create a replacement empty database:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\install-production-task.ps1 `
     -ProjectRoot "C:\path\to\JobPilot" `
     -DataDir "C:\Users\<service-user>\AppData\Local\JobPilot" `
     -EnableDeployment
   ```

   Omit `-EnableDeployment` to install in disabled mode. After branch protection
   is ready, enable it with:

   ```powershell
   New-Item -ItemType File -Path "C:\path\to\JobPilot\.jobpilot-deploy-enabled" -Force
   ```

No Cloudflare record changes are necessary. `job.vcrelay.com` continues to
proxy to the same origin, and no Cloudflare token belongs in this deployment.

## Operational checks

- Current release: `GET https://job.vcrelay.com/api/health`
- Process status: `Get-ScheduledTask -TaskName JobPilot`
- Deployment poller: `Get-ScheduledTask -TaskName JobPilotDeploy`
- SQLite backups: `<DataDir>\backups\deploy-*`
- Pause deployment: remove `.jobpilot-deploy-enabled` from the production
  checkout. This does not stop the running application.

The deployment process never cleans untracked files and refuses to proceed when
the production checkout contains tracked edits. During builds,
`JOBPILOT_DATA_DIR` points at an isolated temporary directory; the real SQLite
directory is used only after the running task has stopped. Release metadata is
stored separately in the ignored `.jobpilot-release.env`; the deploy script
never rewrites operator-managed `.env` files.
