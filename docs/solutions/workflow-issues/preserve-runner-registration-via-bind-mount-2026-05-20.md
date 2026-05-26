---
title: Preserve GitHub Actions runner registration across image upgrades via bind-mounted credentials
date: 2026-05-20
category: workflow-issues
module: github-actions-runners
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - Operating containerized GitHub Actions self-hosted runners
  - Need to rebuild the image regularly (add packages, security patches, runner-version bumps)
  - Multiple runner instances managed by docker compose
  - Cannot afford to request fresh registration tokens for every upgrade
tags: [github-actions, self-hosted-runner, docker-compose, bind-mount, credentials, image-upgrade, dood]
---

# Preserve GitHub Actions runner registration across image upgrades via bind-mounted credentials

## Context

GitHub Actions self-hosted runner registration tokens are **single-use** and live for **~1 hour**. The canonical setup workflow looks like:

```bash
./config.sh --url https://github.com/<org> --token <REG_TOKEN>
./run.sh
```

In a containerized deployment, `config.sh` writes three files into the runner's workdir:

| File | Purpose |
|---|---|
| `.runner` | JSON: runner id, name, GitHub server URL |
| `.credentials` | JSON: oauth-style credentials |
| `.credentials_rsaparams` | RSA private-key material the runner uses to authenticate |

These files live inside the container's filesystem. **Recreating the container destroys them**, so the runner re-runs `config.sh` on next start — and that requires a fresh registration token, which the operator must mint by hand in the GitHub UI.

For a fleet of N runners this becomes punishing: any image change (adding a tool, bumping the runner version, security patch) means visiting the GitHub UI N times within an hour. The friction discourages timely upgrades.

A common but flawed mitigation is `config.sh remove` in the entrypoint's SIGTERM trap. It fails silently because removal needs a separate **removal token**, not the registration token — and even when it works it doesn't help the next start, which still needs a fresh registration token.

## Guidance

**Persist the three registration files outside the container via bind mounts**, so container recreation no longer loses runner identity:

1. One-time: `docker cp` the three files out of each running container into a host directory.
2. Add bind mounts for those files in a `docker-compose.override.yml` (per-runner, since each runner has its own identity).
3. Fix the entrypoint to `chown` the bind-mounted files to the `runner` user (Docker Desktop on Windows bind-mounts with non-runner UIDs, which makes the files unreadable).
4. The existing `if [[ ! -f .runner ]]; then ./config.sh ...; fi` guard in the entrypoint will see the file present, skip registration, and go straight to `./run.sh` — reusing the existing identity.

After the first capture, all subsequent image rebuilds become:

```bash
docker compose build
docker compose down && docker compose up -d
```

No GitHub UI clicks, no token paste.

## Why This Matters

**Decouples image lifecycle from registration lifecycle.** The image is volatile (every upgrade rebuilds it); the registration is durable (lives as long as you want the runner). Treating both as the same lifecycle conflates two concerns and forces tokens into the upgrade loop unnecessarily.

**Removes a daily-ops fragility.** Registration tokens expiring mid-upgrade is a real failure mode — start `down`, fumble for tokens, runners are offline longer than expected. Persistence eliminates the failure mode entirely.

**Keeps registrations "warm" through restarts.** When the runner reconnects with the same identity (vs. registering anew), GitHub treats it as a reconnect of the existing runner. The only delay is a 60-180s window if the old container's session hadn't fully timed out yet ("A session for this runner already exists. Retrying until reconnected."); after that it's listening again. With re-registration, the old runner shows up as a separate "Offline" entry and the new one races to acquire the name.

**Required gotcha on Docker Desktop (Windows host):** NTFS-backed bind mounts get mapped to a non-`runner` UID inside the Linux container. Without a `chown` in the entrypoint, the runner cannot read its own credentials and falls back to `config.sh`. Address it once in the entrypoint — Linux hosts are unaffected by the same line.

## When to Apply

- Any containerized self-hosted runner deployment (one or many instances)
- When image rebuilds are frequent enough that token friction is felt
- When the host is shared/multi-tenant and operator GitHub access is gated (one-token-per-upgrade flow becomes a permission-request bottleneck)

**When *not* to apply:** ephemeral / per-job runners (ARC, ephemeral mode), where the registration is intentionally short-lived. The pattern is for long-lived self-hosted runners.

## Examples

### One-time credential extraction (Windows host, 4 runners)

```cmd
:: from the compose project dir
for /L %i in (1,1,4) do mkdir .creds\%i

for %c in (kb-runner-docker:1 kb-runner-docker-2:2 kb-runner-docker-3:3 kb-runner-docker-4:4) do (
  for /f "tokens=1,2 delims=:" %a in ("%c") do (
    docker cp %a:/actions-runner/.runner                .creds\%b\.runner
    docker cp %a:/actions-runner/.credentials           .creds\%b\.credentials
    docker cp %a:/actions-runner/.credentials_rsaparams .creds\%b\.credentials_rsaparams
  )
)
```

### `docker-compose.override.yml` (gitignored, per-host)

```yaml
# Reuse already-registered identity across image rebuilds.
# volumes lists are written in full (not merged) to avoid compose
# override semantics dropping the main file's docker.sock / work mounts.
services:
  runner:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - runner-work:/actions-runner/_work
      - ./.creds/1/.runner:/actions-runner/.runner
      - ./.creds/1/.credentials:/actions-runner/.credentials
      - ./.creds/1/.credentials_rsaparams:/actions-runner/.credentials_rsaparams
  runner-2:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - runner-work-2:/actions-runner/_work
      - ./.creds/2/.runner:/actions-runner/.runner
      - ./.creds/2/.credentials:/actions-runner/.credentials
      - ./.creds/2/.credentials_rsaparams:/actions-runner/.credentials_rsaparams
  # ...runner-3, runner-4 follow the same shape
```

### Entrypoint `chown` fix (`entrypoint.sh`)

```bash
# Fix UID on bind-mounted credentials before ./run.sh tries to read them.
# Docker Desktop on Windows bind-mounts NTFS files with UID != runner.
for f in .runner .credentials .credentials_rsaparams; do
  [[ -e /actions-runner/$f ]] && sudo chown runner:runner "/actions-runner/$f" || true
done
[[ -e /actions-runner/.credentials_rsaparams ]] && sudo chmod 600 /actions-runner/.credentials_rsaparams || true

# Unchanged: only register if no identity present
if [[ ! -f .runner ]]; then
  ./config.sh --unattended --replace --url "$RUNNER_URL" --token "$RUNNER_TOKEN" ...
fi
exec ./run.sh
```

### Verifying the cycle

After `docker compose down && docker compose up -d`, expect logs like:

```
√ Connected to GitHub
A session for this runner already exists.
... Retrying until reconnected.    # 60-180s wait for the previous session to expire
... Runner reconnected.
... Listening for Jobs
```

The `Conflict` message is normal and self-resolves. If you instead see `404 Not Found from POST .../runner-registration`, the entrypoint went down the `config.sh` path with a stale/already-consumed token — check that the bind-mounted `.runner` file exists and has the right contents.

### Things to gitignore on the host

```gitignore
.creds/                # contains RSA private-key material — never commit
docker-compose.override.yml   # if it's host-specific
```

## Related

- GitHub Actions runner source: <https://github.com/actions/runner>
- Compose override-file merge semantics for `volumes`: list-level fields are not deep-merged across files in the way scalars are; spelling out the full list per service avoids surprise drops
- Real-world consumer of this pattern: [Pin github.com IP via docker-compose extra_hosts on China Unicom-hosted runners](../integration-issues/pin-github-ip-via-extra-hosts-from-china-unicom-2026-05-26.md) — adding `extra_hosts` to fix CN ISP IP blocking forces container recreation, which this pattern makes free (no token re-mint)
