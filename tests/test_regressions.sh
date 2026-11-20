#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ike-regressions.XXXXXX")"
MOCK_BIN="${TMP_DIR}/bin"
MOCK_CURL_LOG="${TMP_DIR}/curl.log"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message: expected=$expected actual=$actual"
}

test_migrate_dry_run_and_schema_upgrade() (
    CONFIG_DIR="${TMP_DIR}/migrate"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"vless+tcp+reality","streamSettings":{"security":"reality","realitySettings":{"dest":"example.com:443"}}}],"outbounds":[]}
JSON
    printf '%s\n' '{}' >"$STATE_FILE"

    local config_before state_before
    config_before="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    state_before="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    run_migrate_command --dry-run >/dev/null || fail "migrate --dry-run 执行失败"
    assert_eq "$config_before" "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')" "migrate --dry-run 不得修改 config"
    assert_eq "$state_before" "$(sha256sum "$STATE_FILE" | awk '{print $1}')" "migrate --dry-run 不得修改 state"

    migrate_old_state() {
        printf '%s\n' '{"partial":true}' >"$STATE_FILE"
        return 1
    }
    if run_migrate_command >/dev/null 2>&1; then
        fail "state 迁移失败时整体迁移不得成功"
    fi
    assert_eq "$config_before" "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')" "state 迁移失败后 config 应回滚"
    assert_eq "$state_before" "$(sha256sum "$STATE_FILE" | awk '{print $1}')" "state 迁移失败后 state 应回滚"

    normalize_config_schema false || fail "Reality schema 迁移失败"
    jq -e '.inbounds[0].streamSettings.realitySettings.target == "example.com:443"' "$CONFIG_FILE" >/dev/null ||
        fail "Reality dest 未迁移到 target"
    jq -e '.inbounds[0].streamSettings.realitySettings.minClientVer == "0.0.0"' "$CONFIG_FILE" >/dev/null ||
        fail "Reality 迁移未补 minClientVer"
    jq -e '.inbounds[0].streamSettings.realitySettings | has("dest") | not' "$CONFIG_FILE" >/dev/null ||
        fail "Reality 迁移后仍保留 dest"
    echo "[OK] migrate dry-run 与 Reality schema 迁移"
)

test_unique_backups_and_safe_removal() (
    CONFIG_DIR="${TMP_DIR}/backup"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{}' >"$CONFIG_FILE"
    backup_config || fail "第一次配置备份失败"
    backup_config || fail "第二次配置备份失败"
    local -a backups=()
    mapfile -t backups < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name 'config.json.bak.*')
    [[ ${#backups[@]} -eq 2 ]] || fail "同一秒内配置备份发生覆盖"

    if remove_managed_tree / >/dev/null 2>&1; then
        fail "安全删除函数不得接受根目录"
    fi
    if remove_managed_tree "/../tmp/xray-oneclick-invalid" >/dev/null 2>&1; then
        fail "安全删除函数不得接受路径跳转"
    fi
    mkdir -p "${CONFIG_DIR}/managed/child"
    remove_managed_tree "${CONFIG_DIR}/managed" || fail "安全删除受管目录失败"
    [[ -d "$CONFIG_DIR" && ! -e "${CONFIG_DIR}/managed" ]] || fail "安全删除范围错误"
    echo "[OK] 唯一备份与安全删除边界"
)

test_xray_binary_replacement_rollback() (
    local root="${TMP_DIR}/binary"
    mkdir -p "$root"
    BIN_PATH="${root}/xray"
    printf '%s\n' old >"$BIN_PATH"
    printf '%s\n' new >"${root}/candidate"
    chmod +x "$BIN_PATH" "${root}/candidate"

    validate_xray_binary_path "$BIN_PATH" || fail "合法 Xray 二进制路径被拒绝"
    validate_xray_binary_path "/etc/passwd" >/dev/null 2>&1 && fail "危险的非 Xray 文件路径不得通过校验"

    replace_xray_binary "${root}/candidate" || fail "Xray 二进制替换失败"
    assert_eq "new" "$(tr -d '\r\n' <"$BIN_PATH")" "替换后应使用新二进制"
    rollback_xray_binary_replacement "$XRAY_REPLACED_BACKUP_PATH" "$XRAY_REPLACED_HAD_ORIGINAL" ||
        fail "Xray 二进制回滚失败"
    assert_eq "old" "$(tr -d '\r\n' <"$BIN_PATH")" "回滚后应恢复旧二进制"
    echo "[OK] Xray 二进制事务回滚"
)

test_endpoint_validation() (
    validate_port "08" || fail "带前导零的十进制端口不应触发八进制解析错误"
    validate_endpoint_value "example.com" || fail "合法域名 endpoint 被拒绝"
    validate_endpoint_value "example.com:443" || fail "合法域名端口 endpoint 被拒绝"
    validate_endpoint_value "[2001:4860:4860::8888]:443" || fail "合法 IPv6 endpoint 被拒绝"
    validate_endpoint_value "https://example.com" && fail "endpoint 不得接受 URL"
    validate_endpoint_value "example.com:99999" && fail "endpoint 不得接受越界端口"
    validate_endpoint_value "999.1.1.1" && fail "endpoint 不得接受无效 IPv4"
    echo "[OK] Endpoint 格式与端口边界"
)

test_cli_failure_propagation() (
    show_xray_usage() { :; }
    run_xray_command unknown >/dev/null 2>&1 && fail "未知 xray 子命令不得返回成功"
    ensure_xray_service() { return 1; }
    validate_config_file() { return 0; }
    run_service_command repair >/dev/null 2>&1 && fail "service repair 不得吞掉修复失败"
    run_preflight_command extra >/dev/null 2>&1 && fail "preflight 不得忽略额外参数"
    run_logs_command extra >/dev/null 2>&1 && fail "logs 不得忽略额外参数"
    run_bootstrap_command extra >/dev/null 2>&1 && fail "bootstrap 不得忽略额外参数"
    run_doctor_command all extra >/dev/null 2>&1 && fail "doctor 不得忽略额外参数"

    ensure_root() { :; }
    check_os() { INIT_SYSTEM="test"; }
    detect_arch() { :; }
    apply_env_endpoint_if_needed() { :; }
    update_xray_core() { fail "update 参数错误时不应执行更新"; }
    export_current_config_backup() { fail "backup 参数错误时不应执行备份"; }
    main update extra >/dev/null 2>&1 && fail "update 不得忽略额外参数"
    main backup extra >/dev/null 2>&1 && fail "backup 不得忽略额外参数"
    echo "[OK] CLI 失败状态传播"
)

test_secret_reset_restart_rollback() (
    CONFIG_DIR="${TMP_DIR}/reset"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<JSON
{"inbounds":[{"tag":"${SOCKS_TAG}","port":1080,"protocol":"socks","settings":{"auth":"password","accounts":[{"user":"admin","pass":"old-password"}]}}],"outbounds":[]}
JSON
    printf '%s\n' '{}' >"$STATE_FILE"
    init_state || fail "初始化密钥重置测试 state 失败"
    cp -a "$CONFIG_FILE" "${CONFIG_DIR}/expected-config.json"
    cp -a "$STATE_FILE" "${CONFIG_DIR}/expected-state.json"
    install_or_update_xray() { return 0; }
    validate_config_file() { return 0; }
    view_config() { :; }
    local restart_count=0
    restart_service() {
        ((restart_count += 1))
        ((restart_count > 1))
    }

    if reset_secrets <<<"3" >/dev/null 2>&1; then
        fail "模拟服务重启失败时，密钥重置不得成功"
    fi
    cmp -s "$CONFIG_FILE" "${CONFIG_DIR}/expected-config.json" || fail "密钥重置失败后 config 未恢复"
    cmp -s "$STATE_FILE" "${CONFIG_DIR}/expected-state.json" || fail "密钥重置失败后 state 未恢复"
    echo "[OK] 密钥重置失败事务回滚"
)

test_keep_config_uninstall_scope() (
    local root="${TMP_DIR}/uninstall"
    CONFIG_DIR="${root}/etc/xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${root}/share/xray"
    INSTALLER_DIR="${root}/share/ike"
    INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
    BIN_PATH="${root}/bin/xray"
    SHORTCUT_PATH="${root}/bin/ike"
    XRAY_SERVICE_FILE="${root}/service/xray.service"
    XRAY_LOG_DIR="${root}/log/xray"
    INIT_SYSTEM="test"
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR" "$INSTALLER_DIR" "$(dirname "$BIN_PATH")"
    printf '%s\n' '{}' >"$CONFIG_FILE"
    printf '%s\n' '{}' >"$STATE_FILE"
    printf '%s\n' xray >"$BIN_PATH"
    printf '%s\n' ike >"$SHORTCUT_PATH"
    printf '%s\n' asset >"${ASSET_DIR}/geoip.dat"
    printf '%s\n' installer >"$INSTALLER_PATH"

    run_uninstall_command --keep-config --yes >/dev/null || fail "keep-config 卸载失败"
    [[ -f "$CONFIG_FILE" && -f "$STATE_FILE" ]] || fail "keep-config 卸载误删配置或 state"
    [[ ! -e "$BIN_PATH" && ! -e "$SHORTCUT_PATH" && ! -e "$ASSET_DIR" && ! -e "$INSTALLER_DIR" ]] ||
        fail "keep-config 卸载未清理程序或资源目录"
    echo "[OK] keep-config 卸载范围"
)

test_purge_aborts_when_backup_fails() (
    local root="${TMP_DIR}/purge"
    CONFIG_DIR="${root}/etc/xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${root}/share/xray"
    INSTALLER_DIR="${root}/share/ike"
    BIN_PATH="${root}/bin/xray"
    SHORTCUT_PATH="${root}/bin/ike"
    XRAY_SERVICE_FILE="${root}/service/xray.service"
    XRAY_LOG_DIR="${root}/log/xray"
    INIT_SYSTEM="test"
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR" "$INSTALLER_DIR" "$(dirname "$BIN_PATH")"
    printf '%s\n' '{}' >"$CONFIG_FILE"
    printf '%s\n' xray >"$BIN_PATH"
    create_purge_backup() { return 1; }

    run_uninstall_command --purge --yes >/dev/null 2>&1 && fail "purge 备份失败时不得继续卸载"
    [[ -f "$CONFIG_FILE" && -f "$BIN_PATH" ]] || fail "purge 备份失败后仍删除了文件"
    echo "[OK] purge 备份失败中止卸载"
)

mkdir -p "$MOCK_BIN"
cat >"${MOCK_BIN}/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
version="4"
url=""
printf '%s\n' "$*" >>"${MOCK_CURL_LOG:?}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -4) version="4" ;;
        -6) version="6" ;;
        --noproxy | --connect-timeout | --max-time) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done

if [[ "${MOCK_ALL_PRIVATE:-false}" == "true" ]]; then
    [[ "$version" == "4" ]] && printf '10.0.0.9\n' || printf 'fd00::9\n'
    exit 0
fi
case "${version}:${url##*/}" in
    4:first) printf '10.0.0.8\n' ;;
    4:second) printf '8.8.8.8\n' ;;
    6:first) printf 'not:an:ip\n' ;;
    6:second) printf '2001:4860:4860::8888\n' ;;
    *) exit 22 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/curl"

cat >"${MOCK_BIN}/ip" <<'MOCK'
#!/usr/bin/env sh
printf '%s\n' \
  '1: eth0    inet6 fd00::9/64 scope global' \
  '1: eth0    inet6 2001:4860:4860::8844/64 scope global'
MOCK
chmod +x "${MOCK_BIN}/ip"

# shellcheck source=../install.sh
source "${REPO_ROOT}/install.sh"
ASSET_DIR="${TMP_DIR}/assets"

test_public_ip_detection() {
    export PATH="${MOCK_BIN}:$PATH"
    export MOCK_CURL_LOG XRAY_ONECLICK_IP_SOURCES="https://mock.invalid/first,https://mock.invalid/second"
    XRAY_ONECLICK_IP_CONNECT_TIMEOUT="1"
    XRAY_ONECLICK_IP_MAX_TIME="1"
    PUBLIC_ADDRESS_PROBED="false"
    PUBLIC_IPV4=""
    PUBLIC_IPV6=""
    : >"$MOCK_CURL_LOG"

    assert_eq "2001:4860:4860::8844" "$(detect_global_ipv6)" "本机 IPv6 探测应跳过 ULA 并选择公网地址"

    is_public_ipv4 "192.168.1.1" && fail "私网 IPv4 不得通过公网校验"
    is_public_ipv4 "999.1.1.1" && fail "无效 IPv4 不得通过公网校验"
    is_public_ipv6 "2001:db8::1" && fail "文档保留 IPv6 不得通过公网校验"
    is_public_ipv6 "2001:0db8::1" && fail "带前导零的文档 IPv6 不得通过公网校验"
    is_public_ipv6 "3fff::1" && fail "文档前缀 3fff::/20 不得通过公网校验"
    is_public_ipv6 "1:2" && fail "不完整 IPv6 不得通过公网校验"
    is_public_ipv6 "2001:4860:4860::8888" || fail "有效公网 IPv6 未通过校验"

    detect_global_ipv6() { printf '%s' '2001:4860:4860::8844'; }
    get_public_addresses
    assert_eq "8.8.8.8" "$PUBLIC_IPV4" "应跳过私网 IPv4 并选择有效公网地址"
    assert_eq "2001:4860:4860::8888" "$PUBLIC_IPV6" "应跳过无效 IPv6"
    grep -q -- '--noproxy \*' "$MOCK_CURL_LOG" || fail "公网探测必须绕过代理环境"

    export MOCK_ALL_PRIVATE="true"
    PUBLIC_ADDRESS_PROBED="false"
    PUBLIC_IPV4=""
    PUBLIC_IPV6=""
    : >"$MOCK_CURL_LOG"
    detect_global_ipv6() { return 1; }
    hostname() { printf '%s\n' '10.10.0.5 172.16.0.8'; }
    get_public_addresses
    assert_eq "" "$PUBLIC_IPV4" "公网探测失败时不得回退到私网 IPv4"
    assert_eq "" "$PUBLIC_IPV6" "没有全局 IPv6 时不得生成 IPv6 endpoint"
    grep -q -- '-6' "$MOCK_CURL_LOG" && fail "没有全局 IPv6 时不应访问 IPv6 探测服务"
    unset MOCK_ALL_PRIVATE

    PUBLIC_ADDRESS_PROBED="true"
    PUBLIC_IPV4="8.8.4.4"
    PUBLIC_IPV6=""
    assert_eq "8.8.4.4" "$(endpoint_auto_value)" "endpoint 应复用已探测的公网地址"
    echo "[OK] 公网 IP 探测"
}

test_prerelease_asset_selection_and_digest() {
    XRAY_ASSET="Xray-linux-64.zip"
    xray_release_metadata() {
        printf '%s' '{"tag_name":"v-test","prerelease":true,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/xray.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
    }

    local info url version prerelease digest archive expected
    info="$(xray_release_asset_info latest prerelease)" || fail "prerelease 资产解析失败"
    IFS=$'\t' read -r url version prerelease digest <<<"$info"
    assert_eq "https://example.invalid/xray.zip" "$url" "prerelease 下载地址错误"
    assert_eq "v-test" "$version" "prerelease 版本错误"
    assert_eq "true" "$prerelease" "prerelease 标志错误"
    assert_eq "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$digest" "prerelease 摘要错误"

    archive="${TMP_DIR}/digest.txt"
    printf '%s' 'digest-test' >"$archive"
    expected="$(sha256sum "$archive" | awk '{print $1}')"
    verify_xray_asset_digest "$archive" "sha256:${expected}" >/dev/null || fail "正确摘要未通过校验"
    if verify_xray_asset_digest "$archive" 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >/dev/null 2>&1; then
        fail "错误摘要不应通过校验"
    fi
    echo "[OK] prerelease 与 SHA-256 校验"
}

test_hysteria_remove_preserves_cert_on_failure() {
    CONFIG_DIR="${TMP_DIR}/hy2"
    mkdir -p "$CONFIG_DIR"
    printf '%s' cert >"$(hysteria2_cert_path)"
    printf '%s' key >"$(hysteria2_key_path)"
    remove_simple_inbound_config() { return 1; }

    if remove_hysteria2_config; then
        fail "Hysteria2 配置删除失败时不应报告成功"
    fi
    [[ -f "$(hysteria2_cert_path)" && -f "$(hysteria2_key_path)" ]] ||
        fail "Hysteria2 配置删除失败时必须保留证书"
    echo "[OK] Hysteria2 删除回滚"
}

test_official_digest_fallback() (
    XRAY_ASSET="Xray-linux-64.zip"
    local official_url="https://github.com/XTLS/Xray-core/releases/download/v26.11.9/$XRAY_ASSET"
    local fixture="$TMP_DIR/archive" download="$TMP_DIR/download" requests_log="$TMP_DIR/download.log" fixture_digest
    printf '%s' official >"$fixture"
    fixture_digest="$(sha256sum "$fixture" | cut -d' ' -f1)"
    xray_release_metadata() {
        jq -cn --arg asset "$XRAY_ASSET" --arg url "${mock_url:-$official_url}" --argjson pre "${mock_prerelease:-false}" '
          {tag_name: "v26.11.9", prerelease: $pre, assets: [{name: $asset, browser_download_url: $url}]}
        '
    }
    download_one_url() {
        printf '%s\n' "$1" >>"$requests_log"
        case "$1" in
            "$official_url.dgst")
                [[ "${mock_checksum:-true}" == "true" ]] || return 1
                printf 'SHA2-256= %s\n' "$fixture_digest" >"$2"
                ;;
            "$official_url") cp "$fixture" "$2" ;;
            *) return 1 ;;
        esac
    }
    verify_xray_archive() { cmp -s "$1" "$fixture" && [[ "$3" == "v26.11.9" ]]; }
    download_xray_core latest stable "$download" >/dev/null || fail "official .dgst fallback failed"
    assert_eq "$official_url.dgst" "$(head -n 1 "$requests_log")" "fallback checksum must come from the official release"
    : >"$requests_log"
    if mock_checksum=false download_xray_core latest stable "$download" >/dev/null 2>&1; then
        fail "asset installation succeeded without a trusted checksum"
    fi
    assert_eq "$official_url.dgst" "$(cat "$requests_log")" "archive or mirror was fetched before obtaining a checksum"
    if mock_prerelease=true download_xray_core latest stable "$download" >/dev/null 2>&1; then
        fail "stable channel accepted a prerelease"
    fi
    if mock_url=https://example.invalid/wrong.zip download_xray_core latest stable "$download" >/dev/null 2>&1; then
        fail "release metadata supplied an unexpected asset URL"
    fi
    echo "[OK] 官方 .dgst 回退、缺摘要中止、发布通道及资产路径检查"
)

test_redacted_report_contains_no_client_credentials() (
    CONFIG_DIR="${TMP_DIR}/report"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    BIN_PATH="${CONFIG_DIR}/xray-missing"
    INIT_SYSTEM="test"
    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"tag":"vless+tcp+reality","port":443,"protocol":"vless","settings":{"clients":[{"id":"secret-uuid"}]},"streamSettings":{"realitySettings":{"serverNames":["example.com"]}}},
    {"tag":"hysteria2-in","port":8443,"protocol":"hysteria","settings":{"clients":[{"auth":"hy-secret"}]},"streamSettings":{"finalmask":{"udp":[{"type":"salamander"}]}}}
  ]
}
JSON
    cat >"$STATE_FILE" <<'JSON'
{
  "meta":{"last_action":"测试安装","last_updated_at":"2026-11-21T00:00:00Z"},
  "vless_reality":{"public_key":"public","default_short_id":"short","link":"vless://secret-uuid@example.com:443"},
  "hysteria2":{"port":8443,"sni":"example.com","auth":"hy-secret","link":"hysteria2://hy-secret@example.com:8443"}
}
JSON
    xray_service_status() { printf '%s' stopped; }
    xray_config_test_status() { printf '%s' skipped; }
    installed_protocols_summary() { printf '%s' test; }
    journalctl() { return 0; }
    get_public_addresses() { PUBLIC_IPV4="" PUBLIC_IPV6=""; }
    run_xray_config_test_verbose() { :; }
    doctor_reality_port() { :; }

    local report
    report="$(render_export_report)"
    [[ "$report" != *'vless://'* && "$report" != *'hysteria2://'* ]] || fail "脱敏报告仍包含客户端链接"
    [[ "$report" != *'secret-uuid'* && "$report" != *'hy-secret'* ]] || fail "脱敏报告仍包含客户端凭据"
    [[ "$report" == *'***REDACTED***'* ]] || fail "脱敏报告未标记已脱敏字段"
    report="$(view_config dual doctor)"
    [[ "$report" != *'hy-secret'* && "$report" != *'hysteria2://'* && "$report" != *'vless://'* ]] ||
        fail "完整诊断输出了客户端凭据"
    [[ "$report" == *'测试安装'* && "$report" == *'2026-11-21T00:00:00Z'* ]] || fail "完整诊断缺少最近变更信息"
    print_reality_result() { fail "smoke 不应显示客户端链接"; }
    run_smoke_command reality >/dev/null
    echo "[OK] 脱敏诊断报告"
)

test_vless_state_is_not_committed_before_apply() {
    CONFIG_DIR="${TMP_DIR}/vless"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}' >"$CONFIG_FILE"
    printf '%s\n' '{}' >"$STATE_FILE"
    VLESS_LISTEN="0.0.0.0"
    VLESS_PORT="8443"
    VLESS_UUID="new-uuid"
    VLESS_DECRYPTION="new-decryption"
    VLESS_ENCRYPTION="new-encryption"
    VLESS_AUTH="x25519"
    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"
    backup_config() { cp "$CONFIG_FILE" "${TMP_DIR}/vless-backup.json"; }
    apply_config() {
        cp "${TMP_DIR}/vless-backup.json" "$CONFIG_FILE"
        return 1
    }

    if install_vless_encryption >/dev/null 2>&1; then
        fail "模拟配置应用失败时 VLESS 安装不应成功"
    fi
    jq -e 'has("vless_encryption") | not' "$STATE_FILE" >/dev/null || fail "配置应用失败前不应提交 VLESS state"
    jq -e '(.inbounds | length) == 0' "$CONFIG_FILE" >/dev/null || fail "模拟回滚后配置未恢复"
    echo "[OK] VLESS 配置/状态提交顺序"
}

test_bootstrap_ref_consistency() {
    grep -q 'IKE_LIB_RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}/lib"' "${REPO_ROOT}/scripts/bootstrap.sh" ||
        fail "bootstrap 未将模块下载固定到同一 ref"
    echo "[OK] bootstrap ref 一致性"
}

test_installer_creates_only_primary_shortcut() {
    local root="${TMP_DIR}/installer"
    local -a shortcuts=()

    SHORTCUT_PATH="${root}/bin/ike"
    INSTALLER_DIR="${root}/share/ike"
    INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
    IKE_INSTALLER_DIR="$REPO_ROOT"
    install_shortcut
    mapfile -t shortcuts < <(find "${root}/bin" -maxdepth 1 -type f -print)
    [[ ${#shortcuts[@]} -eq 1 && "${shortcuts[0]}" == "$SHORTCUT_PATH" ]] ||
        fail "安装器应只创建主快捷命令"
    [[ -x "$SHORTCUT_PATH" ]] || fail "主快捷命令不可执行"
    IKE_INSTALLER_DIR="$INSTALLER_DIR"
    install_shortcut || fail "从已安装目录重复部署快捷命令失败"
    echo "[OK] 安装器单一快捷命令"
}

test_tunnel_exports_are_unique_and_complete() (
    CONFIG_DIR="${TMP_DIR}/tunnel-export/config"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    FORWARD_EXPORT_DIR="${TMP_DIR}/tunnel-export/files"
    TUNNEL_BUNDLE_EXPORT_DIR="${TMP_DIR}/tunnel-export/bundles"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"inbounds":[],"outbounds":[]}' >"$CONFIG_FILE"
    cat >"$STATE_FILE" <<'JSON'
{"tunnels":[{"tag":"tunnel-test","type":"single","group":"","listen":"0.0.0.0","listen_port":30000,"target":"example.com","target_port":443,"network":"tcp","mode":"safe","enabled":true,"remark":""}]}
JSON

    export_forward_rules >/dev/null || fail "第一次 Tunnel 导出失败"
    export_forward_rules >/dev/null || fail "第二次 Tunnel 导出失败"
    [[ "$(find "$FORWARD_EXPORT_DIR" -maxdepth 1 -type f -name 'xray-tunnels-*.json' | wc -l)" -eq 2 ]] ||
        fail "同一秒内 Tunnel 导出不应覆盖"

    export_tunnel_bundle >/dev/null || fail "第一次 Tunnel 部署包导出失败"
    export_tunnel_bundle >/dev/null || fail "第二次 Tunnel 部署包导出失败"
    local -a bundles=()
    mapfile -t bundles < <(find "$TUNNEL_BUNDLE_EXPORT_DIR" -mindepth 1 -maxdepth 1 -type d)
    [[ ${#bundles[@]} -eq 2 ]] || fail "同一秒内 Tunnel 部署包不应复用目录"
    local bundle
    for bundle in "${bundles[@]}"; do
        [[ -s "$bundle/tunnels.json" && -s "$bundle/README.txt" && -x "$bundle/install-tunnels.sh" ]] ||
            fail "Tunnel 部署包文件不完整"
        jq -e '.type == "xray-oneclick-tunnels" and (.tunnels | length) == 1' "$bundle/tunnels.json" >/dev/null ||
            fail "Tunnel 部署包内容无效"
    done
    echo "[OK] Tunnel 导出唯一性与完整性"
)

test_migrate_dry_run_and_schema_upgrade
test_unique_backups_and_safe_removal
test_xray_binary_replacement_rollback
test_endpoint_validation
test_cli_failure_propagation
test_secret_reset_restart_rollback
test_keep_config_uninstall_scope
test_purge_aborts_when_backup_fails
test_public_ip_detection
test_prerelease_asset_selection_and_digest
test_official_digest_fallback
test_hysteria_remove_preserves_cert_on_failure
test_redacted_report_contains_no_client_credentials
test_vless_state_is_not_committed_before_apply
test_bootstrap_ref_consistency
test_installer_creates_only_primary_shortcut
test_tunnel_exports_are_unique_and_complete
echo "[OK] 回归测试全部通过"
