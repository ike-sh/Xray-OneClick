#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# shellcheck source=../install.sh
source "$REPO_ROOT/install.sh"

fail() { echo "[FAIL] $*" >&2; exit 1; }

setup_case() {
    CASE_ROOT="$TEST_ROOT/$1"
    mkdir -p "$CASE_ROOT"/{tmp,bin,service}
    CONFIG_DIR="$CASE_ROOT/xray-config"
    CONFIG_FILE="$CONFIG_DIR/config.json"
    STATE_FILE="$CONFIG_DIR/installer-state.json"
    LIVE_STATE_FILE="$STATE_FILE"
    ASSET_DIR="$CASE_ROOT/assets"
    BIN_PATH="$CASE_ROOT/bin/xray"
    SHORTCUT_PATH="$CASE_ROOT/bin/ike"
    INSTALLER_DIR="$CASE_ROOT/installer"
    INSTALLER_PATH="$INSTALLER_DIR/install.sh"
    XRAY_SERVICE_FILE="$CASE_ROOT/service/xray.service"
    XRAY_LOG_DIR="$CASE_ROOT/logs"
    export TMPDIR="$CASE_ROOT/tmp" CASE_ROOT HY2_TAG
    export XRAY_ONECLICK_TEST_EUID=0 XRAY_ONECLICK_ALLOW_FAKE_SYSTEMD=true
    export XRAY_ONECLICK_ENDPOINT="test.example"
    printf 'ID=debian\n' >"$CASE_ROOT/os-release"
    XRAY_ONECLICK_OS_RELEASE="$CASE_ROOT/os-release"
    check_os
    detect_arch

    trusted_ca_available() { [[ ! -e "$CASE_ROOT/no-ca" ]]; }
    command() {
        if [[ "${1:-}" == "-v" && -e "$CASE_ROOT/no-${2:-}" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    # Helpers model package discovery separately from package manager success.
    apt-get() {
        printf '%s\n' "$*" >>"$CASE_ROOT/apt.log"
        case " $* " in
            *" update "*)
                [[ ! -e "$CASE_ROOT/fail-update" ]] || return 100
                ;;
            *" install "*)
                [[ ! -e "$CASE_ROOT/fail-install" ]] || return 100
                [[ ! -e "$CASE_ROOT/no-repair" ]] || return 0
                fake_install_packages "$@"
                ;;
        esac
    }
    apk() { printf '%s\n' "$*" >>"$CASE_ROOT/apk.log"; fake_install_packages "$@"; }
    dnf() { printf '%s\n' "$*" >>"$CASE_ROOT/dnf.log"; fake_install_packages "$@"; }
    yum() { printf '%s\n' "$*" >>"$CASE_ROOT/yum.log"; fake_install_packages "$@"; }
    update-ca-certificates() { :; }
    update-ca-trust() { :; }

    # Keep actual unit generation, ownership detection and restart paths.
    systemctl() {
        case "$*" in
            'show --property=Version') printf '%s\n' Version=255 ;;
            'show --property=FragmentPath --value xray')
                if [[ -e "$CASE_ROOT/foreign-fragment" ]]; then
                    printf '%s\n' /usr/lib/systemd/system/xray.service
                elif [[ -f "$XRAY_SERVICE_FILE" ]]; then
                    printf '%s\n' "$XRAY_SERVICE_FILE"
                fi
                ;;
            'show --property=DropInPaths --value xray') : ;;
            'show --property=MainPID --value xray')
                [[ -e "$CASE_ROOT/active" ]] && echo 12345
                ;;
            'is-active --quiet xray') [[ -e "$CASE_ROOT/active" ]] ;;
            daemon-reload) : ;;
            'enable xray') touch "$CASE_ROOT/enabled" ;;
            'disable xray') rm -f "$CASE_ROOT/enabled" ;;
            'stop xray') rm -f "$CASE_ROOT/active" ;;
            'restart xray')
                printf '%s\n' restart >>"$CASE_ROOT/restarts"
                if [[ -e "$CASE_ROOT/fail-restart" ]]; then
                    rm -f "$CASE_ROOT/fail-restart" "$CASE_ROOT/active"
                    return 1
                fi
                [[ -f "$XRAY_SERVICE_FILE" && -x "$BIN_PATH" && -f "$CONFIG_FILE" ]] || return 1
                touch "$CASE_ROOT/active"
                ;;
            *) fail "unexpected systemctl call: $*" ;;
        esac
    }
    journalctl() { :; }
    sleep() { :; }
    ss() {
        local requested="${*: -1}" live
        [[ "$1" == "-H" && "$2" == "-aunp" ]] || fail "HY2 must query only UDP listeners: $*"
        if [[ -f "$CASE_ROOT/occupied" && "$requested" == "sport = :$(<"$CASE_ROOT/occupied")" ]]; then
            printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:* users:(("external",pid=2222,fd=7))\n' "${requested##*:}"
        fi
        if [[ -e "$CASE_ROOT/active" && ! -e "$CASE_ROOT/no-listener" ]]; then
            live="$(jq -r --arg tag "$HY2_TAG" '.inbounds[]? | select(.tag == $tag) | .port' "$CONFIG_FILE")"
            if [[ -n "$live" && "$requested" == "sport = :$live" ]]; then
                printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:* users:(("xray",pid=12345,fd=4))\n' "$live"
            fi
        fi
    }

    # The same mock executable serves both versions. Candidate run -test can fail
    # independently of the minimal probe and service actions.
    cat >"$CASE_ROOT/xray-template" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    version)
        if [[ -n "${old_core:-}" ]]; then echo 'Xray 25.8.29 (linux/amd64)'
        else echo 'Xray 26.11.9 (linux/amd64)'; fi
        ;;
    run)
        [[ "$2" == -test && "$3" == -c ]] || exit 2
        if [[ -n "${old_core:-}" ]] && grep -q '"protocol": "hysteria"' "$4"; then exit 1; fi
        if [[ -e "$CASE_ROOT/fail-validation" && "${4##*/}" != hysteria2-probe.json ]]; then exit 1; fi
        jq -e 'type == "object"' "$4" >/dev/null
        ;;
    *) exit 2 ;;
esac
MOCK
    chmod 755 "$CASE_ROOT/xray-template"
    download_xray_core() {
        [[ "$1" == latest && "$2" == stable ]] || fail "expected Stable download"
        printf '%s\n' download >>"$CASE_ROOT/downloads"
        mkdir -p "$3"
        cp -a "$CASE_ROOT/xray-template" "$3/xray"
        printf '%s\n' new-geo >"$3/geoip.dat"
        printf '%s\n' new-sites >"$3/geosite.dat"
        XRAY_EXTRACTED_BINARY="$3/xray"
        XRAY_DOWNLOAD_VERSION=v26.11.9
        XRAY_DOWNLOAD_IS_PRERELEASE=false
    }
}

fake_install_packages() {
    local package
    for package; do
        case "$package" in
            jq | openssl | unzip | flock) rm -f "$CASE_ROOT/no-$package" ;;
            ca-certificates) rm -f "$CASE_ROOT/no-ca" ;;
            iproute | iproute2) rm -f "$CASE_ROOT"/no-{ip,ss} ;;
            iproute2-minimal) rm -f "$CASE_ROOT/no-ip" ;;
            iproute2-ss) rm -f "$CASE_ROOT/no-ss" ;;
            systemd) rm -f "$CASE_ROOT/no-systemctl" ;;
            openrc)
                rm -f "$CASE_ROOT"/no-{rc-service,rc-update}
                # Use fake executable presence even on a host without OpenRC.
                rc-service() { :; }
                rc-update() { :; }
                ;;
        esac
    done
}

assert_absent() {
    local path
    for path; do [[ ! -e "$path" ]] || fail "unexpected deployment file: $path"; done
}

snapshot_node() {
    mkdir -p "$CASE_ROOT/before"
    cp -a "$CONFIG_FILE" "$STATE_FILE" "$(hysteria2_cert_path)" "$(hysteria2_key_path)" "$CASE_ROOT/before/"
}

assert_node_restored() {
    local path
    for path in "$CONFIG_FILE" "$STATE_FILE" "$(hysteria2_cert_path)" "$(hysteria2_key_path)"; do
        cmp -s "$path" "$CASE_ROOT/before/${path##*/}" || fail "rollback did not restore ${path##*/}"
    done
    [[ -e "$CASE_ROOT/active" && -e "$CASE_ROOT/enabled" ]] || fail "rollback did not restore service"
}

run_install() {
    main hysteria2 install "$@" >"$CASE_ROOT/result" 2>&1 || { sed -E '/链接:|密码:/d' "$CASE_ROOT/result" >&2; fail "Hysteria2 install"; }
}

expect_failure() {
    if "$@" >"$CASE_ROOT/error" 2>&1; then fail "expected failure: $*"; fi
    if grep -q '\[完成\].*Hysteria2' "$CASE_ROOT/error"; then fail "printed successful deployment after failure"; fi
}

test_fresh_and_repeat() (
    setup_case fresh
    touch "$CASE_ROOT/no-wget"
    assert_absent "$CONFIG_FILE" "$STATE_FILE" "$BIN_PATH"
    run_install
    assert_absent "$CASE_ROOT/apt.log"
    [[ -x "$BIN_PATH" && -x "$SHORTCUT_PATH" && -f "$XRAY_SERVICE_FILE" ]] || fail "fresh deployment missing core, shortcut or unit"
    jq -e '.hysteria2.port == 443 and .endpoint.custom == "test.example"' "$STATE_FILE" >/dev/null
    openssl x509 -in "$(hysteria2_cert_path)" -noout -ext subjectAltName | grep -q 'DNS:localhost'
    verify_hysteria2_cert "$(hysteria2_cert_path)" "$(hysteria2_key_path)" || fail "certificate and key mismatch"
    snapshot_node
    run_install
    assert_node_restored
    [[ "$(wc -l <"$CASE_ROOT/restarts")" == 1 && "$(wc -l <"$CASE_ROOT/downloads")" == 1 ]] || fail "repeat restarted or downloaded"
    run_install --port 8443
    jq -e --slurpfile before "$CASE_ROOT/before/installer-state.json" '
      .hysteria2.port == 8443 and .hysteria2.auth == $before[0].hysteria2.auth and .hysteria2.obfs == $before[0].hysteria2.obfs
    ' "$STATE_FILE" >/dev/null
    cmp -s "$(hysteria2_cert_path)" "$CASE_ROOT/before/hysteria2-cert.pem" || fail "ordinary update rotated the certificate"
    expect_failure main hysteria2 rotate-cert --sni node.example
    expect_failure main hysteria2 install --sni node.example
    main hysteria2 rotate-cert --sni 192.0.2.5 --yes >/dev/null
    openssl x509 -in "$(hysteria2_cert_path)" -noout -ext subjectAltName | grep -q 'IP Address:192.0.2.5'
    main hysteria2 rotate-credentials --yes >/dev/null
    jq -e --slurpfile before "$CASE_ROOT/before/installer-state.json" '
      .hysteria2.auth != $before[0].hysteria2.auth and .hysteria2.obfs != $before[0].hysteria2.obfs
    ' "$STATE_FILE" >/dev/null
    echo "[OK] 全新 Hysteria2、默认端口、证书 SAN、重复安装、显式轮换"
)

test_dependency_resolution() (
    setup_case deps
    touch "$CASE_ROOT"/no-{jq,openssl,unzip,ca,ip,ss,netstat,wget}
    run_install --port 8443
    grep -q 'install -y --no-install-recommends jq openssl unzip ca-certificates iproute2$' "$CASE_ROOT/apt.log" ||
        fail "APT did not install exactly the missing packages"
    for name in jq openssl unzip ca ip ss; do assert_absent "$CASE_ROOT/no-$name"; done
    [[ -e "$CASE_ROOT/no-wget" ]] || fail "unneeded wget was installed"

    setup_case dnf
    OS_TYPE=rocky
    touch "$CASE_ROOT"/no-{ip,ss,systemctl}
    install_dependencies >/dev/null
    grep -q 'install -y iproute systemd$' "$CASE_ROOT/dnf.log"
    setup_case yum
    OS_TYPE=centos
    touch "$CASE_ROOT"/no-{dnf,ip,ss}
    install_dependencies >/dev/null
    grep -q 'install -y iproute$' "$CASE_ROOT/yum.log"
    setup_case apk
    OS_TYPE=alpine INIT_SYSTEM=openrc
    touch "$CASE_ROOT"/no-{ip,ss,netstat,rc-service,rc-update,flock}
    install_dependencies >/dev/null
    grep -q 'add --no-cache iproute2-minimal iproute2-ss flock openrc$' "$CASE_ROOT/apk.log"
    echo "[OK] apt/dnf/yum/apk 缺项映射、CA 证书与安装后复核"
)

test_dependency_failures() (
    local failure
    for failure in fail-update fail-install no-repair; do
        setup_case "$failure"
        touch "$CASE_ROOT/no-jq" "$CASE_ROOT/$failure"
        expect_failure main hysteria2 install
        grep -q '仍缺少' "$CASE_ROOT/error" || fail "missing remaining dependency report"
        if [[ "$failure" == fail-update ]]; then
            [[ "$(grep -c ' update$' "$CASE_ROOT/apt.log")" == 2 ]] || fail "expected two apt update attempts"
            if grep -q ' install ' "$CASE_ROOT/apt.log"; then fail "installed after update failure"; fi
        elif [[ "$failure" == fail-install ]]; then
            [[ "$(grep -c ' install ' "$CASE_ROOT/apt.log")" == 2 ]] || fail "expected two apt install attempts"
        fi
        assert_absent "$CONFIG_FILE" "$STATE_FILE" "$BIN_PATH" "$XRAY_SERVICE_FILE" "$CASE_ROOT/downloads"
    done
    echo "[OK] 软件源、包管理器、依赖复核失败均中止部署"
)

test_ports_and_multinode() (
    setup_case ports
    mkdir "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[
  {"tag":"tcp443","protocol":"socks","port":443,"settings":{"udp":false}},
  {"tag":"other-udp","protocol":"shadowsocks","port":"9000-9005","settings":{"network":"tcp,udp"}}
],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"BLOCK","protocol":"blackhole"}],
"routing":{"rules":[{"type":"field","port":"25","outboundTag":"BLOCK"},{"type":"field","domain":["domain:example.org"],"outboundTag":"direct"}]}}
JSON
    printf '%s\n' '{"other_protocol":{"port":443},"endpoint":{"custom":"existing.example"},"extra":{"a":[1,2]}}' >"$STATE_FILE"
    cp -a "$CONFIG_FILE" "$CASE_ROOT/old-config"
    cp -a "$STATE_FILE" "$CASE_ROOT/old-state"

    printf '%s' 443 >"$CASE_ROOT/occupied"
    expect_failure main hysteria2 install
    grep -q 'UDP .*443' "$CASE_ROOT/error"
    cmp -s "$CONFIG_FILE" "$CASE_ROOT/old-config"
    printf '%s' 9443 >"$CASE_ROOT/occupied"
    expect_failure main hysteria2 install --port 9443
    expect_failure main hysteria2 install --port 9002
    # The existing TCP/443 inbound can coexist with Hysteria2 UDP/443.
    run_install
    jq -e --slurpfile old "$CASE_ROOT/old-config" --arg tag "$HY2_TAG" '
      del(.inbounds[] | select(.tag == $tag)) == $old[0]
    ' "$CONFIG_FILE" >/dev/null
    jq -e --slurpfile old "$CASE_ROOT/old-state" '
      .other_protocol == $old[0].other_protocol and .endpoint == $old[0].endpoint and .extra == $old[0].extra
    ' "$STATE_FILE" >/dev/null
    printf '%s' 443 >"$CASE_ROOT/occupied"
    expect_failure main hysteria2 install
    echo "[OK] TCP/UDP 共用端口、默认与指定 UDP 冲突、原配置和状态保留"
)

test_controlled_core_upgrade() (
    setup_case old-core
    { head -n 1 "$CASE_ROOT/xray-template"; echo 'old_core=1'; tail -n +2 "$CASE_ROOT/xray-template"; } >"$BIN_PATH"
    chmod 755 "$BIN_PATH"
    cp -a "$BIN_PATH" "$CASE_ROOT/old-binary"
    mkdir -p "$ASSET_DIR"
    printf '%s\n' old-geo >"$ASSET_DIR/geoip.dat"
    printf '%s\n' old-sites >"$ASSET_DIR/geosite.dat"
    touch "$CASE_ROOT/fail-restart"
    expect_failure main hysteria2 install
    cmp -s "$BIN_PATH" "$CASE_ROOT/old-binary" || fail "old core not restored"
    [[ "$(<"$ASSET_DIR/geoip.dat")" == old-geo && "$(<"$ASSET_DIR/geosite.dat")" == old-sites ]] || fail "old assets not restored"
    assert_absent "$CONFIG_FILE" "$STATE_FILE" "$XRAY_SERVICE_FILE" "$CASE_ROOT/active" "$CASE_ROOT/enabled"
    run_install
    [[ "$(detect_xray_version)" == 26.11.9 && "$(wc -l <"$CASE_ROOT/downloads")" == 2 ]] || fail "did not upgrade unsupported core"
    echo "[OK] 旧核心能力探测、受控升级及核心和资源回滚"
)

test_faults_and_rollback() (
    setup_case rollback
    run_install
    snapshot_node
    printf '%s\n' '{"stale_backup":true}' >"$CONFIG_FILE.bak.future"
    openssl() {
        if [[ "${1:-}" == req && -e "$CASE_ROOT/fail-cert" ]]; then return 1; fi
        builtin command openssl "$@"
    }
    jq() {
        if [[ -e "$CASE_ROOT/fail-jq" && "$*" == *'def rotate_credentials:'* ]]; then return 1; fi
        builtin command jq "$@"
    }
    mv() {
        if [[ "${*: -1}" == "$LIVE_STATE_FILE" && -e "$CASE_ROOT/fail-state" ]]; then
            rm -f "$CASE_ROOT/fail-state"
            return 1
        fi
        if [[ "${*: -1}" == "$CONFIG_FILE" && "$*" == *'.restore.'* && -e "$CASE_ROOT/fail-restore" ]]; then
            return 1
        fi
        builtin command mv "$@"
    }
    touch "$CASE_ROOT/fail-cert"
    expect_failure main hysteria2 rotate-cert --yes
    assert_node_restored
    rm "$CASE_ROOT/fail-cert"
    touch "$CASE_ROOT/fail-jq"
    expect_failure main hysteria2 install --port 8443
    assert_node_restored
    rm "$CASE_ROOT/fail-jq"
    touch "$CASE_ROOT/fail-validation"
    expect_failure main hysteria2 rotate-cert --yes
    assert_node_restored
    rm "$CASE_ROOT/fail-validation"
    touch "$CASE_ROOT/fail-restart"
    expect_failure main hysteria2 rotate-cert --yes
    assert_node_restored
    touch "$CASE_ROOT/fail-state"
    expect_failure main hysteria2 rotate-cert --yes
    assert_node_restored

    touch "$CASE_ROOT/fail-state" "$CASE_ROOT/fail-restore"
    expect_failure main hysteria2 install --port 8443
    grep -q '未能恢复文件: .*config.json' "$CASE_ROOT/error" || fail "restore error omitted config.json"
    grep -q '自动恢复不完整' "$CASE_ROOT/error" || fail "missing incomplete rollback report"
    find "$TMPDIR" -type f -name 'original.*' | grep -q .
    echo "[OK] 证书、jq、校验、重启、状态写入失败及回滚失败报告"
)

test_first_state_failure() (
    setup_case first-state
    mv() {
        if [[ "${*: -1}" == "$LIVE_STATE_FILE" ]]; then return 1; fi
        builtin command mv "$@"
    }
    expect_failure main hysteria2 install
    assert_absent "$CONFIG_FILE" "$STATE_FILE" "$(hysteria2_cert_path)" "$(hysteria2_key_path)" \
        "$BIN_PATH" "$ASSET_DIR/geoip.dat" "$XRAY_SERVICE_FILE" "$CASE_ROOT/active" "$CASE_ROOT/enabled"
    [[ -s "$CASE_ROOT/restarts" ]] || fail "expected final state write failure after service start"
    echo "[OK] 首装状态提交失败清理配置、状态、证书、核心和服务"
)

test_readonly_invalid_and_lock() (
    setup_case readonly
    (
        apt-get() { fail "dry-run called apt-get"; }
        systemctl() { fail "dry-run called systemctl"; }
        openssl() { fail "fresh dry-run called openssl"; }
        main hysteria2 install --dry-run >"$CASE_ROOT/preview"
    )
    assert_absent "$CONFIG_FILE" "$STATE_FILE" "$(hysteria2_cert_path)" "$BIN_PATH" "$XRAY_SERVICE_FILE" \
        "$SHORTCUT_PATH" "$CONFIG_DIR.oneclick.lock"
    grep -q 'UDP 443' "$CASE_ROOT/preview"
    run_install
    snapshot_node
    main hysteria2 install --dry-run --port 8443 >/dev/null
    assert_node_restored

    printf '%s\n' 'invalid {' >"$CONFIG_FILE"
    cp "$CONFIG_FILE" "$CASE_ROOT/invalid"
    expect_failure main hysteria2 install
    grep -q 'JSON 对象' "$CASE_ROOT/error"
    cmp -s "$CONFIG_FILE" "$CASE_ROOT/invalid"
    cp "$CASE_ROOT/before/config.json" "$CONFIG_FILE"
    exec {test_lock}<>"$CONFIG_DIR.oneclick.lock"
    flock -n "$test_lock"
    expect_failure main hysteria2 install --port 8443
    grep -q '配置锁' "$CASE_ROOT/error"
    exec {test_lock}>&-
    assert_node_restored
    echo "[OK] dry-run、无效 JSON 和并发互斥"
)

test_menu_and_external_service() (
    setup_case menu
    with_xray_lock run_menu_choice 13 <<< $'8443\nmenu.example\n' >"$CASE_ROOT/result" 2>&1
    jq -e '.hysteria2.port == 8443 and .hysteria2.sni == "menu.example"' "$STATE_FILE" >/dev/null

    setup_case external
    touch "$CASE_ROOT/foreign-fragment" "$CASE_ROOT/active"
    expect_failure main hysteria2 install
    expect_failure main xray upgrade --restart
    assert_absent "$CONFIG_FILE" "$STATE_FILE" "$BIN_PATH" "$XRAY_SERVICE_FILE" "$CASE_ROOT/restarts" "$CASE_ROOT/downloads"
    [[ -e "$CASE_ROOT/active" ]] || fail "external service was stopped"
    echo "[OK] 菜单首次安装和外部服务保护"
)

test_fresh_and_repeat
test_dependency_resolution
test_dependency_failures
test_ports_and_multinode
test_controlled_core_upgrade
test_faults_and_rollback
test_first_state_failure
test_readonly_invalid_and_lock
test_menu_and_external_service
