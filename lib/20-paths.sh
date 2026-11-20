#!/usr/bin/env bash
# Xray-OneClick path security, OS detection, and architecture helpers.

ensure_root() {
    [[ "${XRAY_ONECLICK_TEST_EUID:-$EUID}" -eq 0 ]] || die "错误：请使用 root 或 sudo 运行。"
}

check_os() {
    local ID=""
    if [[ -f /etc/alpine-release && -z "${XRAY_ONECLICK_OS_RELEASE:-}" ]]; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
    elif [[ -f "${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}" ]]; then
        # shellcheck disable=SC1090
        . "${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}"
        OS_TYPE="${ID:-linux}"
        case "$OS_TYPE" in
            alpine) INIT_SYSTEM="openrc" ;;
            debian | ubuntu | centos | rhel | rocky | almalinux | fedora) INIT_SYSTEM="systemd" ;;
            *) INIT_SYSTEM="unknown" ;;
        esac
    else
        die "无法识别系统类型。"
    fi
}

with_xray_lock() {
    # The lock lives next to the config directory so uninstall cannot unlink it.
    local lock_fd result previous_umask
    [[ "${XRAY_LOCK_HELD:-false}" != "true" ]] || { "$@"; return; }
    install_dependencies lock || return 1
    previous_umask="$(umask)"
    umask 077
    { exec {lock_fd}<>"${CONFIG_DIR}.oneclick.lock"; } || true
    umask "$previous_umask"
    if [[ -z "${lock_fd:-}" ]] || ! flock -n "$lock_fd"; then
        [[ -z "${lock_fd:-}" ]] || exec {lock_fd}>&-
        err "[系统] 无法取得 Xray 配置锁，可能有其他安装或更新正在运行。"
        return 1
    fi
    result=0
    (
        # Keep the lock in the caller and out of any daemon launched by the action.
        exec {lock_fd}>&-
        local XRAY_LOCK_HELD=true CONFIG_BACKUP_PATH=""
        "$@"
    ) || result=$?
    exec {lock_fd}>&-
    return "$result"
}

detect_arch() {
    # 官方 XTLS/Xray-core 的 Linux 包是 CGO_ENABLED=0 的静态 Go 二进制，
    # 在 glibc 与 musl(Alpine) 上均可直接运行，官方并不发布单独的 -musl 包。
    # 历史上这里曾错误拼接 -musl 后缀，导致 Alpine 下载不存在的 Xray-linux-64-musl.zip 而安装失败。
    ARCH="${XRAY_ONECLICK_UNAME_M:-$(uname -m)}"
    case "$ARCH" in
        x86_64 | amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
        i386 | i686) XRAY_ASSET="Xray-linux-32.zip" ;;
        aarch64 | arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7l | armv7*) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        armv6l | armv6*) XRAY_ASSET="Xray-linux-arm32-v6.zip" ;;
        armv5l | armv5*) XRAY_ASSET="Xray-linux-arm32-v5.zip" ;;
        riscv64) XRAY_ASSET="Xray-linux-riscv64.zip" ;;
        s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
        ppc64le) XRAY_ASSET="Xray-linux-ppc64le.zip" ;;
        ppc64) XRAY_ASSET="Xray-linux-ppc64.zip" ;;
        loongarch64 | loong64) XRAY_ASSET="Xray-linux-loong64.zip" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac
}

ensure_config_security() {
    if ! mkdir -p "$CONFIG_DIR" "$ASSET_DIR"; then
        err "[安全] 创建配置或资源目录失败。"
        return 1
    fi
    if ! chmod 700 "$CONFIG_DIR"; then
        err "[安全] 设置配置目录权限失败: $CONFIG_DIR"
        return 1
    fi
    if [[ -f "$CONFIG_FILE" ]] && ! chmod 600 "$CONFIG_FILE"; then
        err "[安全] 设置配置文件权限失败: $CONFIG_FILE"
        return 1
    fi
    if [[ -f "$STATE_FILE" ]] && ! chmod 600 "$STATE_FILE"; then
        err "[安全] 设置状态文件权限失败: $STATE_FILE"
        return 1
    fi
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true
}

config_temp_file() {
    if [[ "${1:-false}" == "true" ]]; then
        mktemp
    else
        mktemp "${CONFIG_FILE}.tmp.XXXXXX"
    fi
}

state_temp_file() {
    mktemp "${STATE_FILE}.tmp.XXXXXX"
}

validate_xray_binary_path() {
    local target="${1:-}" segmented

    segmented="/${target#/}/"
    if [[ -z "$target" || "$target" != /* || "$target" =~ [[:space:]] ]]; then
        err "[安全] Xray 二进制路径必须是不含空白的绝对路径: ${target:-空}"
        return 1
    fi
    case "$segmented" in
        */../* | */./*)
            err "[安全] Xray 二进制路径不能包含路径跳转: $target"
            return 1
            ;;
    esac
    if [[ "${target##*/}" != "xray" ]]; then
        err "[安全] 为防止误覆盖或误删，Xray 二进制文件名必须为 xray: $target"
        return 1
    fi
}

remove_managed_tree() {
    local target="${1:-}" segmented

    target="${target%/}"
    segmented="/${target#/}/"
    case "$segmented" in
        */../* | */./*)
            err "[安全] 拒绝删除包含路径跳转的目录: $target"
            return 1
            ;;
    esac
    case "$target" in
        "" | / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /usr/local | /var)
            err "[安全] 拒绝删除过宽目录: ${target:-空}"
            return 1
            ;;
        /*) ;;
        *)
            err "[安全] 拒绝删除非绝对目录: $target"
            return 1
            ;;
    esac
    rm -rf -- "$target"
}
