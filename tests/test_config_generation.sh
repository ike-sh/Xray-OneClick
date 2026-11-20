#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ike-config-generation.XXXXXX")"
TEST_BIN_DIR="${TMP_DIR}/bin"
mkdir -p "$TEST_BIN_DIR"

REALITY_TAG="vless+tcp+reality"
REALITY_DEFENDER_TAG="reality-defender"
XHTTP_TAG="vless-enc-xhttp-finalmask-in"
XHTTP_REALITY_TAG="vless+xhttp+reality"
ENC_REALITY_TAG="vless+enc+reality"
FULLSTACK_TAG="vless+enc+xhttp+reality+finalmask"
ENC_FM_TAG="vless-enc-tcp-finalmask-in"
ENC_XHTTP_TAG="vless-enc-xhttp-in"
HY2_TAG="hysteria2-in"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少依赖命令: $1"
}

require_cmd bash

setup_jq() {
    local jq_exe

    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    jq_exe="$(command -v jq.exe 2>/dev/null || true)"
    if [[ -n "$jq_exe" ]]; then
        cat >"${TEST_BIN_DIR}/jq" <<EOF
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
    if [[ "\$arg" == /* || "\$arg" == ./* || "\$arg" == ../* ]] && [[ -e "\$arg" ]] && command -v wslpath >/dev/null 2>&1; then
        args+=("\$(wslpath -w "\$arg")")
    else
        args+=("\$arg")
    fi
done
exec "$jq_exe" "\${args[@]}"
EOF
        chmod +x "${TEST_BIN_DIR}/jq"
        export PATH="${TEST_BIN_DIR}:$PATH"
        return 0
    fi
    fail "缺少依赖命令: jq"
}

setup_jq

XRAY_TEST_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_TEST_BIN" ]]; then
    XRAY_TEST_BIN="$(command -v xray 2>/dev/null || true)"
fi

prepare_xray_test_certificates() {
    local config="$1"
    local cert_file key_file

    while IFS=$'\t' read -r cert_file key_file; do
        [[ -n "$cert_file" && -n "$key_file" ]] || continue
        [[ -s "$cert_file" && -s "$key_file" ]] && continue
        command -v openssl >/dev/null 2>&1 || return 1
        mkdir -p "$(dirname "$cert_file")" "$(dirname "$key_file")"
        openssl req -x509 -nodes -newkey rsa:2048 \
            -subj '/CN=localhost' -days 1 \
            -keyout "$key_file" -out "$cert_file" >/dev/null 2>&1 || return 1
    done < <(jq -r '
      .. | objects |
      select((.certificateFile? | type) == "string" and (.keyFile? | type) == "string") |
      [.certificateFile, .keyFile] | @tsv
    ' "$config")
}

run_xray_config_test_if_available() {
    local config="$1"

    if [[ -n "$XRAY_TEST_BIN" && -x "$XRAY_TEST_BIN" ]]; then
        if ! prepare_xray_test_certificates "$config"; then
            echo "[SKIP] 缺少 openssl，无法准备测试证书: $config"
            return 0
        fi
        "$XRAY_TEST_BIN" run -test -c "$config" >/dev/null ||
            fail "xray run -test 未通过: $config"
        echo "[OK] xray run -test: $config"
    else
        echo "[SKIP] 未找到可执行 xray，跳过 xray run -test: $config"
    fi
}

run_case() {
    local name="$1"
    shift
    local case_dir="${TMP_DIR}/${name}"
    local out="${case_dir}/config.json"

    mkdir -p "$case_dir"
    echo "[CASE] $name"
    IKE_TEST_ROOT="${case_dir}/root" IKE_CONFIG_OUT="$out" bash "$INSTALL_SH" test-config-generate "$@" >/dev/null
    [[ -s "$out" ]] || fail "$name 未生成 config.json"
    jq . "$out" >/dev/null || fail "$name 生成的 JSON 无效"
    assert_no_reality_dest "$out"
    run_xray_config_test_if_available "$out"
    LAST_CONFIG="$out"
}

assert_no_reality_dest() {
    local config="$1"

    jq -e '([.. | objects | .realitySettings? | select(type == "object" and has("dest"))] | length) == 0' "$config" >/dev/null ||
        fail "新生成配置包含 realitySettings.dest: $config"
}

assert_reality_target() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      any(.inbounds[]?; .tag == $tag and ((.streamSettings.realitySettings.target // "") | length > 0))
    ' "$config" >/dev/null || fail "缺少 realitySettings.target: tag=$tag config=$config"
    jq -e --arg tag "$tag" '
      any(.inbounds[]?; .tag == $tag and .streamSettings.realitySettings.minClientVer == "0.0.0")
    ' "$config" >/dev/null || fail "realitySettings.minClientVer 未设置为 0.0.0: tag=$tag config=$config"
}

assert_reality_defender() {
    local config="$1"

    jq -e --arg tag "$REALITY_TAG" --arg defender "$REALITY_DEFENDER_TAG" --arg block "BLOCK" '
      any(.inbounds[]?; .tag == $tag) and
      any(.inbounds[]?; .tag == $defender and .listen == "127.0.0.1") and
      any(.routing.rules[]?; ((.inboundTag // []) | index($defender)) and .outboundTag == "direct") and
      any(.routing.rules[]?; ((.inboundTag // []) | index($defender)) and .outboundTag == $block)
    ' "$config" >/dev/null || fail "普通 Reality defender/routing 缺失: $config"
}

assert_no_finalmask() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      ([.inbounds[]? | select(.tag == $tag) | (.streamSettings | has("finalmask"))] | index(true) | not)
    ' "$config" >/dev/null || fail "FinalMask off 时仍写入 streamSettings.finalmask: tag=$tag config=$config"
}

assert_finalmask_balanced() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings.finalmask) as $fm |
      ($fm | type == "object") and
      ($fm.tcp | type == "array") and
      ($fm.tcp[0].type == "fragment") and
      ($fm.tcp[0].settings.packets == "tlshello") and
      ($fm.tcp[0].settings.length == "100-200") and
      ($fm.tcp[0].settings.delay == "10-20") and
      ($fm.tcp[0].settings.maxSplit == "3-6")
    ' "$config" >/dev/null || fail "FinalMask balanced 配置不合法: tag=$tag config=$config"
}

assert_finalmask_sudoku() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings.finalmask) as $fm |
      ($fm | type == "object") and
      ($fm.tcp | type == "array") and
      ($fm.tcp[0].type == "sudoku") and
      (($fm.tcp[0].settings.password // "") | length > 0)
    ' "$config" >/dev/null || fail "FinalMask sudoku 配置不合法(应含 settings.password): tag=$tag config=$config"
}

assert_tcp_security_none() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings) as $ss |
      ($ss.network == "tcp") and ($ss.security == "none")
    ' "$config" >/dev/null || fail "ENC-FinalMask 入站 network/security 不正确: tag=$tag config=$config"
}

assert_xhttp_plain() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings) as $ss |
      ($ss.network == "xhttp") and ($ss.security == "none") and
      ($ss.xhttpSettings | type == "object") and ($ss.xhttpSettings | has("path")) and
      (($ss | has("finalmask")) | not)
    ' "$config" >/dev/null || fail "ENC-XHTTP 入站结构不正确(应为 xhttp/none/含xhttpSettings.path/无finalmask): tag=$tag config=$config"
}

assert_hysteria2() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag)) as $in |
      ($in.protocol == "hysteria") and
      ($in.settings.version == 2) and
      (($in.settings.clients[0].auth // "") | length > 0) and
      ($in.streamSettings.network == "hysteria") and
      ($in.streamSettings.security == "tls") and
      ($in.streamSettings.hysteriaSettings.version == 2) and
      (($in.streamSettings.tlsSettings.certificates[0].certificateFile // "") | length > 0) and
      ($in.streamSettings.finalmask.udp[0].type == "salamander") and
      (($in.streamSettings.finalmask.udp[0].settings.password // "") | length > 0)
    ' "$config" >/dev/null || fail "Hysteria2 入站结构不正确: tag=$tag config=$config"
}

assert_fallback_limit() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      .inbounds[]? |
      select(.tag == $tag).streamSettings.realitySettings |
      has("limitFallbackUpload") and has("limitFallbackDownload") and
      (.limitFallbackUpload | type == "object") and
      (.limitFallbackDownload | type == "object")
    ' "$config" >/dev/null || fail "fallback-limit conservative 未写入 limitFallbackUpload/Download: tag=$tag config=$config"
}

run_case "reality" reality --port 30004 --defender-port 40004 --sni www.microsoft.com
assert_reality_target "$LAST_CONFIG" "$REALITY_TAG"
assert_reality_defender "$LAST_CONFIG"

run_case "xhttp_off" xhttp-off --port 30005 --path /api/off
assert_no_finalmask "$LAST_CONFIG" "$XHTTP_TAG"

run_case "xhttp_balanced" xhttp-balanced --port 30005 --path /api/balanced --finalmask-preset balanced
assert_finalmask_balanced "$LAST_CONFIG" "$XHTTP_TAG"

run_case "xhttp_reality" xhttp-reality --port 30006 --path /api/xhttp-reality --sni www.microsoft.com
assert_reality_target "$LAST_CONFIG" "$XHTTP_REALITY_TAG"

run_case "enc_reality" enc-reality --port 30007 --sni www.microsoft.com
assert_reality_target "$LAST_CONFIG" "$ENC_REALITY_TAG"

run_case "fullstack_off" fullstack --port 30008 --path /api/fullstack-off --sni www.microsoft.com --finalmask off
assert_reality_target "$LAST_CONFIG" "$FULLSTACK_TAG"
assert_no_finalmask "$LAST_CONFIG" "$FULLSTACK_TAG"

run_case "fullstack_balanced" fullstack --port 30008 --path /api/fullstack-balanced --sni www.microsoft.com --finalmask on --finalmask-preset balanced
assert_reality_target "$LAST_CONFIG" "$FULLSTACK_TAG"
assert_finalmask_balanced "$LAST_CONFIG" "$FULLSTACK_TAG"

run_case "xhttp_reality_fallback_limit" xhttp-reality --port 30009 --path /api/xhttp-reality-limit --sni www.microsoft.com --fallback-limit conservative
assert_reality_target "$LAST_CONFIG" "$XHTTP_REALITY_TAG"
assert_fallback_limit "$LAST_CONFIG" "$XHTTP_REALITY_TAG"

run_case "enc_finalmask" enc-finalmask --port 30010
assert_finalmask_sudoku "$LAST_CONFIG" "$ENC_FM_TAG"
assert_tcp_security_none "$LAST_CONFIG" "$ENC_FM_TAG"

run_case "enc_xhttp" enc-xhttp --port 30011 --path /api/enc-xhttp
assert_xhttp_plain "$LAST_CONFIG" "$ENC_XHTTP_TAG"

run_case "hysteria2" hysteria2 --port 30012 --sni www.microsoft.com
assert_hysteria2 "$LAST_CONFIG" "$HY2_TAG"

run_legacy_case() (
    local profile="$1" IKE_TEST_ROOT="$TMP_DIR/$1/root"
    echo "[CASE] $profile"
    # shellcheck source=../install.sh
    source "$INSTALL_SH"
    setup_test_config_generation_env
    install_or_update_xray() { :; }
    restart_service() { :; }
    view_config() { :; }
    if [[ ! -x "$BIN_PATH" ]]; then
        validate_config_file() { validate_json_object "$CONFIG_FILE"; }
    fi
    case "$profile" in
        ss2022_ipv4)
            configure_ss2022 ipv4 <<< $'1\n31010\n'
            install_ss2022
            jq -e '.inbounds[] | select(.tag == "ss2022-in" and .listen == "0.0.0.0")' "$CONFIG_FILE" >/dev/null
            ;;
        ss2022_ipv6)
            configure_ss2022 ipv6 <<< $'2\n31011\n'
            install_ss2022
            jq -e '.inbounds[] | select(.tag == "ss2022-in" and .listen == "::")' "$CONFIG_FILE" >/dev/null
            ;;
        vless_encryption)
            configure_vless_encryption <<< $'1\n1\n31012\n'
            install_vless_encryption
            jq -e '.inbounds[] | select(.tag == "vless-enc-in" and .protocol == "vless")' "$CONFIG_FILE" >/dev/null
            ;;
        socks5)
            install_socks5 <<< $'31013\ntest-user\ntest-password\n'
            jq -e '.inbounds[] | select(.tag == "socks-in" and .settings.udp == true)' "$CONFIG_FILE" >/dev/null
            ;;
        tunnel | tunnel_port_map)
            FORWARD_LISTEN="127.0.0.1" FORWARD_LISTEN_PORT=31014 FORWARD_TARGET="127.0.0.1"
            FORWARD_TARGET_PORT=8080 FORWARD_NETWORK=tcp,udp FORWARD_MODE=relay FORWARD_REMARK=""
            if [[ "$profile" == "tunnel_port_map" ]]; then
                FORWARD_TYPE=portMap
                FORWARD_LISTEN_PORT=31015,31016
                FORWARD_PORT_MAP_JSON='{"31015":"127.0.0.1:8080","31016":"127.0.0.1:8081"}'
            fi
            install_forward_rule
            jq -e '.inbounds[] | select(.tag | startswith("tunnel-"))' "$CONFIG_FILE" >/dev/null
            ;;
    esac >"$IKE_TEST_ROOT/installer.log"
    run_xray_config_test_if_available "$CONFIG_FILE"
)

for profile in ss2022_ipv4 ss2022_ipv6 vless_encryption socks5 tunnel tunnel_port_map; do
    run_legacy_case "$profile"
done

echo "[OK] 离线配置生成测试全部通过"
