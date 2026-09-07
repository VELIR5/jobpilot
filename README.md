# JobPilot

[![CI](https://github.com/VELIR5/jobpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/VELIR5/jobpilot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/github/package-json/v/VELIR5/jobpilot)](https://github.com/VELIR5/jobpilot)

[简体中文](README.zh-CN.md) · [Live demo](https://job.vcrelay.com:8443) · [Issues](https://github.com/VELIR5/jobpilot/issues)

JobPilot is a resume-aware job matching and application assistant. It helps a
candidate parse a resume, describe job preferences, search for real vacancies,
review matching evidence, and prepare or submit an application after explicit
confirmation.

The repository contains a Next.js web application and a native WeChat
mini-program client. Both clients use the same server-side domain and API
contracts.

> The live demo is a deployment endpoint, not an availability or delivery
> guarantee. Job data, source records, and email delivery must be independently
> reviewed by the user.

## Try JobPilot

Open the public web application:

**[https://job.vcrelay.com:8443](https://job.vcrelay.com:8443)**

Sign in with your email, upload a resume, set your job preferences, and review
matched vacancies before deciding whether to apply.

## What it does

- Email-based access with signed HttpOnly browser sessions.
- Resume upload and deterministic PDF/DOCX text extraction with confirmation.
- Preference capture for target city, role family, industry, and work mode.
- A scheduled job catalog fed by configured public ATS, JSON, RSS, or Atom
  sources, with deterministic normalization, expiry, deduplication, and local
  filtering.
- An optional background web collector can broaden the catalog with generic
  city and role searches; it never sends a user's resume to the collector.
- Explicit separation between email-eligible vacancies and official manual
  application channels.
- Application tasks, idempotency, status history, and user-scoped records.
- Optional Google OAuth and central platform email relay through Resend.
- Native WeChat mini-program pages for login, resume, preferences, matches, and
  application history.

## Safety boundaries

JobPilot deliberately favors an honest incomplete result over a fabricated one.

- External job feeds and vacancy content are untrusted input.
- A job must pass the configured source, URL, city, and schema checks before it
  becomes a formal result.
- The system never guesses a hiring email, company, vacancy, URL, qualification,
  or delivery result.
- A vacancy without a directly verified application email remains a manual or
  official-portal action; it is not auto-emailed.
- Real email submission requires user selection, final confirmation, valid
  sending configuration, and an idempotent application task.
- Tests and CI use mocks and do not send real email or search a user's resume.
- The project does not bypass login, CAPTCHA, rate limits, access controls, or
  site rules.

## Requirements

- Node.js 22.5 or newer. Node 22 is required for the built-in SQLite runtime.
- npm with network access to install the locked dependencies.
- For a self-hosted deployment, at least one public job feed configured by the
  administrator in `config/job-feeds.json`, or an explicitly configured
  background web collector.
- Google Cloud OAuth credentials only if Google login is enabled.
- WeChat mini-program credentials only if the mini-program login exchange is
  enabled.
- Resend sender credentials only if central email relay is enabled.

## Local development

```powershell
npm ci
Copy-Item .env.example .env
# Fill the required values in .env using your own local secrets.
npm run db:push
npm run dev
```

Open `http://localhost:3000`. The `.env` file, database, uploads, and logs are
ignored by Git and must never be committed.

For a self-hosted deployment, the catalog scheduler uses:

| Variable | Purpose |
| --- | --- |
| `JOBPILOT_SESSION_SECRET` | Signs browser and Bearer sessions. Use a long random value. |
| `JOBPILOT_ACCESS_PASSWORD_HASH` | Shared gate password hash for the sign-in page. |
| `JOBPILOT_INVITE_PASSWORD_HASH` | Invitation hash used for account registration. |
| `JOBPILOT_CATALOG_REFRESH_MINUTES` | Background refresh interval; defaults to 60 minutes. |
| `JOBPILOT_CATALOG_STALE_HOURS` | How long an unseen vacancy remains searchable; defaults to 48 hours. |
| `JOBPILOT_CATALOG_MAX_ACTIVE_JOBS` | Active catalog size limit; defaults to 5,000. |
| `JOBPILOT_JOB_FEEDS` | Optional inline JSON feed configuration; otherwise `config/job-feeds.json` is used. |

All supported variables and security notes are listed in [`.env.example`](.env.example).
See [`docs/JOB_CATALOG.md`](docs/JOB_CATALOG.md) for administrator feed
configuration. End users of the hosted application do not need to configure
these values.

## Production start

```powershell
npm ci
npm run db:push
npm run build
npm run start
```

`next start` loads the production build once at startup. After changing server
code or environment configuration, rebuild and restart the process. Put the
application behind HTTPS and a deployment-specific access control layer; a
tunnel only supplies transport and does not replace authentication or tenant
isolation.

The server starts the catalog scheduler automatically. A separate long-running
worker is also available for process managers:

```powershell
npm run catalog:worker
```

Production releases can be synchronized from a CI-tested `master` commit by a
credential-free, systemd-managed pull task on the existing Debian Linux origin. See
[`docs/PRODUCTION_DEPLOYMENT.md`](docs/PRODUCTION_DEPLOYMENT.md). The Cloudflare
record remains a proxy in front of the persistent Node origin; no Cloudflare API
or GitHub token is required by the deployment workflow.

## WeChat mini-program

1. Import [`miniapp/`](miniapp/) into WeChat Developer Tools.
2. Replace the placeholder AppID in `project.config.json` with your own AppID.
3. Set the production HTTPS API origin in [`miniapp/config.js`](miniapp/config.js).
4. Configure the API origin as a legal request and upload domain in WeChat.
5. Run `npm run check:miniapp` before device testing.

The mini-program package contains no mail key, database, resume, or
server session secret. Real WeChat login, upload, navigation, and device
acceptance still require WeChat Developer Tools and a real device.

## License and security

JobPilot is released under the [MIT License](LICENSE). Security issues should
be reported privately to the repository owner.
