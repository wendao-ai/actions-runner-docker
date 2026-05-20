#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_URL:?RUNNER_URL must be set, e.g. https://github.com/<org>}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN must be set (registration token from GitHub)}"

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"

# DooD: 让 runner 用户能用宿主 docker.sock；GID 在不同宿主上不固定，
# 直接 chown 到 runner（仅影响容器内视图，不改宿主）
if [[ -S /var/run/docker.sock ]]; then
  sudo chown runner /var/run/docker.sock || true
fi

cleanup() {
  echo "[entrypoint] Removing runner registration..."
  ./config.sh remove --unattended --token "${RUNNER_TOKEN}" || true
}
trap 'cleanup; exit 130' INT TERM

if [[ ! -f .runner ]]; then
  ./config.sh \
      --unattended \
      --replace \
      --url    "${RUNNER_URL}" \
      --token  "${RUNNER_TOKEN}" \
      --name   "${RUNNER_NAME}" \
      --work   "${RUNNER_WORKDIR}" \
      ${RUNNER_LABELS:+--labels "${RUNNER_LABELS}"}
fi

exec ./run.sh
