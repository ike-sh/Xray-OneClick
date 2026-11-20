#!/usr/bin/env bash
# Endpoint detection and link rendering helpers.

split_endpoint_for_link() {
    local local_port="$1"
    local preferred_host="${2:-}"
    local custom endpoint host port

    custom="$(endpoint_custom_value)"
    if [[ -n "$custom" ]]; then
        if [[ "$custom" =~ ^(\[[^]]+\]):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        elif [[ "$custom" =~ ^([^:]+):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        else
            host="$custom"
            port="$local_port"
        fi
    elif [[ -n "$preferred_host" ]]; then
        host="$preferred_host"
        port="$local_port"
    elif [[ -n "${IPV4_HOST:-}" ]]; then
        host="$IPV4_HOST"
        port="$local_port"
    elif [[ -n "${IPV6_HOST:-}" ]]; then
        host="$IPV6_HOST"
        port="$local_port"
    else
        endpoint="$(endpoint_auto_value || true)"
        host="${endpoint:-YOUR_SERVER}"
        port="$local_port"
    fi

    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        host="[${host}]"
    fi
    printf '%s\t%s' "$host" "$port"
}

protocol_listen_scope() {
    local listen="${1:-}"

    case "$listen" in
        "")
            printf '%s' "unknown"
            ;;
        "0.0.0.0" | 127.*)
            printf '%s' "ipv4"
            ;;
        "::" | "[::]")
            printf '%s' "dual"
            ;;
        *:*)
            printf '%s' "ipv6"
            ;;
        *.*)
            printf '%s' "ipv4"
            ;;
        *)
            printf '%s' "unknown"
            ;;
    esac
}

config_inbound_listen_scope() {
    local tag="$1"
    local listen

    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "unknown"
        return 0
    }
    listen="$(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag == $tag).listen // empty' "$CONFIG_FILE" 2>/dev/null | head -n 1)"
    protocol_listen_scope "$listen"
}

state_listen_scope() {
    local state_key="$1"
    local scope

    [[ -n "$state_key" && -f "$STATE_FILE" ]] || return 1
    scope="$(jq -r --arg key "$state_key" '.[$key].listen_scope // empty' "$STATE_FILE" 2>/dev/null)"
    [[ -n "$scope" && "$scope" != "null" ]] || return 1
    printf '%s' "$scope"
}

inbound_supports_ipv6() {
    local tag="$1"
    local state_key="${2:-}"
    local scope

    scope="$(state_listen_scope "$state_key" 2>/dev/null || true)"
    [[ -n "$scope" ]] || scope="$(config_inbound_listen_scope "$tag")"
    [[ "$scope" == "ipv6" || "$scope" == "dual" ]]
}

should_print_ipv6_link() {
    local mode="$1"
    local tag="$2"
    local state_key="${3:-}"

    [[ "$mode" == "dual" || "$mode" == "ipv6" ]] || return 1
    [[ -n "${IPV6_HOST:-}" ]] || return 1
    inbound_supports_ipv6 "$tag" "$state_key"
}

print_ipv6_status_hint() {
    local tag="$1"
    local state_key="${2:-}"

    if [[ -z "${IPV6_HOST:-}" ]]; then
        echo "IPv6链接: 未输出（未检测到全局 IPv6 endpoint）"
    elif ! inbound_supports_ipv6 "$tag" "$state_key"; then
        echo "IPv6链接: 未输出（当前协议未监听 IPv6）"
    else
        echo "IPv6链接: 未输出（当前链接显示模式未启用 IPv6）"
    fi
}

link_endpoint_for_tag() {
    local port="$1"
    local tag="$2"
    local state_key="${3:-}"
    local mode="${CURRENT_LINK_VIEW_MODE:-dual}"

    case "$mode" in
        ipv6)
            if should_print_ipv6_link "$mode" "$tag" "$state_key"; then
                split_endpoint_for_link "$port" "$IPV6_HOST"
            else
                printf '%s\t%s' "YOUR_SERVER" "$port"
            fi
            ;;
        ipv4)
            split_endpoint_for_link "$port" "${IPV4_HOST:-}"
            ;;
        *)
            split_endpoint_for_link "$port"
            ;;
    esac
}








is_valid_ipv4() {
    local value="$1"
    local o1 o2 o3 o4 extra octet

    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 extra <<<"$value"
    [[ -z "$extra" ]] || return 1
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

is_public_ipv4() {
    local value="$1"
    local o1 o2 o3 o4

    is_valid_ipv4 "$value" || return 1
    IFS=. read -r o1 o2 o3 o4 <<<"$value"
    o1=$((10#$o1)); o2=$((10#$o2)); o3=$((10#$o3)); o4=$((10#$o4))

    ((o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224)) && return 1
    ((o1 == 100 && o2 >= 64 && o2 <= 127)) && return 1
    ((o1 == 169 && o2 == 254)) && return 1
    ((o1 == 172 && o2 >= 16 && o2 <= 31)) && return 1
    ((o1 == 192 && o2 == 168)) && return 1
    ((o1 == 192 && o2 == 0 && (o3 == 0 || o3 == 2))) && return 1
    ((o1 == 198 && (o2 == 18 || o2 == 19 || (o2 == 51 && o3 == 100)))) && return 1
    ((o1 == 203 && o2 == 0 && o3 == 113)) && return 1
    return 0
}

is_valid_ipv6() {
    local value="${1,,}"
    local remainder part compressed="false"
    local count=0
    local -a parts=()

    value="${value#[}"
    value="${value%]}"
    value="${value%%%*}"
    [[ -n "$value" && "$value" == *:* && "$value" =~ ^[0-9a-f:]+$ ]] || return 1
    [[ "$value" != *:::* ]] || return 1
    if [[ "$value" == *::* ]]; then
        compressed="true"
        remainder="${value#*::}"
        [[ "$remainder" != *::* ]] || return 1
    fi

    IFS=: read -r -a parts <<<"$value"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        ((count += 1))
    done
    if [[ "$compressed" == "true" ]]; then
        ((count < 8))
    else
        ((count == 8))
    fi
}

is_public_ipv6() {
    local value="${1,,}"
    local h1 h2 h3 h1_value h2_value h3_value

    value="${value#[}"
    value="${value%]}"
    value="${value%%%*}"
    is_valid_ipv6 "$value" || return 1
    case "$value" in
        :: | ::1 | ::ffff:* | fc* | fd* | fe8* | fe9* | fea* | feb* | fec* | fed* | fee* | fef* | ff* | 2001:db8:*) return 1 ;;
    esac
    IFS=: read -r h1 h2 h3 _ <<<"$value"
    h1_value=$((16#${h1:-0}))
    h2_value=$((16#${h2:-0}))
    h3_value=$((16#${h3:-0}))
    ((h1_value == 0x2001 && h2_value == 0x0db8)) && return 1
    ((h1_value == 0x2001 && h2_value == 0x0000)) && return 1
    ((h1_value == 0x2001 && h2_value == 0x0002 && h3_value == 0)) && return 1
    ((h1_value == 0x2001 && h2_value >= 0x0010 && h2_value <= 0x002f)) && return 1
    ((h1_value == 0x3fff && h2_value <= 0x0fff)) && return 1
    # 当前可公网路由的 IPv6 全局单播空间为 2000::/3。
    [[ "$value" == 2* || "$value" == 3* ]]
}

public_ip_sources() {
    local configured="${XRAY_ONECLICK_IP_SOURCES:-}"
    local source
    local -a sources

    if [[ -n "$configured" ]]; then
        IFS=',' read -r -a sources <<<"$configured"
        for source in "${sources[@]}"; do
            source="${source//[[:space:]]/}"
            [[ -n "$source" ]] && printf '%s\n' "$source"
        done
        return 0
    fi
    printf '%s\n' \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"
}

query_public_ip_source() {
    local version="$1"
    local source="$2"
    local curl_flag="-4"
    local response result
    local connect_timeout="${XRAY_ONECLICK_IP_CONNECT_TIMEOUT:-2}"
    local max_time="${XRAY_ONECLICK_IP_MAX_TIME:-4}"

    [[ "$version" == "4" || "$version" == "6" ]] || return 1
    [[ "$version" == "6" ]] && curl_flag="-6"
    if command -v curl >/dev/null 2>&1; then
        response="$(curl -fsS "$curl_flag" --noproxy '*' --connect-timeout "$connect_timeout" --max-time "$max_time" "$source" 2>/dev/null)" || return 1
    elif command -v wget >/dev/null 2>&1; then
        # BusyBox wget lacks -4/-6. Validate the response family below.
        response="$(timeout "$max_time" wget -Y off -q -T "$connect_timeout" -O - "$source" 2>/dev/null)" || return 1
    else
        return 1
    fi
    result="$(tr -d '\r' <<<"$response" | awk 'NF{print $1; exit}')"
    if [[ "$version" == "4" ]]; then
        is_public_ipv4 "$result" || return 1
    else
        is_public_ipv6 "$result" || return 1
    fi
    printf '%s' "$result"
}

detect_public_ip_first() {
    local version="$1"
    local source result tmpdir output pid
    local -a outputs=() pids=()

    [[ "$version" == "4" || "$version" == "6" ]] || return 1
    tmpdir="$(mktemp -d)" || return 1
    while IFS= read -r source; do
        [[ -n "$source" ]] || continue
        output="${tmpdir}/${#outputs[@]}"
        outputs+=("$output")
        (query_public_ip_source "$version" "$source" >"$output" 2>/dev/null) &
        pids+=("$!")
    done < <(public_ip_sources)

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    for output in "${outputs[@]}"; do
        result="$(head -n 1 "$output" 2>/dev/null || true)"
        [[ -n "$result" ]] || continue
        ((${#outputs[@]} == 0)) || rm -f -- "${outputs[@]}"
        rmdir "$tmpdir" 2>/dev/null || true
        printf '%s' "$result"
        return 0
    done
    ((${#outputs[@]} == 0)) || rm -f -- "${outputs[@]}"
    rmdir "$tmpdir" 2>/dev/null || true
    return 1
}

detect_public_ip() {
    local version="$1"
    local source result
    local -A seen=()

    [[ "$version" == "4" || "$version" == "6" ]] || return 1
    while IFS= read -r source; do
        [[ -n "$source" ]] || continue
        result="$(query_public_ip_source "$version" "$source" || true)"
        [[ -n "$result" && -z "${seen[$result]+x}" ]] || continue
        seen[$result]=1
        printf '%s\t%s\n' "$result" "$source"
    done < <(public_ip_sources)
}

get_public_addresses() {
    local candidate local_ipv6

    if [[ "${PUBLIC_ADDRESS_PROBED:-false}" == "true" ]]; then
        return 0
    fi
    PUBLIC_IPV4="$(detect_public_ip_first "4" || true)"
    local_ipv6="$(detect_global_ipv6 || true)"
    PUBLIC_IPV6=""
    if [[ -n "$local_ipv6" ]] && is_public_ipv6 "$local_ipv6"; then
        PUBLIC_IPV6="$(detect_public_ip_first "6" || true)"
        [[ -n "$PUBLIC_IPV6" ]] || PUBLIC_IPV6="$local_ipv6"
    fi

    if [[ -z "$PUBLIC_IPV4" ]]; then
        while IFS= read -r candidate; do
            is_public_ipv4 "$candidate" || continue
            PUBLIC_IPV4="$candidate"
            break
        done < <(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF')
    fi
    PUBLIC_ADDRESS_PROBED="true"
}

endpoint_custom_value() {
    [[ -f "$STATE_FILE" ]] || return 0
    jq -r '.endpoint.custom // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

endpoint_updated_at() {
    [[ -f "$STATE_FILE" ]] || return 0
    jq -r '.endpoint.updated_at // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

state_set_endpoint() {
    local endpoint="$1"
    local timestamp tmp

    init_state || return 1
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(state_temp_file)" || return 1
    if ! jq --arg endpoint "$endpoint" --arg timestamp "$timestamp" '
      .endpoint = {
        custom: $endpoint,
        updated_at: $timestamp
      }
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [Endpoint] 写入状态文件失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [Endpoint] 写入状态文件失败。"
        return 1
    fi
    ensure_config_security || return 1
}

state_clear_endpoint() {
    local tmp

    init_state || return 1
    tmp="$(state_temp_file)" || return 1
    if ! jq 'del(.endpoint.custom) | .endpoint.updated_at = ""' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [Endpoint] 清理状态文件失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [Endpoint] 写入状态文件失败。"
        return 1
    fi
    ensure_config_security || return 1
}

endpoint_has_explicit_port() {
    local endpoint="$1"

    [[ "$endpoint" =~ ^\[[^]]+\]:[0-9]+$ || "$endpoint" =~ ^[^:]+:[0-9]+$ ]]
}

is_valid_endpoint_hostname() {
    local host="${1:-}"
    local label
    local -a labels=()

    [[ -n "$host" && ${#host} -le 253 ]] || return 1
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        is_valid_ipv4 "$host"
        return
    fi
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"$host"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

validate_endpoint_value() {
    local endpoint="${1:-}"
    local host port

    [[ -n "$endpoint" && ! "$endpoint" =~ [[:space:]] ]] || return 1
    [[ "$endpoint" != *\"* && "$endpoint" != *\\* && "$endpoint" != */* && "$endpoint" != *'?'* && "$endpoint" != *'#'* && "$endpoint" != *'@'* && "$endpoint" != *'%'* ]] || return 1
    if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        is_valid_ipv6 "$host" && validate_port "$port"
    elif [[ "$endpoint" =~ ^\[([^]]+)\]$ ]]; then
        is_valid_ipv6 "${BASH_REMATCH[1]}"
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        is_valid_endpoint_hostname "$host" && validate_port "$port"
    elif [[ "$endpoint" == *:* ]]; then
        is_valid_ipv6 "$endpoint"
    else
        is_valid_endpoint_hostname "$endpoint"
    fi
}

endpoint_auto_value() {
    if [[ -n "${ENDPOINT_AUTO_OVERRIDE:-}" ]]; then
        printf '%s' "$ENDPOINT_AUTO_OVERRIDE"
        return 0
    fi
    get_public_addresses
    if [[ -n "${PUBLIC_IPV4:-}" ]]; then
        printf '%s' "$PUBLIC_IPV4"
        return 0
    fi
    if [[ -n "${PUBLIC_IPV6:-}" ]]; then
        printf '[%s]' "$PUBLIC_IPV6"
        return 0
    fi
    return 1
}

endpoint_detect_command() {
    local line ip source local_ipv6 found="false"

    echo -e "\n${YELLOW}[Endpoint] IPv4 探测结果${PLAIN}"
    while IFS=$'\t' read -r ip source; do
        [[ -n "$ip" ]] || continue
        found="true"
        echo "- ${ip} (${source})"
    done < <(detect_public_ip "4")
    [[ "$found" == "true" ]] || echo "- 未检测到 IPv4"

    found="false"
    echo -e "\n${YELLOW}[Endpoint] IPv6 探测结果${PLAIN}"
    local_ipv6="$(detect_global_ipv6 || true)"
    if [[ -z "$local_ipv6" ]] || ! is_public_ipv6 "$local_ipv6"; then
        echo "- 本机没有公网 IPv6，已跳过外网探测"
        return 0
    fi
    while IFS=$'\t' read -r ip source; do
        [[ -n "$ip" ]] || continue
        found="true"
        echo "- ${ip} (${source})"
    done < <(detect_public_ip "6")
    [[ "$found" == "true" ]] || echo "- 未检测到 IPv6"
}

endpoint_show_command() {
    local custom updated auto

    init_state || return 1
    custom="$(endpoint_custom_value)"
    updated="$(endpoint_updated_at)"
    if [[ -n "$custom" ]]; then
        echo "当前自定义 endpoint: $custom"
        [[ -n "$updated" ]] && echo "更新时间: $updated"
        if endpoint_has_explicit_port "$custom"; then
            echo "提示: 当前 endpoint 已包含端口，Tunnel 列表不会自动拼接本地监听端口。"
        fi
        return 0
    fi

    auto="$(endpoint_auto_value || true)"
    if [[ -n "$auto" ]]; then
        echo "当前未设置自定义 endpoint，自动检测: $auto"
    else
        echo "当前未设置自定义 endpoint，自动检测失败。"
        echo "建议运行: ike endpoint set"
    fi
}

endpoint_set_command() {
    local endpoint

    read -r -p "自定义连接地址，例如 1.2.3.4 / example.com / domain.com:外部端口: " endpoint
    endpoint="${endpoint//$'\r'/}"
    if ! validate_endpoint_value "$endpoint"; then
        err "[失败] [Endpoint] 地址格式无效，请使用 IP、域名、域名:端口 或 [IPv6]:端口。"
        return 1
    fi
    state_set_endpoint "$endpoint" || return 1
    state_set_meta_action "设置 Endpoint" || err "[状态] 最近变更记录失败。"
    ok "[完成] 自定义 endpoint 已设置: $endpoint"
}

endpoint_clear_command() {
    state_clear_endpoint || return 1
    state_set_meta_action "清除 Endpoint" || err "[状态] 最近变更记录失败。"
    ok "[完成] 自定义 endpoint 已清除。"
}

apply_env_endpoint_if_needed() {
    local endpoint="${XRAY_ONECLICK_ENDPOINT:-}"
    local tmp

    [[ -n "$endpoint" ]] || return 0
    endpoint="${endpoint//$'\r'/}"
    if ! validate_endpoint_value "$endpoint"; then
        err "[失败] [Endpoint] XRAY_ONECLICK_ENDPOINT 格式无效。"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        mkdir -p "$CONFIG_DIR" || return 1
        if [[ -s "$STATE_FILE" ]]; then
            info "[Endpoint] 缺少 jq，已保留现有 state，暂不覆盖 endpoint。"
            return 0
        fi
        tmp="$(state_temp_file)" || return 1
        if ! cat >"$tmp" <<EOF
{
  "endpoint": {
    "custom": "$endpoint",
    "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
        then
            rm -f "$tmp"
            err "[失败] [Endpoint] 写入状态文件失败。"
            return 1
        fi
        if ! mv "$tmp" "$STATE_FILE"; then
            rm -f "$tmp"
            err "[失败] [Endpoint] 提交状态文件失败。"
            return 1
        fi
        ensure_config_security || return 1
        ok "[Endpoint] 已从环境变量设置连接入口: $endpoint"
        return 0
    fi

    init_state || return 1
    if [[ -n "$(endpoint_custom_value)" ]]; then
        return 0
    fi

    state_set_endpoint "$endpoint" || return 1
    state_set_meta_action "设置 Endpoint" || err "[状态] 最近变更记录失败。"
    ok "[Endpoint] 已从环境变量设置连接入口: $endpoint"
}
