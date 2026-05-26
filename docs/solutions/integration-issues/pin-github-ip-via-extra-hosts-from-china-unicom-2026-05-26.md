---
title: Pin github.com IP via docker-compose extra_hosts on China Unicom-hosted self-hosted runners
date: 2026-05-26
category: integration-issues
module: actions-runner-docker
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "actions/checkout@v4 fails with: Failed to connect to github.com port 443 after 13xxxx ms: Couldn't connect to server"
  - "Roughly 50% of CI jobs fail at the checkout step; retrying eventually succeeds on a different runner"
  - "DNS for github.com from the runner host resolves to 20.205.243.166 (Azure/Singapore) which is 100% unreachable"
  - "Some 140.82.x.4 IPs are 0/3 reachable while 140.82.114.3 is 3/3 reachable from the same host"
  - "Sibling GitHub hostnames (codeload, api, objects) remain reachable, isolating the issue to github.com IP routing"
root_cause: config_error
resolution_type: config_change
applies_when:
  - "Self-hosted GitHub Actions runners deployed on China-mainland networks (especially China Unicom)"
  - "Workflows depend on actions/checkout@v4 or any direct https clone of github.com"
  - "Multiple runner replicas share the same docker-compose stack and one host"
  - "GitHub DNS occasionally returns 20.205.243.0/24 (Azure) IPs that are blackholed from the host"
  - "Runner registration is identity-bound (.runner / .credentials files) and must survive container recreation"
tags:
  - github-actions
  - self-hosted-runner
  - docker-compose
  - extra-hosts
  - china-unicom
  - github-ip-blocking
  - actions-checkout
  - dns-blackhole
  - bind-mount-persistence
---

# Pin github.com IP via docker-compose extra_hosts on China Unicom-hosted self-hosted runners

## Problem

A self-hosted GitHub Actions runner stack (`actions-runner-docker`, 4 DooD runners sharing host `docker.sock`) migrated from a broken Windows ZeroTier host to a Beijing Ubuntu 22.04 cloud VM `cw` (China Unicom). After successful registration, ~50% of CI jobs failed at `actions/checkout@v4` while other jobs in the same workflow run, on sibling runner containers, succeeded.

## Symptoms

- `actions/checkout@v4` step fails with:
  ```
  fatal: unable to access 'https://github.com/wendao-ai/mige-lims-jeecgboot/':
  Failed to connect to github.com port 443 after 13xxxx ms: Couldn't connect to server
  The process '/usr/bin/git' failed with exit code 128
  ```
- Within one workflow run: `cw-runner-2` green, `cw-runner` red — same image, same compose, same egress.
- `getent hosts github.com` returns a different IP on each container/each call (Docker embedded DNS round-robins GitHub's anycast pool).
- IP-pinned curl probe shows a clean ISP-level pattern:

  | IP | Reachable |
  |---|---|
  | `140.82.112.3` | 1/3 |
  | `140.82.112.4` | 0/3 |
  | `140.82.113.3` | ok |
  | `140.82.113.4` | 0/3 |
  | `140.82.114.3` | **3/3** |
  | `140.82.114.4` | 0/3 |
  | `140.82.121.3` | 0/3 |
  | `140.82.121.4` | 0/3 |
  | `20.205.243.166` (current DNS answer) | timeout |

- `codeload.github.com`, `api.github.com`, `objects.githubusercontent.com` all reachable — only the apex `github.com` hostname is degraded.
- `curl https://github.com` from the *host*, not just containers, also times out — rules out Docker networking.

## What Didn't Work

- **HTTP proxy on runner**: no proxy host available on cw; `actions/checkout` does not honor per-job HTTPS proxy without invasive workflow rewrites.
- **`daemon.json` `registry-mirrors` (DaoCloud)**: only proxies the docker registry path, not `git clone https://github.com`. Already configured for the docker pull case; orthogonal.
- **Baking `/etc/hosts` into the image**: Docker images do not carry `/etc/hosts`; the file is daemon-managed at runtime. Must be set via compose `extra_hosts`.
- **`docker exec ... echo >> /etc/hosts`**: survives `docker stop/start` but is wiped on container recreation — and any `extra_hosts` edit forces recreation, so a manual hosts patch would be destroyed by the very fix that replaces it.

## Solution

Two coupled parts. **Part B is a prerequisite for Part A** — applying Part A without Part B will burn all four one-time runner registration tokens.

### Part A — Pin `github.com` to a reachable IP via `extra_hosts`

In `docker-compose.yml`, extend the shared anchor so all 4 runners inherit the override:

```yaml
x-runner-base: &runner-base
  # ... existing fields ...
  dns:
    - 1.1.1.1
    - 8.8.8.8
  # China Unicom selectively rate-limits / null-routes portions of GitHub's
  # IP pool (notably the *.4 endings in 140.82.x.x and the 20.205.243.x
  # Azure-hosted block that DNS now returns to CN clients).
  # Probe loop on 2026-05-26 found 140.82.114.3 stable 3/3.
  # Override via GITHUB_HOST_IP when this IP eventually degrades.
  extra_hosts:
    - "github.com:${GITHUB_HOST_IP:-140.82.114.3}"
```

### Part B — Persist runner identity before recreation

`extra_hosts` changes trigger container recreation. Without bind-mounted credentials, each new container re-runs `config.sh` and requires a fresh registration token from the GitHub UI (one-time, ~1h TTL, manual × 4). Persist first.

1. Extract creds from the running containers into per-runner host directories:
   ```bash
   for i in 1 2 3 4; do
     C=$( [ "$i" = 1 ] && echo cw-runner || echo cw-runner-$i )
     mkdir -p .creds/$i
     for f in .runner .credentials .credentials_rsaparams; do
       docker cp "$C:/actions-runner/$f" ".creds/$i/$f"
     done
   done
   chmod 600 .creds/*/.credentials_rsaparams
   ```

2. Add `docker-compose.override.yml` (gitignored, per-host). Compose override does **not** deep-merge `volumes:` arrays — you must restate the docker.sock + work volume + 3 cred mounts together:
   ```yaml
   services:
     runner:
       volumes:
         - /var/run/docker.sock:/var/run/docker.sock
         - runner-work:/actions-runner/_work
         - ./.creds/1/.runner:/actions-runner/.runner
         - ./.creds/1/.credentials:/actions-runner/.credentials
         - ./.creds/1/.credentials_rsaparams:/actions-runner/.credentials_rsaparams
     # runner-2/3/4 follow same shape with .creds/2/, .creds/3/, .creds/4/
   ```

3. `.gitignore`:
   ```
   .creds/                          # runner registration creds (RSA private keys)
   docker-compose.override.yml      # per-host bind-mount override
   ```

4. `docker compose down && docker compose up -d`. Expected per-runner log:
   ```
   Connected to GitHub
   A session for this runner already exists. Retrying until reconnected.
   Listening for Jobs
   ```
   Zero registration tokens consumed.

## Why This Works

- **ISP-level, not Docker-level**: China Unicom selectively blackholes part of GitHub's anycast pool (notably the `.4` endings in `140.82.x.x` and the newer `20.205.243.x` Azure addresses CN-region DNS now prefers). The same docker-compose looks flaky only because Docker's embedded DNS round-robins through good and bad IPs — landing on a healthy IP makes a job green, landing on a blackholed one times out git after 130s.
- **`extra_hosts` short-circuits DNS round-robin**: it writes an `/etc/hosts` entry inside the container that takes precedence over the embedded resolver, so every `git clone` pins to the IP probe-verified as reachable. No ISP coverage change, no DNS magic — deterministic routing.
- **Credential persistence is structural, not optional**: the moment you touch `extra_hosts` (or any container-config field), compose recreates the container. Self-hosted runner credentials live inside the container filesystem and are coupled to a one-time, ~1h TTL registration token. Without bind mounts, recreation = re-registration = manual GitHub UI walk × N runners. The companion learning [preserve-runner-registration-via-bind-mount-2026-05-20.md](../workflow-issues/preserve-runner-registration-via-bind-mount-2026-05-20.md) already flagged this; this episode forced compliance.

## Prevention

- **Re-probe when the pinned IP degrades.** Keep this one-liner near the compose file (or in repo docs) and rerun before/after any region or ISP routing change:
  ```bash
  for ip in 140.82.112.3 140.82.112.4 140.82.113.3 140.82.113.4 \
            140.82.114.3 140.82.114.4 140.82.121.3 140.82.121.4; do
    printf '%s: ' "$ip"
    for _ in 1 2 3; do
      curl -sS -o /dev/null --resolve github.com:443:$ip \
        --max-time 5 -w '%{http_code} ' https://github.com/ || printf 'fail '
    done
    echo
  done
  ```
  Set `GITHUB_HOST_IP=<best>` in the host env (or in `.env`), then `docker compose up -d`. The pin is intentionally env-overridable so swaps don't need code edits.

- **Track the IP choice with a date stamp.** Inline comment above `extra_hosts` should carry `last_updated: YYYY-MM-DD` and current pick (this doc: `2026-05-26 -> 140.82.114.3`). Treat the value as expiring — re-verify quarterly or on first failure.

- **Always persist creds before touching runner container config.** See companion: [preserve-runner-registration-via-bind-mount-2026-05-20.md](../workflow-issues/preserve-runner-registration-via-bind-mount-2026-05-20.md). Any compose edit on a self-hosted runner should be preceded by the `docker cp .runner .credentials .credentials_rsaparams` extraction in Part B above.

- **Side discovery — Dockerfile `COPY --chmod=0755` for entrypoint.** Independent issue surfaced in the same migration: `COPY --chown=runner:runner entrypoint.sh /entrypoint.sh` inherits the source file's mode. A freshly cloned repo where `entrypoint.sh` happens to be `0600` (e.g. restrictive umask, restored from backup) fails container startup with `exec: "/entrypoint.sh": permission denied`. Force the bit at copy time:
  ```dockerfile
  COPY --chown=runner:runner --chmod=0755 entrypoint.sh /entrypoint.sh
  ```
  Treat every COPY of an executable as needing an explicit `--chmod` — don't trust the working tree's permissions.

## Related Issues

- [preserve-runner-registration-via-bind-mount-2026-05-20.md](../workflow-issues/preserve-runner-registration-via-bind-mount-2026-05-20.md) — the credential-persistence pattern that Part B applies. Was previously a "nice to have for image upgrades"; this episode promotes it to "required prerequisite before any runner container-config edit."
