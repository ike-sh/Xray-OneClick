#!/usr/bin/env bash
# System prep, preflight, ports, and shared utilities.

trusted_ca_available() {
    local bundle
    if [[ -n "${SSL_CERT_FILE:-}" ]]; then
        [[ -r "$SSL_CERT_FILE" && -s "$SSL_CERT_FILE" ]]
        return
    fi
    for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
        [[ -r "$bundle" && -s "$bundle" ]] && return 0
    done
    return 1
}

# Output each missing command (or capability) and the package that provides it.
missing_dependencies() {
    local tool network_package=iproute2 socket_package=iproute2 lock_package=util-linux
    case "$OS_TYPE" in
        alpine) network_package=iproute2-minimal; socket_package=iproute2-ss; lock_package=flock ;;
        centos | rhel | rocky | almalinux | fedora) network_package=iproute; socket_package=iproute ;;
    esac

    if [[ "${1:-}" == "lock" ]]; then
        if ! command -v flock >/dev/null 2>&1; then
            printf 'flock %s\n' "$lock_package"
        fi
        return 0
    fi
    for tool in bash jq tar openssl awk sed grep find cmp diff; do
        command -v "$tool" >/dev/null 2>&1 && continue
        case "$tool" in
            awk) printf 'awk gawk\n' ;;
            find) printf 'find findutils\n' ;;
            cmp | diff) printf '%s diffutils\n' "$tool" ;;
            *) printf '%s %s\n' "$tool" "$tool" ;;
        esac
    done
    if ! command -v unzip >/dev/null || ! unzip -v >/dev/null 2>&1; then
        printf 'unzip unzip\n'
    fi
    for tool in base64 basename cat chmod chown cp cut date df dirname head id install ln mkdir mktemp mv \
        od readlink realpath rm rmdir sha256sum sleep sort stat tail tee timeout touch tr uniq wc; do
        command -v "$tool" >/dev/null 2>&1 || printf '%s coreutils\n' "$tool"
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || printf 'curl/wget curl\n'
    trusted_ca_available || printf 'CA证书 ca-certificates\n'
    command -v ip >/dev/null 2>&1 || printf 'ip %s\n' "$network_package"
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || printf 'ss/netstat %s\n' "$socket_package"
    missing_dependencies lock
    case "$INIT_SYSTEM" in
        systemd) command -v systemctl >/dev/null 2>&1 || printf 'systemctl systemd\n' ;;
        openrc)
            for tool in rc-service rc-update; do
                command -v "$tool" >/dev/null 2>&1 || printf '%s openrc\n' "$tool"
            done
            ;;
        *) printf 'systemd/OpenRC -\n' ;;
    esac
    return 0
}

dependency_manager() {
    case "$OS_TYPE" in
        alpine) command -v apk >/dev/null && printf '%s' apk ;;
        ubuntu | debian) command -v apt-get >/dev/null && printf '%s' apt-get ;;
        centos | rhel | rocky | almalinux | fedora)
            if command -v dnf >/dev/null; then
                printf '%s' dnf
            elif command -v yum >/dev/null; then
                printf '%s' yum
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

retry_package_command() {
    local attempt rc
    for attempt in 1 2; do
        if "$@"; then
            return 0
        else
            rc=$?
        fi
        err "[系统] $1 执行失败（第 $attempt/2 次，退出码 $rc）"
    done
    return "$rc"
}

install_dependencies() {
    local profile="${1:-}" tool package manager missing
    local -a tools_needed=() packages=()

    missing="$(missing_dependencies "$profile")"
    [[ -n "$missing" ]] || return 0
    while read -r tool package; do
        tools_needed+=("$tool")
        if [[ " ${packages[*]} " != *" $package "* ]]; then
            packages+=("$package")
        fi
    done <<<"$missing"
    info "[系统] 缺少依赖: ${tools_needed[*]}"
    if ! manager="$(dependency_manager)" || [[ " ${packages[*]} " == *" - "* ]]; then
        err "[系统] 无可用的包管理器或服务管理器（$OS_TYPE / $INIT_SYSTEM）。请手动补齐: ${tools_needed[*]}"
        return 1
    fi

    info "[系统] 使用 $manager 安装: ${packages[*]}"
    local result=0
    case "$manager" in
        apk) retry_package_command apk add --no-cache "${packages[@]}" || result=$? ;;
        apt-get)
            local -a apt_options=(-o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
            local DEBIAN_FRONTEND=noninteractive
            export DEBIAN_FRONTEND
            if retry_package_command apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update; then
                retry_package_command apt-get "${apt_options[@]}" install -y --no-install-recommends "${packages[@]}" || result=$?
            else
                result=$?
            fi
            ;;
        *)
            retry_package_command "$manager" --setopt=retries=1 --setopt=timeout=20 install -y "${packages[@]}" || result=$?
            ;;
    esac
    hash -r
    if ((result == 0)) && [[ -z "${SSL_CERT_FILE:-}" && " ${packages[*]} " == *" ca-certificates "* ]] &&
        ! trusted_ca_available; then
        if command -v update-ca-certificates >/dev/null; then
            update-ca-certificates || result=$?
        elif command -v update-ca-trust >/dev/null; then
            update-ca-trust extract || result=$?
        fi
    fi
    missing="$(missing_dependencies "$profile")"
    if ((result != 0)) || [[ -n "$missing" ]]; then
        err "[系统] 依赖准备失败（$manager 退出码 $result）。请检查软件源、DNS、TLS 根证书和网络，再安装: ${packages[*]}"
        [[ -z "$missing" ]] || err "[系统] 仍缺少（工具 / 包）: $missing"
        return 1
    fi
    info "[系统] 依赖复核通过。"
}

enable_bbr() {
    [[ "$OS_TYPE" == "alpine" ]] && return 0
    command -v sysctl >/dev/null 2>&1 || return 0

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        return 0
    fi

    info "[系统] 尝试启用 BBR..."
    if ! cat >/etc/sysctl.d/99-xray-installer-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    then
        return 1
    fi
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-xray-installer-bbr.conf >/dev/null 2>&1
}

prepare_system() {
    [[ -n "${OS_TYPE:-}" ]] || check_os || return 1
    [[ -n "${XRAY_ASSET:-}" ]] || detect_arch || return 1
    info "[系统] 环境: $OS_TYPE ($INIT_SYSTEM) / 架构: $ARCH / 资产: ${XRAY_ASSET:-未知}"
    install_dependencies || return 1
    service_manager_ready || return 1
    install_shortcut || {
        err "[系统] 安装 ike 快捷命令失败。"
        return 1
    }
    if env_truthy "${XRAY_ONECLICK_ENABLE_BBR:-}"; then
        enable_bbr || info "[系统] BBR 启用失败，已继续安装 Xray。"
    fi
}

preflight_root() {
    if [[ "${XRAY_ONECLICK_TEST_EUID:-$EUID}" -eq 0 ]]; then
        diag_ok "root 权限"
        return 0
    fi
    diag_fail "非 root：请使用 root 或 sudo 运行。"
    return 1
}

preflight_os() {
    local os_file="${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}"
    local id version pretty

    if [[ ! -f "$os_file" ]]; then
        diag_fail "未找到 os-release: $os_file"
        return 1
    fi
    id="$(grep -E '^ID=' "$os_file" | head -n 1 | cut -d= -f2- | tr -d '"')"
    version="$(grep -E '^VERSION_ID=' "$os_file" | head -n 1 | cut -d= -f2- | tr -d '"')"
    pretty="$(grep -E '^PRETTY_NAME=' "$os_file" | head -n 1 | cut -d= -f2- | tr -d '"')"
    case "$id" in
        debian | ubuntu)
            diag_ok "OS: ${pretty:-$id $version}"
            ;;
        alpine)
            diag_ok "OS: ${pretty:-Alpine Linux $version}（OpenRC）"
            ;;
        *)
            diag_warn "OS: ${pretty:-${id:-unknown}}；脚本主推 Debian 12 / Ubuntu 22.04+ 或 Alpine（OpenRC），其它系统请谨慎验证。"
            ;;
    esac
}

preflight_arch() {
    local machine="${XRAY_ONECLICK_UNAME_M:-$(uname -m)}"

    case "$machine" in
        x86_64 | amd64)
            diag_ok "架构: amd64"
            ;;
        aarch64 | arm64)
            diag_ok "架构: arm64"
            ;;
        i386 | i686)
            diag_ok "架构: 386"
            ;;
        armv7l | armv7* | armv6l | armv6* | armv5l | armv5*)
            diag_ok "架构: arm32 ($machine)"
            ;;
        riscv64)
            diag_ok "架构: riscv64"
            ;;
        s390x | ppc64le | ppc64 | loongarch64 | loong64)
            # 这些架构 detect_arch 支持下载，但官方测试覆盖有限，请实测验证。
            diag_warn "架构: $machine（受支持但测试覆盖有限，请实测验证）"
            ;;
        *)
            diag_fail "不支持的架构: $machine"
            return 1
            ;;
    esac
}

preflight_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        diag_fail "systemctl 不存在，当前脚本无法管理 xray.service。"
        return 1
    fi
    if [[ ! -d "${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}" ]]; then
        diag_fail "未检测到 systemd 运行目录 ${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}，不要写入不可用 service。"
        return 1
    fi
    diag_ok "systemd 可用"
}

preflight_openrc() {
    if ! command -v rc-service >/dev/null 2>&1; then
        diag_fail "rc-service 不存在，当前脚本无法管理 OpenRC 服务。"
        return 1
    fi
    if [[ ! -d /etc/init.d ]]; then
        diag_fail "未找到 /etc/init.d，OpenRC 不可用。"
        return 1
    fi
    command -v rc-update >/dev/null 2>&1 || diag_warn "rc-update 不存在，服务可能无法设置开机自启。"
    diag_ok "OpenRC 可用"
}

preflight_init_system() {
    case "${INIT_SYSTEM:-}" in
        systemd) preflight_systemd ;;
        openrc) preflight_openrc ;;
        *)
            diag_fail "未检测到 systemd 或 OpenRC（INIT_SYSTEM=${INIT_SYSTEM:-未知}）。"
            return 1
            ;;
    esac
}

preflight_xray() {
    local installed
    if installed="$(detect_xray_version)"; then
        diag_ok "Xray $installed 可运行"
    elif [[ -e "$BIN_PATH" || -L "$BIN_PATH" ]]; then
        diag_fail "无法运行 Xray 二进制: $BIN_PATH"
        return 1
    else
        diag_info "Xray 尚未安装"
    fi
    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
        if [[ -n "$installed" && "$installed" != "未安装" ]]; then
            validate_config_file || return 1
            diag_ok "现有配置通过 Xray 校验"
        else
            validate_json_object "$CONFIG_FILE" || return 1
            diag_ok "现有配置是有效的 JSON 对象"
        fi
    else
        diag_info "尚未创建 config.json"
    fi
}

preflight_disk() {
    local free_kb human

    free_kb="${XRAY_ONECLICK_DISK_FREE_KB:-$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')}"
    if [[ -z "$free_kb" || ! "$free_kb" =~ ^[0-9]+$ ]]; then
        diag_warn "无法读取根分区可用空间"
        return 0
    fi
    human="$(awk -v kb="$free_kb" 'BEGIN{if(kb>=1048576) printf "%.1fG", kb/1048576; else printf "%.0fM", kb/1024}')"
    if ((free_kb < MIN_ROOT_FREE_KB)); then
        diag_fail "根分区可用空间不足: ${human}，建议至少 200M；可清理 apt cache 或 journal。"
        return 1
    fi
    diag_ok "根分区可用空间: ${human}"
}

preflight_network_tools() {
    local missing
    missing="$(missing_dependencies)"
    if [[ -n "$missing" ]]; then
        diag_fail "缺少必需依赖（工具 / 包）: $missing"
        return 1
    fi
    diag_ok "必需依赖可用（含 CA 证书和网络诊断）"
}

preflight_ports() {
    if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
        diag_ok "端口监听检测工具可用"
    else
        diag_warn "ss/netstat 未安装，将跳过监听检测"
    fi
}

print_preflight_summary() {
    echo -e "\n${YELLOW}系统预检${PLAIN}"
    echo "----------------------------------------"
}

preflight_system() {
    local failed="false"

    print_preflight_summary
    preflight_root || failed="true"
    preflight_os || failed="true"
    preflight_init_system || failed="true"
    preflight_arch || failed="true"
    diag_info "内核: $(uname -r)"
    preflight_disk || failed="true"
    preflight_network_tools || failed="true"
    preflight_ports || true
    if service_manager_ready; then
        diag_info "Xray 服务: $(xray_service_status)"
    else
        failed="true"
    fi
    preflight_xray || failed="true"
    [[ "$failed" != "true" ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535)) || return 1
    return 0
}

check_port() {
    local port="$1"

    if env_truthy "${IKE_TEST_MODE:-}"; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 1
    elif [[ "${PORT_CHECK_WARNING_SHOWN:-false}" != "true" ]]; then
        info "[提示] 未找到 ss/netstat，跳过系统监听端口检测，仅检查 config.json。"
        PORT_CHECK_WARNING_SHOWN="true"
    fi
    return 0
}

warn_reserved_port() {
    local port="$1"
    if ((port < 1024)); then
        info "[提示] ${port} 属于系统保留端口，请确认是否有冲突。"
    fi
    case "$port" in
        22 | 53 | 80 | 123 | 443 | 3306 | 5432 | 6379 | 8080)
            info "[提示] ${port} 是常见服务端口，请确认不会影响现有业务。"
            ;;
    esac
}

ask_port() {
    local prompt="$1"
    local default_port="$2"
    local __resultvar="$3"
    local input use_anyway

    while true; do
        read -r -p "${prompt} (默认: ${default_port}): " input || return 1
        input="${input:-$default_port}"

        if ! validate_port "$input"; then
            err "端口无效，请输入 1-65535 之间的数字。"
            continue
        fi
        input=$((10#$input))

        if ! check_port "$input"; then
            info "[提示] 端口 ${input} 当前可能已被占用。"
            read -r -p "仍然写入配置? [y/N]: " use_anyway || return 1
            [[ "$use_anyway" =~ ^[yY]$ ]] || continue
        fi

        warn_reserved_port "$input"
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

detect_global_ipv6() {
    local candidate

    if [[ ${XRAY_ONECLICK_TEST_GLOBAL_IPV6+x} ]]; then
        candidate="$XRAY_ONECLICK_TEST_GLOBAL_IPV6"
        [[ -n "$candidate" ]] || return 1
        if declare -F is_public_ipv6 >/dev/null 2>&1; then
            is_public_ipv6 "$candidate" || return 1
        fi
        printf '%s' "$candidate"
        return
    fi
    command -v ip >/dev/null 2>&1 || return 1
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if declare -F is_public_ipv6 >/dev/null 2>&1; then
            is_public_ipv6 "$candidate" || continue
        elif [[ "$candidate" != 2* && "$candidate" != 3* ]]; then
            continue
        fi
        printf '%s' "$candidate"
        return 0
    done < <(ip -o -6 addr show scope global 2>/dev/null |
        awk '$0 !~ / tentative| dadfailed| deprecated/ {
          for (i = 1; i <= NF; i++) {
            if ($i == "inet6") {
              split($(i + 1), addr, "/")
              print addr[1]
            }
          }
        }')
    return 1
}

is_system_ipv6_disabled() {
    local all_value default_value

    if [[ ${XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL+x} ]]; then
        all_value="$XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL"
    else
        all_value="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
    fi
    if [[ ${XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT+x} ]]; then
        default_value="$XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT"
    else
        default_value="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)"
    fi

    [[ "$all_value" == "1" || "$default_value" == "1" ]]
}

check_ipv6_status() {
    local ipv6_global_addr

    ipv6_global_addr="$(detect_global_ipv6 || true)"
    if [[ -n "$ipv6_global_addr" ]]; then
        if is_system_ipv6_disabled; then
            info "[IPv6] sysctl 显示 disable_ipv6=1，但检测到全局 IPv6 地址：${ipv6_global_addr}，按实际地址继续。"
        fi
        ok "[IPv6] 可用，检测到全局地址: ${ipv6_global_addr}"
        return 0
    fi

    if is_system_ipv6_disabled; then
        err "[IPv6] 系统未开启 IPv6，且未检测到全局 IPv6 地址。"
        return 1
    fi

    err "[IPv6] 未检测到全局 IPv6 地址，无法生成可用节点。"
    return 1
}

b64_no_wrap() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\n'
    fi
}

b64_url_no_pad() {
    b64_no_wrap | tr '+/' '-_' | sed 's/=*$//'
}

url_encode() {
    MSYS2_ENV_CONV_EXCL="URL_ENCODE_VALUE" URL_ENCODE_VALUE="$1" jq -rn 'env.URL_ENCODE_VALUE|@uri'
}

json_url_encode() {
    jq -crn --argjson v "$1" '$v | tojson | @uri'
}

generate_uuid() {
    local uuid

    if [[ -x "$BIN_PATH" ]]; then
        uuid="$("$BIN_PATH" uuid 2>/dev/null | tr -d '\r\n' || true)"
        if [[ -n "$uuid" ]]; then
            printf '%s' "$uuid"
            return 0
        fi
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuid="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')"
        if [[ -n "$uuid" ]]; then
            printf '%s' "$uuid"
            return 0
        fi
    fi
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        tr -d '\r\n' </proc/sys/kernel/random/uuid
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
        return 0
    fi
    return 1
}

port_used_in_config() {
    local port="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    validate_port "$port" || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --argjson port "$((10#$port))" 'any(.inbounds[]?; (.port? // empty) == $port)' "$CONFIG_FILE" >/dev/null 2>&1
}

random_free_port() {
    local min="$1"
    local max="$2"
    local span port rand attempt

    validate_port "$min" || return 1
    validate_port "$max" || return 1
    ((min <= max)) || return 1
    span=$((max - min + 1))

    for ((attempt = 0; attempt < 200; attempt++)); do
        if command -v openssl >/dev/null 2>&1; then
            local random_hex
            random_hex="$(openssl rand -hex 2 2>/dev/null || true)"
            if [[ "$random_hex" =~ ^[[:xdigit:]]{4}$ ]]; then
                rand=$((16#$random_hex))
            else
                rand=$RANDOM
            fi
        else
            rand=$RANDOM
        fi
        port=$((min + rand % span))
        if ! port_used_in_config "$port" && check_port "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done

    for ((port = min; port <= max; port++)); do
        if ! port_used_in_config "$port" && check_port "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done

    return 1
}
