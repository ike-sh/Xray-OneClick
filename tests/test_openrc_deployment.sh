#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f /.dockerenv && -f /etc/alpine-release && ! -e /etc/xray && ! -e /etc/init.d/xray ]] || {
    echo "[FAIL] 此测试需要空白的 Alpine Docker 容器。" >&2
    exit 1
}

umask 077
WORK_DIR="$(mktemp -d)"
client_pid="" http_pid=""
cleanup() {
    local pid
    for pid in "$client_pid" "$http_pid"; do
        [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    done
    if [[ -f /etc/init.d/xray ]]; then rc-service xray stop >/dev/null 2>&1 || true; fi
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { echo "[FAIL] $*" >&2; exit 1; }

# OpenRC service commands need runlevel state even in a single-process container.
mkdir -p /run/openrc "$WORK_DIR/www"
printf 'default\n' >/run/openrc/softlevel
printf 'hysteria2-test-ok\n' >"$WORK_DIR/www/index.html"
busybox-extras httpd -f -p 127.0.0.1:443 -h "$WORK_DIR/www" &
http_pid=$!

export XRAY_BIN="$WORK_DIR/bin/xray" XRAY_ONECLICK_ENDPOINT=127.0.0.1
if command -v jq >/dev/null || command -v openssl >/dev/null; then
    fail "dependency test image already includes jq or openssl"
fi
# Serve the uncommitted installer ref from the test checkout. Xray downloads
# still use the network and the official release metadata.
TEST_REAL_WGET="$(command -v wget)"
export BOOTSTRAP_FIXTURE_ROOT="$PWD" TEST_REAL_WGET
mkdir "$WORK_DIR/downloaders"
cat >"$WORK_DIR/downloaders/wget" <<'SH'
#!/bin/sh
last=""
output=""
for arg do
    if [ "$last" = -O ]; then output="$arg"; fi
    last="$arg"
done
case "$last" in
    https://raw.githubusercontent.com/ike-sh/Xray-OneClick/deployment-test/*)
        cp "$BOOTSTRAP_FIXTURE_ROOT/${last#*deployment-test/}" "$output"
        ;;
    *) exec "$TEST_REAL_WGET" "$@" ;;
esac
SH
chmod 755 "$WORK_DIR/downloaders/wget"
if ! PATH="$WORK_DIR/downloaders:$PATH" XRAY_ONECLICK_REF=deployment-test \
    sh scripts/bootstrap.sh hysteria2 install >"$WORK_DIR/install.log" 2>&1; then
    sed -E '/链接:|密码:/d' "$WORK_DIR/install.log" >&2
    fail "OpenRC fresh Hysteria2 deployment"
fi
cmp -s install.sh /usr/local/share/ike/install.sh || fail "bootstrap did not install the selected installer ref"
cmp -s lib/57-hysteria2.sh /usr/local/share/ike/lib/57-hysteria2.sh || fail "bootstrap installed inconsistent modules"
rc-service xray status
"$XRAY_BIN" version | sed -n '1p'
for dependency in jq openssl unzip rc-service; do command -v "$dependency" >/dev/null; done
config=/etc/xray/config.json
live_state=/etc/xray/installer-state.json
cert=/etc/xray/hysteria2-cert.pem
key=/etc/xray/hysteria2-key.pem
jq -e '.hysteria2.port == 443 and (.hysteria2.certificate_sha256 | length > 0)' "$live_state" >/dev/null
openssl x509 -in "$cert" -noout -checkhost localhost >/dev/null
echo "[OK] 空白 Alpine 自动补齐依赖并安装 Stable，TCP/443 与 UDP/443 同时运行"

# Use a dedicated outbound restricted to the HTTP fixture. Xray's own
# Freedom default blocks private targets for Hysteria inbounds.
jq '
  .outbounds += [{tag:"test-http", protocol:"freedom", settings:{finalRules:[
    {action:"allow", network:"tcp", ip:["127.0.0.1/32"], port:"443"}
  ]}}] |
  .routing.rules |= ([{type:"field", inboundTag:["hysteria2-in"],
    ip:["127.0.0.1/32"], port:"443", outboundTag:"test-http"}] + .)
' "$config" >"$WORK_DIR/server.json"
mv "$WORK_DIR/server.json" "$config"
rc-service xray restart >/dev/null

jq -n --slurpfile state "$live_state" '
  $state[0].hysteria2 as $hy2 | {
    log: {loglevel: "warning"},
    inbounds: [{listen: "127.0.0.1", port: 18080, protocol: "http"}],
    outbounds: [{
      protocol: "hysteria", settings: {version: 2, address: "127.0.0.1", port: $hy2.port},
      streamSettings: {
        network: "hysteria", security: "tls",
        tlsSettings: {serverName: $hy2.sni, alpn: ["h3"], pinnedPeerCertSha256: $hy2.certificate_sha256},
        hysteriaSettings: {version: 2, auth: $hy2.auth},
        finalmask: {udp: [{type: "salamander", settings: {password: $hy2.obfs}}]}
      }
    }]
  }
' >"$WORK_DIR/client.json"
"$XRAY_BIN" run -test -c "$WORK_DIR/client.json" >/dev/null
if http_proxy=http://127.0.0.1:18080 no_proxy='' NO_PROXY='' wget -q -T 2 -O - http://127.0.0.1:443/ >/dev/null 2>&1; then
    fail "test request bypassed the proxy"
fi
"$XRAY_BIN" run -c "$WORK_DIR/client.json" >"$WORK_DIR/client.log" 2>&1 &
client_pid=$!

check_connection() {
    local try response
    for try in 1 2 3; do
        if response="$(http_proxy=http://127.0.0.1:18080 no_proxy='' NO_PROXY='' \
            wget -q -T 3 -O - http://127.0.0.1:443/ 2>/dev/null)" && [[ "$response" == "hysteria2-test-ok" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}
check_connection || fail "Hysteria2 TLS pin and Salamander connection"
echo "[OK] Hysteria2 经 TLS 证书固定校验及 Salamander 转发真实 HTTP 请求"

sha256sum "$config" "$live_state" "$cert" "$key" >"$WORK_DIR/before"
original_pid="$(cat /run/xray.pid)"
if ! ike hysteria2 install >"$WORK_DIR/repeat.log" 2>&1; then
    sed -E '/链接:|密码:/d' "$WORK_DIR/repeat.log" >&2
    fail "OpenRC Hysteria2 repeat"
fi
[[ "$(cat /run/xray.pid)" == "$original_pid" ]] || fail "repeat restarted Xray"
sha256sum -c "$WORK_DIR/before" >/dev/null || fail "repeat changed configuration or credentials"

# Inject a final state write error after the new port has been applied.
if ! (
    # shellcheck source=../install.sh
    source ./install.sh
    mv() {
        if [[ "${*: -1}" == "$live_state" && "$*" == *".new."* ]]; then return 1; fi
        command mv "$@"
    }
    if main hysteria2 install --port 8443; then fail "state write failure reported success"; fi
) >"$WORK_DIR/rollback.log" 2>&1; then
    sed -E '/链接:|密码:/d' "$WORK_DIR/rollback.log" >&2
    fail "OpenRC Hysteria2 rollback fault injection"
fi
grep -q '写入失败: .*installer-state.json' "$WORK_DIR/rollback.log" || fail "state commit was not reached"
sha256sum -c "$WORK_DIR/before" >/dev/null || fail "rollback changed original configuration or credentials"
[[ "$(cat /run/xray.pid)" != "$original_pid" ]] || fail "state rollback did not exercise service restart"
kill "$client_pid"
wait "$client_pid" || true
"$XRAY_BIN" run -c "$WORK_DIR/client.json" >"$WORK_DIR/client.log" 2>&1 &
client_pid=$!
check_connection || fail "Hysteria2 connection after real restart rollback"
echo "[OK] OpenRC 重复安装保持服务，状态写入失败后恢复原端口、证书和连接"
