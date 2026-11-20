#!/bin/sh
# POSIX entry point for fresh Linux systems, including Alpine without Bash.
set -eu

REPO="${XRAY_ONECLICK_REPO:-ike-sh/Xray-OneClick}"
REF="${XRAY_ONECLICK_REF:-main}"
uid="$(id -u)"
dry_run=0
for arg do
    [ "$arg" != "--dry-run" ] || dry_run=1
done

log() { printf '[INFO] %s\n' "$*"; }
errx() { printf '[ERR] %s\n' "$*" >&2; exit 1; }

has_downloader() { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }

has_ca() {
    if [ -n "${SSL_CERT_FILE:-}" ]; then
        [ -r "$SSL_CERT_FILE" ] && [ -s "$SSL_CERT_FILE" ]
        return
    fi
    for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
        [ -r "$bundle" ] && [ -s "$bundle" ] && return 0
    done
    return 1
}

retry_pkg() {
    for attempt in 1 2; do
        if "$@"; then return 0; else rc=$?; fi
        printf '[ERR] %s 第 %s/2 次执行失败，退出码 %s\n' "$1" "$attempt" "$rc" >&2
    done
    return "$rc"
}

bootstrap_dependencies() {
    set --
    has_downloader || set -- "$@" curl
    has_ca || set -- "$@" ca-certificates
    if [ "$uid" -eq 0 ] || [ "$dry_run" -eq 1 ]; then
        command -v bash >/dev/null 2>&1 || set -- "$@" bash
    fi
    [ "$#" -gt 0 ] || return 0
    [ "$uid" -eq 0 ] && [ "$dry_run" -eq 0 ] ||
        errx "引导缺少依赖：$*。请先手动安装。"
    log "引导安装缺失依赖：$*"
    if command -v apk >/dev/null 2>&1; then
        retry_pkg apk add --no-cache "$@" ||
            errx "apk 失败，请检查 APK 软件源及网络后安装：$*"
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        retry_pkg apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
            -o APT::Update::Error-Mode=any update &&
            retry_pkg apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
                install -y --no-install-recommends "$@" ||
            errx "apt-get 失败，请检查 APT 软件源及网络后安装：$*"
    else
        if command -v dnf >/dev/null 2>&1; then manager=dnf
        elif command -v yum >/dev/null 2>&1; then manager=yum
        else errx "没有可用的包管理器，请手动安装：$*"; fi
        retry_pkg "$manager" --setopt=retries=1 --setopt=timeout=20 install -y "$@" ||
            errx "$manager 失败，请检查软件源及网络后安装：$*"
    fi
    has_downloader && has_ca && command -v bash >/dev/null 2>&1 ||
        errx "引导依赖复核失败，请检查 bash、curl/wget 与 CA 证书。"
}

dl() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 1 --connect-timeout 10 --max-time 40 -o "$2" "$1"
    else
        wget -q -T 20 -O "$2" "$1"
    fi
}

bootstrap_dependencies
tmpdir="$(mktemp -d)" || errx "无法创建引导临时目录。"
trap 'rm -rf -- "$tmpdir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

installer="$tmpdir/install.sh"
log "下载 ${REPO} ${REF} 的 install.sh"
dl "https://raw.githubusercontent.com/${REPO}/${REF}/install.sh" "$installer" ||
    errx "下载 install.sh 失败，请检查网络或 XRAY_ONECLICK_REPO/REF。"
[ -s "$installer" ] || errx "下载到的 install.sh 为空。"
if command -v bash >/dev/null 2>&1; then
    bash -n "$installer" || errx "下载的 install.sh 语法校验失败。"
fi

if [ "$uid" -eq 0 ] || [ "$dry_run" -eq 1 ]; then
    IKE_LIB_RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}/lib"
    XRAY_ONECLICK_REPO="$REPO"
    XRAY_ONECLICK_REF="$REF"
    export IKE_LIB_RAW_BASE XRAY_ONECLICK_REPO XRAY_ONECLICK_REF
    bash "$installer" "$@"
    exit "$?"
fi

install -m 0755 "$installer" ./install.sh 2>/dev/null || { cp "$installer" ./install.sh && chmod 0755 ./install.sh; }
log "已保存 ./install.sh"
echo "请以 root 运行：XRAY_ONECLICK_REPO='$REPO' XRAY_ONECLICK_REF='$REF' bash install.sh"
