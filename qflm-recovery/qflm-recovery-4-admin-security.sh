#!/usr/bin/env bash
set -euo pipefail
BASE=https://raw.githubusercontent.com/quikefix/quikefix-wazuh-agent-installer/main/qflm-recovery
curl -fsSL "$BASE/qflm-recovery-4a-source.sh" | bash
curl -fsSL "$BASE/qflm-recovery-4b-promote.sh" | bash
