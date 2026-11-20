#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

required_modules=(
    00-bootstrap.sh 01-constants.sh 02-output.sh 03-installer.sh 03-system.sh
    20-paths.sh 21-config-base.sh 22-state.sh 30-xray-core.sh 31-service.sh
    40-network.sh 41-safety.sh 50-vless-common.sh 50-vless-enc.sh 51-reality.sh
    52-xhttp.sh 53-advanced.sh 54-ss2022.sh 55-socks.sh 56-tunnel.sh
    57-hysteria2.sh 60-doctor.sh 61-smoke.sh 62-export.sh 63-diag.sh
    70-view.sh 71-cli-view.sh 72-cli-core.sh 72-cli-admin.sh 73-cli-migrate.sh
    74-cli-protocols.sh 80-menu.sh 81-help.sh 90-test-harness.sh
)

for module in "${required_modules[@]}"; do
    [[ -f "lib/${module}" ]] || {
        echo "[FAIL] 缺少模块: lib/${module}" >&2
        exit 1
    }
done

install_lines="$(wc -l <install.sh)"
((install_lines < 900)) || {
    echo "[FAIL] install.sh 行数异常: ${install_lines}" >&2
    exit 1
}

script_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' lib/01-constants.sh | head -n 1)"
file_version="$(tr -d '\r\n' <VERSION)"
readme_version="$(sed -n 's/.*当前版本：\*\*\([0-9.]*\)\*\*.*/\1/p' README.md | head -n 1)"
[[ -n "$script_version" && "$script_version" == "$file_version" && "$script_version" == "$readme_version" ]] || {
    echo "[FAIL] 版本不一致: script=${script_version} file=${file_version} readme=${readme_version}" >&2
    exit 1
}

for script in install.sh scripts/bootstrap.sh lib/*.sh tests/*.sh; do
    bash -n "$script"
done
sh -n scripts/bootstrap.sh
shellcheck -x -S warning -e SC2034,SC2120 install.sh scripts/bootstrap.sh lib/*.sh tests/*.sh
bash install.sh version
bash tests/test_config_generation.sh
bash tests/test_regressions.sh
bash tests/test_deployment.sh

echo "[OK] 完整测试全部通过"
