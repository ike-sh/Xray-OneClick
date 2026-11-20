#!/usr/bin/env bash
# Tunnel/forward rule management and CLI.

tunnel_connection_entry() {
    local listen_port="$1"
    local endpoint custom

    custom="$(endpoint_custom_value)"
    if [[ -n "$custom" ]]; then
        if endpoint_has_explicit_port "$custom"; then
            printf '%s%s' "$custom" "（自定义 endpoint 已含端口，请确认 NAT 映射端口）"
        else
            printf '%s:%s' "$custom" "$listen_port"
        fi
        return 0
    fi

    endpoint="$(endpoint_auto_value || true)"
    if [[ -n "$endpoint" ]]; then
        printf '%s:%s' "$endpoint" "$listen_port"
    else
        printf '%s' "请手动设置 ike endpoint set"
    fi
}

tunnel_import_auto_yes_enabled() {
    env_truthy "${XRAY_ONECLICK_YES:-}" || env_truthy "${XRAY_ONECLICK_TUNNEL_IMPORT_YES:-}"
}

get_local_addresses() {
    PUBLIC_IPV4="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./{print; exit}')"
    PUBLIC_IPV6="$(detect_global_ipv6 || true)"
}

host_candidates() {
    local mode="${1:-dual}"
    IPV4_HOST=""
    IPV6_HOST=""

    case "$mode" in
        ipv4)
            [[ -n "$PUBLIC_IPV4" ]] && IPV4_HOST="$PUBLIC_IPV4"
            ;;
        ipv6)
            [[ -n "$PUBLIC_IPV6" ]] && IPV6_HOST="[${PUBLIC_IPV6}]"
            ;;
        *)
            [[ -n "$PUBLIC_IPV4" ]] && IPV4_HOST="$PUBLIC_IPV4"
            [[ -n "$PUBLIC_IPV6" ]] && IPV6_HOST="[${PUBLIC_IPV6}]"
            ;;
    esac
}


resource_file_status() {
    if [[ -f "$1" ]]; then
        printf '%s' "存在"
    else
        printf '%s' "不存在"
    fi
}

xray_config_test_status() {
    local log_file

    [[ -x "$BIN_PATH" ]] || {
        printf '%s' "未检测到 xray"
        return 0
    }
    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "失败"
        return 0
    }

    log_file="$(mktemp)" || {
        printf '%s' "失败"
        return 0
    }
    if "$BIN_PATH" run -test -c "$CONFIG_FILE" >"$log_file" 2>&1; then
        rm -f "$log_file"
        printf '%s' "通过"
    else
        rm -f "$log_file"
        printf '%s' "失败"
    fi
}

print_apply_failure_hint() {
    local scope="${1:-proxy}"

    err "[建议] 可先执行: ike doctor ${scope}"
    err "[建议] 可再执行: ike smoke ${scope}"
    err "[建议] 查看最近日志: ike service logs"
}

print_finalmask_failure_hint() {
    err "[建议] FinalMask 属于高级兼容功能；如校验或客户端导入失败，优先重试: ike xhttp install --finalmask off"
    err "[建议] 检查当前 Xray-core 版本是否支持所用 XHTTP/FinalMask schema。"
}

print_reality_failure_hint() {
    err "[Reality] 修复建议:"
    err "  - 检查 SNI 是否为纯域名且 DOMAIN:443 可达。"
    err "  - 检查入口端口和 defender 端口是否被占用。"
    print_apply_failure_hint "reality"
}

print_xhttp_failure_hint() {
    err "[XHTTP] 修复建议:"
    err "  - 检查 path 是否以 / 开头，且不含空格、?、# 或反斜杠。"
    err "  - 检查 xray-core 版本是否支持 VLESS Encryption / XHTTP / FinalMask。"
    if [[ "${XHTTP_FINALMASK_ENABLED:-false}" == "true" ]]; then
        print_finalmask_failure_hint
    fi
    print_apply_failure_hint "xhttp"
}

random_short_suffix() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 2
    else
        printf '%04x' "$((RANDOM % 65536))"
    fi
}

port_in_csv() {
    local port="$1"
    local csv="$2"
    local item
    local -a _port_items

    IFS=',' read -ra _port_items <<<"$csv"
    for item in "${_port_items[@]}"; do
        [[ "$port" == "$item" ]] && return 0
    done
    return 1
}

is_private_target_address() {
    local target="${1,,}"
    local ip a b _unused_c _unused_d

    target="${target#[}"
    target="${target%]}"
    ip="${target%%/*}"

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r a b _unused_c _unused_d <<<"$ip"
        a=$((10#$a))
        b=$((10#$b))
        if ((a == 10 || a == 127)); then
            return 0
        fi
        if ((a == 172 && b >= 16 && b <= 31)); then
            return 0
        fi
        if ((a == 192 && b == 168)); then
            return 0
        fi
        if ((a == 169 && b == 254)); then
            return 0
        fi
        if ((a == 100 && b >= 64 && b <= 127)); then
            return 0
        fi
        return 1
    fi

    case "$ip" in
        ::1 | 0:0:0:0:0:0:0:1 | fc*:* | fd*:* | fe80:*)
            return 0
            ;;
    esac

    return 1
}

confirm_yes_no() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local answer normalized suffix

    if [[ "${default_answer,,}" == "y" || "${default_answer,,}" == "yes" ]]; then
        suffix="[Y/n]"
        default_answer="y"
    else
        suffix="[y/N]"
        default_answer="n"
    fi

    while true; do
        read -r -p "${prompt} ${suffix}: " answer
        normalized="${answer,,}"
        if [[ -z "$normalized" ]]; then
            [[ "$default_answer" == "y" ]]
            return $?
        fi
        case "$normalized" in
            y | yes) return 0 ;;
            n | no) return 1 ;;
            *) err "请输入 y/yes 或 n/no。" ;;
        esac
    done
}

confirm_dangerous_action() {
    local prompt="$1"

    confirm_yes_no "${prompt} 输入 y/yes 继续，默认取消" "n"
}

confirm_forward_warning() {
    local message="$1"

    info "[提示] $message"
    confirm_yes_no "是否继续?" "n"
}

confirm_forward_safety_warnings() {
    if [[ "${FORWARD_MODE:-safe}" == "relay" ]]; then
        confirm_forward_relay_warnings
        return $?
    fi

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS"; then
        confirm_forward_warning "目标端口属于默认安全屏蔽范围，转发可能无法工作。" || return 1
    fi

    if port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS"; then
        confirm_forward_warning "目标端口属于增强安全屏蔽范围，如果增强安全屏蔽已启用，转发可能无法工作。" || return 1
    fi

    if is_private_target_address "$FORWARD_TARGET"; then
        confirm_forward_warning "目标地址可能属于私网，当前默认安全屏蔽可能会阻断该转发。" || return 1
    fi

    return 0
}

confirm_forward_relay_warnings() {
    local risky="false"

    info "[提示] 专用中转模式会为该转发规则添加 inboundTag -> direct 放行规则，可能绕过默认安全屏蔽，仅建议用于可信固定目标。"
    confirm_dangerous_action "是否继续?" || return 1

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS" ||
        port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS" ||
        is_private_target_address "$FORWARD_TARGET"; then
        risky="true"
    fi

    if [[ "$risky" == "true" ]]; then
        info "[提示] 目标命中高风险端口或私网地址；relay 模式会为该 forward inbound 使用 direct 放行。"
        confirm_dangerous_action "请再次确认是否继续?" || return 1
    fi

    return 0
}

validate_forward_network() {
    case "$1" in
        tcp | udp | tcp,udp) return 0 ;;
        *) return 1 ;;
    esac
}

validate_forward_mode() {
    case "$1" in
        safe | relay) return 0 ;;
        *) return 1 ;;
    esac
}

is_tunnel_managed_tag() {
    case "$1" in
        "${TUNNEL_TAG_PREFIX}"* | "${LEGACY_FORWARD_TAG_PREFIX}"*) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_tunnel_type() {
    case "${1:-single}" in
        single | portMap) printf '%s' "${1:-single}" ;;
        *) printf '%s' "single" ;;
    esac
}

probe_tunnel_protocol() {
    local tmp

    [[ -x "$BIN_PATH" ]] || return 0
    tmp="$(mktemp)" || return 0
    cat >"$tmp" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "tunnel-probe",
      "listen": "127.0.0.1",
      "port": 9,
      "protocol": "tunnel",
      "settings": {
        "address": "127.0.0.1",
        "port": 9,
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" }
  ]
}
JSON

    if "$BIN_PATH" run -test -c "$tmp" >/dev/null 2>&1; then
        TUNNEL_PROTOCOL="tunnel"
    else
        TUNNEL_PROTOCOL="dokodemo-door"
    fi
    rm -f "$tmp"
}

forward_scenario_defaults() {
    local scenario="$1"

    case "$scenario" in
        map)
            FORWARD_SCENARIO_TITLE="多端口落地组（portMap / fallback 多条 single）"
            FORWARD_SCENARIO_MODE="relay"
            FORWARD_SCENARIO_NETWORK="tcp,udp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        public)
            FORWARD_SCENARIO_TITLE="普通公网转发（safe/tcp）"
            FORWARD_SCENARIO_MODE="safe"
            FORWARD_SCENARIO_NETWORK="tcp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        landing)
            FORWARD_SCENARIO_TITLE="单端口落地中转（relay/tcp,udp）"
            FORWARD_SCENARIO_MODE="relay"
            FORWARD_SCENARIO_NETWORK="tcp,udp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        lan)
            FORWARD_SCENARIO_TITLE="内网服务暴露（relay/tcp）"
            FORWARD_SCENARIO_MODE="relay"
            FORWARD_SCENARIO_NETWORK="tcp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        udp)
            FORWARD_SCENARIO_TITLE="UDP 游戏/语音转发"
            FORWARD_SCENARIO_MODE="safe"
            FORWARD_SCENARIO_NETWORK="udp"
            FORWARD_SCENARIO_LOCK_NETWORK="false"
            ;;
        custom)
            FORWARD_SCENARIO_TITLE="自定义高级转发"
            FORWARD_SCENARIO_MODE="safe"
            FORWARD_SCENARIO_NETWORK="tcp,udp"
            FORWARD_SCENARIO_LOCK_NETWORK="false"
            ;;
        *)
            err "[失败] [端口转发] 未知场景: $scenario"
            return 1
            ;;
    esac
}

forward_tag_exists() {
    local tag="$1"

    if [[ -f "$CONFIG_FILE" ]] && jq -e --arg tag "$tag" 'any(.inbounds[]?; .tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f "$STATE_FILE" ]] && jq -e --arg tag "$tag" '
      any(((.tunnels // []) + (.forwards // []))[]?; .tag == $tag)
    ' "$STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

generate_forward_tag() {
    local base first_port

    if [[ "${FORWARD_TYPE:-single}" == "portMap" ]]; then
        first_port="${FORWARD_LISTEN_PORT%%,*}"
        base="${TUNNEL_TAG_PREFIX}map-${first_port}"
    else
        base="${FORWARD_TAG_PREFIX}${FORWARD_LISTEN_PORT}-${FORWARD_TARGET_PORT}"
    fi
    FORWARD_TAG="$(generate_unique_forward_tag_from_base "$base")"
}

generate_unique_forward_tag_from_base() {
    local base="$1"
    local suffix tag

    [[ -n "$base" ]] || {
        err "[失败] [端口转发] 生成 tag 失败：base 为空。"
        return 1
    }
    tag="$base"
    while forward_tag_exists "$tag"; do
        suffix="$(random_short_suffix)"
        tag="${base}-${suffix}"
    done
    printf '%s' "$tag"
}

forward_rule_lines() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
      def managed_tag:
        ((.tag // "") | startswith($tunnel_prefix)) or
        ((.tag // "") | startswith($legacy_prefix));
      def tunnel_protocol: (.protocol == "dokodemo-door" or .protocol == "tunnel");
      .inbounds[]? |
      select(managed_tag) |
      select(tunnel_protocol) |
      [
        .tag,
        (.listen // "0.0.0.0"),
        (.port | tostring),
        (.settings.address // ""),
        (.settings.port | tostring),
        (.settings.network // "tcp"),
        (if (.settings.portMap // null) then "portMap" else "single" end)
      ] | join("\u001f")
    ' "$CONFIG_FILE" 2>/dev/null
}

forward_state_lines() {
    [[ -f "$STATE_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
      [((.tunnels // [])[]?), ((.forwards // [])[]?)] |
      unique_by(.tag)[]? |
      [
        (.tag // ""),
        (.listen // "0.0.0.0"),
        (.listen_port | tostring),
        (.target // ""),
        (.target_port | tostring),
        (.network // "tcp"),
        (.mode // "safe"),
        (.remark // ""),
        ((.enabled // true) | tostring),
        (.type // "single"),
        (.group // ""),
        ((.port_map // {}) | @json)
      ] | join("\u001f")
    ' "$STATE_FILE" 2>/dev/null
}

forward_config_has_tag() {
    local tag="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e --arg tag "$tag" '
      any(.inbounds[]?; (.tag == $tag) and (.protocol == "dokodemo-door" or .protocol == "tunnel"))
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

forward_tag_known() {
    local tag="$1"

    forward_config_has_tag "$tag" && return 0
    [[ -f "$STATE_FILE" ]] || return 1
    jq -e --arg tag "$tag" 'any(((.tunnels // []) + (.forwards // []))[]?; .tag == $tag)' "$STATE_FILE" >/dev/null 2>&1
}

forward_state_has_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 1
    jq -e --arg tag "$tag" 'any(((.tunnels // []) + (.forwards // []))[]?; .tag == $tag)' "$STATE_FILE" >/dev/null 2>&1
}

forward_state_field_for_tag() {
    local tag="$1"
    local field="$2"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" --arg field "$field" '
      ((.tunnels // []) + (.forwards // []))[]? |
      select(.tag == $tag) |
      .[$field] // empty
    ' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_relay_route_exists() {
    local tag="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e --arg tag "$tag" '
      any(.routing.rules[]?;
        (.type == "field") and
        (.outboundTag == "direct") and
        (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end))
      )
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

forward_rule_count() {
    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "0"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        printf '%s' "0"
        return 0
    }

    jq -r --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
      [ .inbounds[]? |
        select(((.tag // "") | startswith($tunnel_prefix)) or ((.tag // "") | startswith($legacy_prefix))) |
        select(.protocol == "dokodemo-door" or .protocol == "tunnel")
      ] | length
    ' "$CONFIG_FILE" 2>/dev/null
}

forward_remark_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" '((.tunnels // []) + (.forwards // []))[]? | select(.tag == $tag) | .remark // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_group_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" '((.tunnels // []) + (.forwards // []))[]? | select(.tag == $tag) | .group // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_type_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || {
        printf '%s' "single"
        return 0
    }
    jq -r --arg tag "$tag" '((.tunnels // []) + (.forwards // []))[]? | select(.tag == $tag) | .type // "single"' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_mode_for_tag() {
    local tag="$1"

    if [[ -f "$CONFIG_FILE" ]] && jq -e --arg tag "$tag" '
      any(.routing.rules[]?;
        (.type == "field") and
        (.outboundTag == "direct") and
        (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end))
      )
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        printf '%s' "relay"
    else
        printf '%s' "safe"
    fi
}

forward_all_lines() {
    local line tag listen listen_port target target_port network mode remark enabled type group port_map seen_tags
    seen_tags="|"

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r tag listen listen_port target target_port network type <<<"$line"
        [[ -n "$tag" ]] || continue
        mode="$(forward_mode_for_tag "$tag")"
        remark="$(forward_remark_for_tag "$tag")"
        group="$(forward_group_for_tag "$tag")"
        if forward_state_has_tag "$tag"; then
            type="$(forward_type_for_tag "$tag")"
        fi
        [[ -n "$type" ]] || type="single"
        printf '启用\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$mode" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network" "$remark" "$type" "$group"
        seen_tags="${seen_tags}${tag}|"
    done < <(forward_rule_lines)

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r tag listen listen_port target target_port network mode remark enabled type group port_map <<<"$line"
        [[ -n "$tag" ]] || continue
        [[ "$seen_tags" == *"|${tag}|"* ]] && continue
        printf '停用\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "${mode:-safe}" "$tag" "$listen" "$listen_port" "$target" "$target_port" "${network:-tcp}" "$remark" "${type:-single}" "$group"
    done < <(forward_state_lines)
}

load_forward_vars_from_tag() {
    local tag="$1"
    local line

    if forward_state_has_tag "$tag"; then
        line="$(jq -r --arg tag "$tag" '
          ((.tunnels // []) + (.forwards // []))[]? |
          select(.tag == $tag) |
          [
            .tag,
            (.listen // "0.0.0.0"),
            (.listen_port | tostring),
            (.target // ""),
            (.target_port | tostring),
            (.network // "tcp"),
            (.mode // "safe"),
            (.remark // ""),
            ((.enabled // false) | tostring),
            (.type // "single"),
            (.group // ""),
            ((.port_map // {}) | @json)
          ] | join("\u001f")
        ' "$STATE_FILE" 2>/dev/null | head -n 1)"
        [[ -n "$line" ]] || return 1
        IFS=$'\037' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED FORWARD_TYPE FORWARD_GROUP FORWARD_PORT_MAP_JSON <<<"$line"
        if forward_config_has_tag "$FORWARD_TAG"; then
            FORWARD_ENABLED="true"
        fi
        FORWARD_TYPE="$(normalize_tunnel_type "$FORWARD_TYPE")"
        [[ -n "${FORWARD_PORT_MAP_JSON:-}" ]] || FORWARD_PORT_MAP_JSON="{}"
        return 0
    fi

    if forward_config_has_tag "$tag"; then
        line="$(jq -r --arg tag "$tag" '
          .inbounds[]? |
          select((.tag == $tag) and (.protocol == "dokodemo-door" or .protocol == "tunnel")) |
          [
            .tag,
            (.listen // "0.0.0.0"),
            (.port | tostring),
            (.settings.address // ""),
            (.settings.port | tostring),
            (.settings.network // "tcp"),
            (if (.settings.portMap // null) then "portMap" else "single" end),
            ((.settings.portMap // {}) | @json)
          ] | join("\u001f")
        ' "$CONFIG_FILE" 2>/dev/null | head -n 1)"
        [[ -n "$line" ]] || return 1
        IFS=$'\037' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_TYPE FORWARD_PORT_MAP_JSON <<<"$line"
        FORWARD_MODE="$(forward_mode_for_tag "$FORWARD_TAG")"
        FORWARD_REMARK=""
        FORWARD_GROUP=""
        FORWARD_ENABLED="true"
        FORWARD_TYPE="$(normalize_tunnel_type "$FORWARD_TYPE")"
        [[ -n "${FORWARD_PORT_MAP_JSON:-}" ]] || FORWARD_PORT_MAP_JSON="{}"
        return 0
    fi

    return 1
}

select_forward_tag() {
    local filter="${1:-all}"
    local direct_tag="${2:-}"
    local line status mode tag listen listen_port target target_port network remark type group
    local records=()
    local tags=()
    local idx selected

    if [[ -n "$direct_tag" ]]; then
        if forward_tag_known "$direct_tag"; then
            SELECTED_FORWARD_TAG="$direct_tag"
            return 0
        fi
        err "[失败] 未找到转发规则: $direct_tag"
        return 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        case "$filter" in
            enabled) [[ "$status" == "启用" ]] || continue ;;
            disabled) [[ "$status" == "停用" ]] || continue ;;
        esac
        records+=("$line")
        tags+=("$tag")
    done < <(forward_all_lines)

    if [[ ${#records[@]} -eq 0 ]]; then
        err "[失败] 没有可选择的转发规则。"
        return 1
    fi

    echo -e "\n${YELLOW}[端口转发] 选择规则${PLAIN}"
    idx=1
    for line in "${records[@]}"; do
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        group="${group:-未分组}"
        if [[ -n "$remark" ]]; then
            echo " ${idx}) ${status} ${mode} ${type:-single} ${group} ${tag}: ${listen}:${listen_port} -> ${target}:${target_port}/${network} ${remark}"
        else
            echo " ${idx}) ${status} ${mode} ${type:-single} ${group} ${tag}: ${listen}:${listen_port} -> ${target}:${target_port}/${network}"
        fi
        ((idx++))
    done

    read -r -p "请选择规则编号: " selected
    if ! [[ "$selected" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#tags[@]})); then
        err "[失败] [端口转发] 无效编号。"
        return 1
    fi

    SELECTED_FORWARD_TAG="${tags[$((selected - 1))]}"
}

list_forward_rules() {
    local line status tag listen listen_port target target_port network mode remark type group
    local rules=()

    if ! command -v jq >/dev/null 2>&1; then
        err "[失败] [端口转发] 缺少 jq，无法读取配置。"
        return 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        info "[端口转发] 未找到配置文件，请先安装 Xray 或协议。"
        return 0
    fi

    if [[ -z "$(endpoint_custom_value)" ]]; then
        get_public_addresses
    fi

    mapfile -t rules < <(forward_all_lines)
    if [[ ${#rules[@]} -eq 0 ]]; then
        info "[端口转发] 当前未配置转发规则。"
        return 0
    fi

    echo -e "\n${YELLOW}--- Tunnel 中转 ---${PLAIN}"
    printf '%-6s %-6s %-8s %-14s %s\n' "状态" "模式" "类型" "分组" "规则"
    for line in "${rules[@]}"; do
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        group="${group:-未分组}"
        if [[ -n "$remark" ]]; then
            printf '%-6s %-6s %-8s %-14s %s: %s:%s -> %s:%s/%s %s\n' "$status" "$mode" "${type:-single}" "$group" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network" "$remark"
        else
            printf '%-6s %-6s %-8s %-14s %s: %s:%s -> %s:%s/%s\n' "$status" "$mode" "${type:-single}" "$group" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network"
        fi
        printf '       连接入口: %s\n' "$(tunnel_connection_entry "$listen_port")"
    done
}

state_sync_forward_rule() {
    local tmp port_map_json replaced_tag

    init_state || return 1
    replaced_tag="${1:-${FORWARD_TAG}}"
    port_map_json="${FORWARD_PORT_MAP_JSON:-}"
    [[ -n "$port_map_json" ]] || port_map_json="{}"
    tmp="$(state_temp_file)" || {
        err "[失败] [端口转发] 创建状态临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$FORWARD_TAG" \
        --arg replaced_tag "$replaced_tag" \
        --arg listen "$FORWARD_LISTEN" \
        --arg listen_port "$FORWARD_LISTEN_PORT" \
        --arg target "$FORWARD_TARGET" \
        --arg target_port "$FORWARD_TARGET_PORT" \
        --arg network "$FORWARD_NETWORK" \
        --arg mode "$FORWARD_MODE" \
        --arg enabled "${FORWARD_ENABLED:-true}" \
        --arg remark "$FORWARD_REMARK" \
        --arg type "$(normalize_tunnel_type "${FORWARD_TYPE:-single}")" \
        --arg group "${FORWARD_GROUP:-}" \
        --argjson port_map "$port_map_json" '
        def tunnel_record:
        {
          "tag": $tag,
          "type": $type,
          "group": $group,
          "listen": $listen,
          "listen_port": (if $type == "portMap" then $listen_port else ($listen_port | tonumber) end),
          "target": $target,
          "target_port": ($target_port | tonumber),
          "network": $network,
          "mode": $mode,
          "enabled": ($enabled == "true"),
          "remark": $remark
        } + (if $type == "portMap" then {"port_map": $port_map} else {} end);
        .tunnels = ((.tunnels // []) | map(select(.tag != $tag and .tag != $replaced_tag))) |
        .tunnels += [tunnel_record] |
        .forwards = ((.forwards // []) | map(select(.tag != $tag and .tag != $replaced_tag))) |
        .forwards += [tunnel_record]
      ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入状态文件失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security || return 1
}

state_delete_forward_rule() {
    local tag="$1"
    local tmp

    [[ -f "$STATE_FILE" ]] || return 0
    tmp="$(state_temp_file)" || {
        err "[失败] [端口转发] 创建状态临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$tag" '
        .tunnels = ((.tunnels // []) | map(select(.tag != $tag))) |
        .forwards = ((.forwards // []) | map(select(.tag != $tag)))
      ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 删除状态记录失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security || return 1
}

configure_forward_rule() {
    local input default_network lock_network scenario_title

    FORWARD_MODE="${1:-${FORWARD_MODE:-safe}}"
    FORWARD_TYPE="single"
    FORWARD_PORT_MAP_JSON="{}"
    default_network="${2:-tcp}"
    lock_network="${3:-false}"
    scenario_title="${4:-}"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 未知转发模式: $FORWARD_MODE"
        return 1
    }

    if [[ -n "$scenario_title" ]]; then
        echo -e "\n${YELLOW}[Tunnel 中转] ${scenario_title}${PLAIN}"
    else
        echo -e "\n${YELLOW}[Tunnel 中转] 添加单端口 Tunnel (${FORWARD_MODE})${PLAIN}"
    fi
    read -r -p "本机监听地址 (默认: 0.0.0.0): " FORWARD_LISTEN
    FORWARD_LISTEN="${FORWARD_LISTEN:-0.0.0.0}"
    if [[ "$FORWARD_LISTEN" =~ [[:space:]] || -z "$FORWARD_LISTEN" ]]; then
        err "[失败] [端口转发] 本机监听地址无效。"
        return 1
    fi

    ask_port "本机监听端口" "30000" FORWARD_LISTEN_PORT || return 1

    read -r -p "目标地址，例如 1.2.3.4 或 example.com: " FORWARD_TARGET
    if [[ -z "$FORWARD_TARGET" || "$FORWARD_TARGET" =~ [[:space:]] ]]; then
        err "[失败] [端口转发] 目标地址无效。"
        return 1
    fi

    while true; do
        read -r -p "目标端口: " FORWARD_TARGET_PORT
        if validate_port "$FORWARD_TARGET_PORT"; then
            break
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done

    if [[ "$lock_network" == "true" ]]; then
        FORWARD_NETWORK="$default_network"
        info "[端口转发] 网络类型: ${FORWARD_NETWORK}"
    else
        read -r -p "网络类型 tcp / udp / tcp,udp (默认: ${default_network}): " input
        FORWARD_NETWORK="${input:-$default_network}"
    fi
    if ! validate_forward_network "$FORWARD_NETWORK"; then
        err "[失败] [端口转发] 网络类型无效，仅支持 tcp、udp、tcp,udp。"
        return 1
    fi

    read -r -p "分组名称，可选: " FORWARD_GROUP
    read -r -p "备注名称，可选: " FORWARD_REMARK
    confirm_forward_safety_warnings || {
        err "[取消] 已取消添加端口转发。"
        return 1
    }
}

configure_forward_scenario() {
    local scenario="$1"
    local input

    forward_scenario_defaults "$scenario" || return 1
    if [[ "$scenario" == "custom" ]]; then
        echo -e "\n${YELLOW}[中转/端口转发] ${FORWARD_SCENARIO_TITLE}${PLAIN}"
        echo " 1) safe：遵守全局安全规则"
        echo " 2) relay：为该 forward inbound 添加 direct 放行"
        read -r -p "模式 (默认: 1): " input
        case "${input:-1}" in
            1) FORWARD_SCENARIO_MODE="safe" ;;
            2) FORWARD_SCENARIO_MODE="relay" ;;
            *)
                err "[失败] 无效模式。"
                return 1
                ;;
        esac
    elif [[ "$scenario" == "udp" ]]; then
        echo -e "\n${YELLOW}[中转/端口转发] ${FORWARD_SCENARIO_TITLE}${PLAIN}"
        echo " 1) safe：普通 UDP 转发，遵守全局安全规则"
        echo " 2) relay：专用 UDP 中转，仅用于可信固定目标"
        read -r -p "模式 (默认: 1): " input
        case "${input:-1}" in
            1) FORWARD_SCENARIO_MODE="safe" ;;
            2) FORWARD_SCENARIO_MODE="relay" ;;
            *)
                err "[失败] 无效模式。"
                return 1
                ;;
        esac
        read -r -p "网络类型 udp / tcp,udp (默认: udp): " input
        case "${input:-udp}" in
            udp | tcp,udp) FORWARD_SCENARIO_NETWORK="${input:-udp}" ;;
            *)
                err "[失败] 网络类型无效，仅支持 udp 或 tcp,udp。"
                return 1
                ;;
        esac
    fi
    if [[ "$scenario" == "custom" ]]; then
        info "[Tunnel] 自定义模式默认网络类型为 tcp,udp；如只需要 TCP，可在下一步输入 tcp。"
    fi

    configure_forward_rule \
        "$FORWARD_SCENARIO_MODE" \
        "$FORWARD_SCENARIO_NETWORK" \
        "$FORWARD_SCENARIO_LOCK_NETWORK" \
        "$FORWARD_SCENARIO_TITLE"
}

remove_forward_config_by_tag() {
    local tag="$1"
    local tmp

    [[ -f "$CONFIG_FILE" ]] || return 0

    tmp="$(config_temp_file)" || {
        err "[失败] [端口转发] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$tag" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
        def managed_tag:
          ((. // "") | startswith($tunnel_prefix)) or
          ((. // "") | startswith($legacy_prefix));
        def selected_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end));
        .inbounds = ((.inbounds // []) | map(select((.tag != $tag) or (((.tag // "") | managed_tag) | not)))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((selected_relay_rule) | not)))
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
}

write_forward_config_from_vars() {
    local tmp port_map_json

    FORWARD_ENABLED="${FORWARD_ENABLED:-true}"
    port_map_json="${FORWARD_PORT_MAP_JSON:-}"
    [[ -n "$port_map_json" ]] || port_map_json="{}"
    tmp="$(config_temp_file)" || {
        err "[失败] [端口转发] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$FORWARD_TAG" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" \
        --arg protocol "$TUNNEL_PROTOCOL" \
        --arg listen "$FORWARD_LISTEN" \
        --arg listen_port "$FORWARD_LISTEN_PORT" \
        --arg target "$FORWARD_TARGET" \
        --arg target_port "$FORWARD_TARGET_PORT" \
        --arg network "$FORWARD_NETWORK" \
        --arg mode "$FORWARD_MODE" \
        --arg enabled "$FORWARD_ENABLED" \
        --arg type "$(normalize_tunnel_type "${FORWARD_TYPE:-single}")" \
        --argjson port_map "$port_map_json" '
        def managed_tag:
          ((. // "") | startswith($tunnel_prefix)) or
          ((. // "") | startswith($legacy_prefix));
        def port_value($p):
          if ($p | test(",")) then $p else ($p | tonumber) end;
        def relay_rule:
          {"type": "field", "inboundTag": [$tag], "outboundTag": "direct"};
        def selected_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end));
        def forward_inbound:
          if $type == "portMap" then
            {
              "tag": $tag,
              "listen": $listen,
              "port": port_value($listen_port),
              "protocol": $protocol,
              "settings": {
                "address": $target,
                "port": ($target_port | tonumber),
                "portMap": $port_map,
                "network": $network
              }
            }
          else
            {
              "tag": $tag,
              "listen": $listen,
              "port": ($listen_port | tonumber),
              "protocol": $protocol,
              "settings": {
                "address": $target,
                "port": ($target_port | tonumber),
                "network": $network
              }
            }
          end;
        .inbounds = ((.inbounds // []) | map(select((.tag != $tag) or (((.tag // "") | managed_tag) | not)))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((selected_relay_rule) | not))) |
        if $enabled == "true" then
          .inbounds += [forward_inbound] |
          if $mode == "relay" then
            .routing.rules = ([relay_rule] + ((.routing.rules // []) | map(select(. != relay_rule))))
          else
            .
          end
        else
          .
        end
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
}

install_forward_rule() {
    FORWARD_MODE="${FORWARD_MODE:-safe}"
    FORWARD_ENABLED="true"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 未知转发模式: $FORWARD_MODE"
        return 1
    }

    install_or_update_xray || {
        err "[失败] [端口转发] Xray 安装/更新失败。"
        return 1
    }
    probe_tunnel_protocol
    generate_forward_tag
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    write_forward_config_from_vars || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 应用配置失败。"
        return 1
    fi

    if ! state_sync_forward_rule; then
        rollback_config_after_state_failure "端口转发"
        return 1
    fi
    state_set_meta_action "添加端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已添加: ${FORWARD_TAG}"
}

delete_forward_rule() {
    local selected_tag="${1:-}"

    select_forward_tag "all" "$selected_tag" || return 1
    selected_tag="$SELECTED_FORWARD_TAG"

    if ! forward_config_has_tag "$selected_tag"; then
        state_delete_forward_rule "$selected_tag" || return 1
        state_set_meta_action "删除端口转发" || err "[状态] 最近变更记录失败。"
        ok "[完成] 已删除停用转发规则: ${selected_tag}"
        return 0
    fi

    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    remove_forward_config_by_tag "$selected_tag" || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 应用删除失败。"
        return 1
    fi

    if ! state_delete_forward_rule "$selected_tag"; then
        rollback_config_after_state_failure "端口转发删除"
        return 1
    fi
    state_set_meta_action "删除端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已删除: ${selected_tag}"
}

set_forward_enabled() {
    local enable="$1"
    local selected_tag="${2:-}"
    local filter action context

    if [[ "$enable" == "true" ]]; then
        filter="disabled"
        action="启用"
    else
        filter="enabled"
        action="停用"
    fi

    select_forward_tag "$filter" "$selected_tag" || return 1
    selected_tag="$SELECTED_FORWARD_TAG"
    load_forward_vars_from_tag "$selected_tag" || {
        err "[失败] [端口转发] 无法读取规则: $selected_tag"
        return 1
    }

    if [[ "$enable" == "true" && "$FORWARD_ENABLED" == "true" ]] && forward_config_has_tag "$FORWARD_TAG"; then
        info "[端口转发] 规则已启用: $FORWARD_TAG"
        return 0
    fi
    if [[ "$enable" == "false" ]] && ! forward_config_has_tag "$FORWARD_TAG"; then
        FORWARD_ENABLED="false"
        state_sync_forward_rule || return 1
        info "[端口转发] 规则已停用: $FORWARD_TAG"
        return 0
    fi

    if [[ "$enable" == "true" ]]; then
        install_or_update_xray || return 1
        probe_tunnel_protocol
    fi

    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    FORWARD_ENABLED="$enable"
    if [[ "$enable" == "true" ]]; then
        write_forward_config_from_vars || return 1
    else
        remove_forward_config_by_tag "$FORWARD_TAG" || return 1
    fi

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] ${action}失败。"
        return 1
    fi

    if ! state_sync_forward_rule; then
        rollback_config_after_state_failure "${action}端口转发"
        return 1
    fi
    context="${action}端口转发"
    state_set_meta_action "$context" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${context}: ${FORWARD_TAG}"
}

prompt_forward_port_value() {
    local label="$1"
    local current="$2"
    local __resultvar="$3"
    local input

    while true; do
        read -r -p "${label} (当前: ${current}): " input
        input="${input:-$current}"
        if validate_port "$input"; then
            printf -v "$__resultvar" '%s' "$input"
            return 0
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done
}

edit_forward_rule() {
    local selected_tag="${1:-}"
    local old_tag old_listen_port old_target_port input regen_tag

    select_forward_tag "all" "$selected_tag" || return 1
    load_forward_vars_from_tag "$SELECTED_FORWARD_TAG" || {
        err "[失败] [端口转发] 无法读取规则: $SELECTED_FORWARD_TAG"
        return 1
    }
    if [[ "${FORWARD_TYPE:-single}" == "portMap" ]]; then
        err "[失败] portMap 规则暂不支持逐项 edit，请导出后修改 JSON 再导入，或删除后重新添加。"
        return 1
    fi

    old_tag="$FORWARD_TAG"
    old_listen_port="$FORWARD_LISTEN_PORT"
    old_target_port="$FORWARD_TARGET_PORT"

    echo -e "\n${YELLOW}[端口转发] 修改规则: ${old_tag}${PLAIN}"
    read -r -p "本机监听地址 (当前: ${FORWARD_LISTEN}): " input
    [[ -n "$input" ]] && FORWARD_LISTEN="$input"
    [[ -z "$FORWARD_LISTEN" || "$FORWARD_LISTEN" =~ [[:space:]] ]] && {
        err "[失败] [端口转发] 本机监听地址无效。"
        return 1
    }

    prompt_forward_port_value "本机监听端口" "$FORWARD_LISTEN_PORT" FORWARD_LISTEN_PORT || return 1

    read -r -p "目标地址 (当前: ${FORWARD_TARGET}): " input
    [[ -n "$input" ]] && FORWARD_TARGET="$input"
    [[ -z "$FORWARD_TARGET" || "$FORWARD_TARGET" =~ [[:space:]] ]] && {
        err "[失败] [端口转发] 目标地址无效。"
        return 1
    }

    prompt_forward_port_value "目标端口" "$FORWARD_TARGET_PORT" FORWARD_TARGET_PORT || return 1

    read -r -p "网络类型 tcp / udp / tcp,udp (当前: ${FORWARD_NETWORK}): " input
    [[ -n "$input" ]] && FORWARD_NETWORK="$input"
    validate_forward_network "$FORWARD_NETWORK" || {
        err "[失败] [端口转发] 网络类型无效。"
        return 1
    }

    read -r -p "模式 safe / relay (当前: ${FORWARD_MODE}): " input
    [[ -n "$input" ]] && FORWARD_MODE="$input"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 模式无效。"
        return 1
    }

    read -r -p "分组名称 (当前: ${FORWARD_GROUP:-无}): " input
    [[ -n "$input" ]] && FORWARD_GROUP="$input"

    read -r -p "备注名称 (当前: ${FORWARD_REMARK:-无}): " input
    [[ -n "$input" ]] && FORWARD_REMARK="$input"

    confirm_forward_safety_warnings || {
        err "[取消] 已取消修改端口转发。"
        return 1
    }

    if [[ "$FORWARD_LISTEN_PORT" != "$old_listen_port" || "$FORWARD_TARGET_PORT" != "$old_target_port" ]]; then
        read -r -p "监听端口或目标端口已改变，是否重新生成 tag? [y/N]: " regen_tag
        if [[ "$regen_tag" =~ ^[yY]$ ]]; then
            generate_forward_tag
        else
            FORWARD_TAG="$old_tag"
        fi
    fi

    FORWARD_ENABLED="true"
    install_or_update_xray || return 1
    probe_tunnel_protocol
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    remove_forward_config_by_tag "$old_tag" || return 1
    write_forward_config_from_vars || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 修改失败。"
        return 1
    fi

    if ! state_sync_forward_rule "$old_tag"; then
        rollback_config_after_state_failure "修改端口转发"
        return 1
    fi
    state_set_meta_action "修改端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已修改: ${FORWARD_TAG}"
}

forward_target_is_ip_literal() {
    local target="$1"

    [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$target" == *:* ]]
}

forward_security_impact_summary() {
    local impacts=()
    local cn_status

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS"; then
        impacts+=("可能被默认端口屏蔽")
    fi
    if port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS"; then
        impacts+=("可能被增强端口屏蔽")
    fi
    if is_private_target_address "$FORWARD_TARGET"; then
        impacts+=("可能被私网屏蔽")
    fi

    cn_status="$(china_direct_block_status)"
    if [[ "$cn_status" != "未启用" ]]; then
        impacts+=("CN block ${cn_status} 可能影响中国大陆目标")
    fi

    if [[ ${#impacts[@]} -eq 0 ]]; then
        printf '%s' "未发现明显命中项"
    else
        local IFS='；'
        printf '%s' "${impacts[*]}"
    fi
}

forward_local_listen_status() {
    if ! forward_config_has_tag "$FORWARD_TAG"; then
        printf '%s' "失败（规则未启用）"
        return 0
    fi
    if ! command -v ss >/dev/null 2>&1; then
        printf '%s' "未检测（缺少 ss，无法检查本地监听）"
        return 0
    fi
    if ss -tulpn 2>/dev/null | grep -E "[:.]${FORWARD_LISTEN_PORT}[[:space:]]" | grep -q xray; then
        printf '%s' "OK"
    else
        printf '%s' "失败（未看到 xray 监听该端口）"
    fi
}

forward_tcp_connect_status() {
    local nc_bin

    if [[ "$FORWARD_NETWORK" != *tcp* ]]; then
        printf '%s' "跳过（非 TCP 规则）"
        return 0
    fi

    nc_bin="$(command -v nc || true)"
    if [[ -z "$nc_bin" ]]; then
        printf '%s' "跳过（未检测到 nc，请安装 netcat-openbsd）"
        return 0
    fi

    if nc -z -w3 "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" >/dev/null 2>&1; then
        printf '%s' "OK"
    else
        printf '%s' "失败"
    fi
}

forward_relay_route_status() {
    if [[ "$FORWARD_MODE" != "relay" ]]; then
        printf '%s' "不适用"
        return 0
    fi

    if forward_relay_route_exists "$FORWARD_TAG"; then
        printf '%s' "存在"
    else
        printf '%s' "缺失"
    fi
}

forward_state_config_summary() {
    if forward_config_has_tag "$FORWARD_TAG" && forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "config/state 同步"
    elif forward_config_has_tag "$FORWARD_TAG"; then
        printf '%s' "state 缺失，可从 config 解析"
    elif forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "state 存在但 config inbound 不存在"
    else
        printf '%s' "config/state 均缺失"
    fi
}

forward_effective_status() {
    if forward_config_has_tag "$FORWARD_TAG" && forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "启用"
    elif forward_config_has_tag "$FORWARD_TAG"; then
        printf '%s' "config-only"
    elif forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "state-only"
    else
        printf '%s' "异常"
    fi
}

print_forward_resolution() {
    if forward_target_is_ip_literal "$FORWARD_TARGET"; then
        echo "目标解析: 跳过（目标是 IP 地址）"
        return 0
    fi

    if ! command -v getent >/dev/null 2>&1; then
        echo "目标解析: 跳过（缺少 getent）"
        return 0
    fi

    echo "目标解析:"
    if ! getent ahosts "$FORWARD_TARGET" | awk '{print "  " $1 " " $2}' | sort -u | head -n 8; then
        echo "  未获得 A/AAAA 结果"
    fi
}

diagnose_forward_rule() {
    local tag="$1"
    local status

    load_forward_vars_from_tag "$tag" || {
        err "[失败] [端口转发] 无法读取规则: $tag"
        return 1
    }

    status="$(forward_effective_status)"

    echo -e "\n${YELLOW}--- Tunnel 诊断 ---${PLAIN}"
    echo "规则: ${FORWARD_TAG}"
    echo "状态: ${status}"
    echo "模式: ${FORWARD_MODE}"
    echo "类型: ${FORWARD_TYPE:-single}"
    echo "分组: ${FORWARD_GROUP:-未分组}"
    echo "监听: ${FORWARD_LISTEN}:${FORWARD_LISTEN_PORT}"
    echo "连接入口: $(tunnel_connection_entry "$FORWARD_LISTEN_PORT")"
    echo "目标: ${FORWARD_TARGET}:${FORWARD_TARGET_PORT}/${FORWARD_NETWORK}"
    [[ -n "$FORWARD_REMARK" ]] && echo "备注: ${FORWARD_REMARK}"
    echo "状态摘要: $(forward_state_config_summary)"
    echo "本地监听: $(forward_local_listen_status)"
    print_forward_resolution
    echo "TCP连通: $(forward_tcp_connect_status)"
    if [[ "$FORWARD_NETWORK" == *udp* ]]; then
        echo "UDP说明: UDP 无法通过简单握手可靠判断"
    else
        echo "UDP说明: 不适用"
    fi
    echo "relay路由: $(forward_relay_route_status)"
    if [[ "$FORWARD_MODE" == "safe" ]]; then
        echo "安全规则影响: $(forward_security_impact_summary)；safe 模式会遵守全局安全规则"
    else
        echo "安全规则影响: $(forward_security_impact_summary)"
    fi
}

test_forward_rule() {
    local selected_tag="${1:-}"

    select_forward_tag "all" "$selected_tag" || return 1
    diagnose_forward_rule "$SELECTED_FORWARD_TAG"
}

doctor_forward_rules() {
    local selected_tag="${1:-}"
    local line status mode tag listen listen_port target target_port network remark
    local rules=()

    if [[ -n "$selected_tag" ]]; then
        forward_tag_known "$selected_tag" || {
            err "[失败] 未找到转发规则: $selected_tag"
            return 1
        }
        diagnose_forward_rule "$selected_tag"
        return $?
    fi

    mapfile -t rules < <(forward_all_lines)
    if [[ ${#rules[@]} -eq 0 ]]; then
        info "[端口转发] 当前没有可诊断的转发规则。"
        return 0
    fi

    for line in "${rules[@]}"; do
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark _type _group <<<"$line"
        diagnose_forward_rule "$tag" || return 1
    done
}

list_tunnel_groups() {
    local line status mode tag listen listen_port target target_port network remark type group key
    local -A totals enabled disabled
    local groups=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        key="${group:-未分组}"
        if [[ -z "${totals[$key]+x}" ]]; then
            groups+=("$key")
            totals[$key]=0
            enabled[$key]=0
            disabled[$key]=0
        fi
        totals[$key]=$((totals[$key] + 1))
        if [[ "$status" == "启用" ]]; then
            enabled[$key]=$((enabled[$key] + 1))
        else
            disabled[$key]=$((disabled[$key] + 1))
        fi
    done < <(forward_all_lines)

    if [[ ${#groups[@]} -eq 0 ]]; then
        info "[Tunnel] 当前没有分组。"
        return 0
    fi

    echo -e "\n${YELLOW}--- Tunnel 分组 ---${PLAIN}"
    printf '%-18s %-8s %-8s %-8s\n' "group" "总数" "启用" "停用"
    for key in "${groups[@]}"; do
        printf '%-18s %-8s %-8s %-8s\n' "$key" "${totals[$key]}" "${enabled[$key]}" "${disabled[$key]}"
    done
}

doctor_tunnel_groups() {
    local line status mode tag listen listen_port target target_port network remark type group key relay_status
    local -A totals enabled disabled abnormal
    local groups=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        key="${group:-未分组}"
        if [[ -z "${totals[$key]+x}" ]]; then
            groups+=("$key")
            totals[$key]=0
            enabled[$key]=0
            disabled[$key]=0
            abnormal[$key]=0
        fi
        totals[$key]=$((totals[$key] + 1))
        if [[ "$status" == "启用" ]]; then
            enabled[$key]=$((enabled[$key] + 1))
        else
            disabled[$key]=$((disabled[$key] + 1))
        fi
        load_forward_vars_from_tag "$tag" >/dev/null 2>&1 || {
            abnormal[$key]=$((abnormal[$key] + 1))
            continue
        }
        relay_status="$(forward_relay_route_status)"
        if [[ "$FORWARD_MODE" == "relay" && "$relay_status" == "缺失" ]]; then
            abnormal[$key]=$((abnormal[$key] + 1))
        fi
    done < <(forward_all_lines)

    if [[ ${#groups[@]} -eq 0 ]]; then
        info "[Tunnel] 当前没有可诊断的分组。"
        return 0
    fi

    echo -e "\n${YELLOW}--- Tunnel 分组诊断 ---${PLAIN}"
    for key in "${groups[@]}"; do
        echo "group: ${key}"
        echo "总数: ${totals[$key]}"
        echo "启用: ${enabled[$key]}"
        echo "停用: ${disabled[$key]}"
        echo "异常: ${abnormal[$key]}"
        echo
    done
}

export_forward_rules() {
    local timestamp outfile export_dir

    FORWARD_EXPORTED_FILE=""
    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口转发] 缺少 jq，无法导出。"
        return 1
    }

    timestamp="$(date +%Y%m%d%H%M%S)"
    export_dir="${FORWARD_EXPORT_DIR:-/root}"
    mkdir -p "$export_dir" || {
        err "[失败] [端口转发] 创建导出目录失败: $export_dir"
        return 1
    }
    outfile="$(mktemp --suffix=.json "${export_dir}/xray-tunnels-${timestamp}.XXXXXX")" || {
        err "[失败] [端口转发] 创建导出文件失败: $export_dir"
        return 1
    }

    if [[ -f "$STATE_FILE" ]] && jq -e '(((.tunnels // []) + (.forwards // [])) | length) > 0' "$STATE_FILE" >/dev/null 2>&1; then
        jq '{
          version: 1,
          type: "xray-oneclick-tunnels",
          tunnels: ([((.tunnels // [])[]?), ((.forwards // [])[]?)] | unique_by(.tag))
        }' "$STATE_FILE" >"$outfile" || {
            rm -f "$outfile"
            err "[失败] [端口转发] 导出 state 失败。"
            return 1
        }
    elif [[ -f "$CONFIG_FILE" ]]; then
        jq --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
            --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
          def managed_tag:
            ((.tag // "") | startswith($tunnel_prefix)) or
            ((.tag // "") | startswith($legacy_prefix));
          def tunnel_protocol: (.protocol == "dokodemo-door" or .protocol == "tunnel");
          . as $root |
          {
            version: 1,
            type: "xray-oneclick-tunnels",
            tunnels: [
              $root.inbounds[]? |
              select(managed_tag) |
              select(tunnel_protocol) |
              . as $in |
              {
                tag: $in.tag,
                type: (if ($in.settings.portMap // null) then "portMap" else "single" end),
                group: "",
                listen: ($in.listen // "0.0.0.0"),
                listen_port: $in.port,
                target: ($in.settings.address // ""),
                target_port: $in.settings.port,
                network: ($in.settings.network // "tcp"),
                mode: (if any($root.routing.rules[]?; (.type == "field") and (.outboundTag == "direct") and (((.inboundTag // []) | if type == "array" then any(.[]; . == $in.tag) else false end))) then "relay" else "safe" end),
                remark: "",
                enabled: true
              } + (if ($in.settings.portMap // null) then {port_map: $in.settings.portMap} else {} end)
            ]
          }
        ' "$CONFIG_FILE" >"$outfile" || {
            rm -f "$outfile"
            err "[失败] [端口转发] 从 config.json 导出失败。"
            return 1
        }
    else
        if ! printf '{\n  "version": 1,\n  "type": "xray-oneclick-tunnels",\n  "tunnels": []\n}\n' >"$outfile"; then
            rm -f "$outfile"
            return 1
        fi
    fi

    chmod 600 "$outfile" || {
        rm -f "$outfile"
        err "[失败] [端口转发] 无法保护导出文件权限。"
        return 1
    }
    FORWARD_EXPORTED_FILE="$outfile"
    ok "[完成] Tunnel 规则已导出: $outfile"
}

generate_forward_template() {
    local outfile tmp

    outfile="${FORWARD_EXPORT_DIR:-/root}/xray-tunnels-template.json"
    mkdir -p "$(dirname "$outfile")" || return 1
    tmp="$(mktemp "${outfile}.tmp.XXXXXX")" || return 1
    if ! cat >"$tmp" <<'JSON'
{
  "version": 1,
  "type": "xray-oneclick-tunnels",
  "tunnels": [
    {
      "tag": "tunnel-30000-443",
      "type": "single",
      "group": "landing-us",
      "listen": "0.0.0.0",
      "listen_port": 30000,
      "target": "1.2.3.4",
      "target_port": 443,
      "network": "tcp",
      "mode": "relay",
      "remark": "landing-us",
      "enabled": true
    }
  ]
}
JSON
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$outfile" || {
        rm -f "$tmp"
        return 1
    }
    ok "[完成] Tunnel 导入模板已生成: $outfile"
}

list_managed_ports() {
    [[ -f "$CONFIG_FILE" ]] || {
        info "[端口] 未找到配置文件: $CONFIG_FILE"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口] 缺少 jq，无法读取配置。"
        return 1
    }

    echo -e "\n${YELLOW}--- 脚本管理的监听端口 ---${PLAIN}"
    printf '%-8s %-12s %s\n' "端口" "类型" "监听"
    jq -r --arg ss "$SS_TAG" \
        --arg vless "$VLESS_TAG" \
        --arg reality "$REALITY_TAG" \
        --arg reality_defender "$REALITY_DEFENDER_TAG" \
        --arg xhttp "$VLESS_XHTTP_FM_TAG" \
        --arg socks "$SOCKS_TAG" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
        def managed_tag:
          ((.tag // "") | startswith($tunnel_prefix)) or
          ((.tag // "") | startswith($legacy_prefix));
        .inbounds[]? |
        select(
          .tag == $ss or
          .tag == $vless or
          .tag == $reality or
          .tag == $reality_defender or
          .tag == $xhttp or
          .tag == $socks or
          managed_tag
        ) |
        [
          (.port | tostring),
          (if .tag == $ss then "SS2022"
           elif .tag == $vless then "VLESS"
           elif .tag == $reality then "Reality"
           elif .tag == $reality_defender then "Reality-Def"
           elif .tag == $xhttp then "XHTTP-FM"
           elif .tag == $socks then "SOCKS5"
           else "Tunnel" end),
          (if managed_tag then .tag else (.listen // "0.0.0.0") end)
        ] | @tsv
    ' "$CONFIG_FILE" 2>/dev/null | while IFS=$'\t' read -r port proto listen; do
        [[ -n "$port" ]] || continue
        printf '%-8s %-12s %s\n' "$port" "$proto" "$listen"
    done
}

resolve_tunnel_import_file() {
    local import_path="$1"
    local candidate

    import_path="${import_path//$'\r'/}"
    if [[ -d "$import_path" ]]; then
        candidate="${import_path%/}/tunnels.json"
        [[ -f "$candidate" ]] || {
            err "[失败] [Tunnel] 部署包目录中未找到 tunnels.json: $candidate"
            return 1
        }
        printf '%s' "$candidate"
        return 0
    fi

    printf '%s' "$import_path"
}

import_forward_rules() {
    local import_file="${1:-}" tmp_records line tag listen listen_port target target_port network mode remark enabled choice imported new_tag type group port_map
    local assume_yes="false" arg state_snapshot
    local import_lines=()

    shift || true
    if tunnel_import_auto_yes_enabled; then
        assume_yes="true"
    fi
    for arg in "$@"; do
        case "$arg" in
            --yes | -y)
                assume_yes="true"
                ;;
            *)
                err "[失败] [Tunnel] 未知 import 参数: $arg"
                echo "用法: ike tunnel import [文件路径] [--yes]"
                return 1
                ;;
        esac
    done

    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口转发] 缺少 jq，无法导入。"
        return 1
    }

    if [[ -z "$import_file" ]]; then
        read -r -p "导入文件路径: " import_file
    fi
    import_file="$(resolve_tunnel_import_file "$import_file")" || return 1
    [[ -f "$import_file" ]] || {
        err "[失败] [端口转发] 未找到导入文件: $import_file"
        return 1
    }

    jq empty "$import_file" >/dev/null 2>&1 || {
        err "[失败] [端口转发] JSON 格式无效。"
        return 1
    }

    jq -e '
      def src:
        if type == "array" then .
        elif (.tunnels // null) then .tunnels
        else (.forwards // [])
        end;
      def valid_port(p): ((try (p | tonumber) catch 0) >= 1 and (try (p | tonumber) catch 0) <= 65535);
      def valid_listen_port(p; t):
        if t == "portMap" then
          ((p | tostring | split(",") | length) > 0 and all((p | tostring | split(","))[]; valid_port(.)))
        else
          valid_port(p)
        end;
      (src | type) == "array" and
      all(src[]?;
        ((.type // "single") as $t |
        (.tag | type == "string") and ((.tag | startswith("tunnel-")) or (.tag | startswith("forward-"))) and
        (.listen | type == "string") and
        valid_listen_port(.listen_port; $t) and
        (.target | type == "string") and
        valid_port(.target_port) and
        ((.network // "tcp") as $n | ["tcp","udp","tcp,udp"] | index($n)) and
        ((.mode // "safe") as $m | ["safe","relay"] | index($m)) and
        (["single","portMap"] | index($t)) and
        (if (.type // "single") == "portMap" then ((.port_map // {}) | type == "object") else true end)
        )
      )
    ' "$import_file" >/dev/null || {
        err "[失败] [端口转发] 导入文件缺少必要字段或字段非法。"
        return 1
    }

    install_or_update_xray || return 1
    probe_tunnel_protocol
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    tmp_records="$(mktemp)" || return 1
    imported=0

    mapfile -t import_lines < <(jq -c '
      def src:
        if type == "array" then .
        elif (.tunnels // null) then .tunnels
        else (.forwards // [])
        end;
      src[]?
    ' "$import_file")

    for line in "${import_lines[@]}"; do
        tag="$(jq -r '.tag' <<<"$line")"
        type="$(jq -r '.type // "single"' <<<"$line")"
        group="$(jq -r '.group // ""' <<<"$line")"
        listen="$(jq -r '.listen' <<<"$line")"
        listen_port="$(jq -r '.listen_port | tostring' <<<"$line")"
        target="$(jq -r '.target' <<<"$line")"
        target_port="$(jq -r '.target_port | tostring' <<<"$line")"
        network="$(jq -r '.network // "tcp"' <<<"$line")"
        mode="$(jq -r '.mode // "safe"' <<<"$line")"
        remark="$(jq -r '.remark // ""' <<<"$line")"
        enabled="$(jq -r '(.enabled // true) | tostring' <<<"$line")"
        port_map="$(jq -c '.port_map // {}' <<<"$line")"
        tag="${tag//$'\r'/}"
        type="${type//$'\r'/}"
        group="${group//$'\r'/}"
        listen="${listen//$'\r'/}"
        listen_port="${listen_port//$'\r'/}"
        target="${target//$'\r'/}"
        target_port="${target_port//$'\r'/}"
        network="${network//$'\r'/}"
        mode="${mode//$'\r'/}"
        remark="${remark//$'\r'/}"
        enabled="${enabled//$'\r'/}"
        port_map="${port_map//$'\r'/}"
        FORWARD_TAG="$tag"
        FORWARD_TYPE="$(normalize_tunnel_type "$type")"
        FORWARD_GROUP="$group"
        FORWARD_LISTEN="$listen"
        FORWARD_LISTEN_PORT="$listen_port"
        FORWARD_TARGET="$target"
        FORWARD_TARGET_PORT="$target_port"
        FORWARD_NETWORK="${network:-tcp}"
        FORWARD_MODE="${mode:-safe}"
        FORWARD_REMARK="$remark"
        FORWARD_ENABLED="${enabled:-true}"
        FORWARD_PORT_MAP_JSON="$port_map"
        [[ -n "$FORWARD_PORT_MAP_JSON" ]] || FORWARD_PORT_MAP_JSON="{}"

        if forward_tag_known "$FORWARD_TAG"; then
            if [[ "$assume_yes" == "true" ]]; then
                choice="3"
                info "[冲突] 已存在 tag: ${FORWARD_TAG}，--yes 模式将自动改名。"
            else
                echo -e "\n[冲突] 已存在 tag: ${FORWARD_TAG}"
                echo " 1) 跳过"
                echo " 2) 覆盖"
                echo " 3) 自动改名"
                read -r -p "选项 (默认: 1): " choice
            fi
            case "${choice:-1}" in
                2)
                    remove_forward_config_by_tag "$FORWARD_TAG" || return 1
                    ;;
                3)
                    new_tag="$(generate_unique_forward_tag_from_base "$FORWARD_TAG")" || return 1
                    info "[导入] ${FORWARD_TAG} 已自动改名为 ${new_tag}"
                    FORWARD_TAG="$new_tag"
                    ;;
                *)
                    info "[跳过] ${tag}"
                    continue
                    ;;
            esac
        fi

        write_forward_config_from_vars || return 1
        printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$FORWARD_TAG" "$FORWARD_TYPE" "$FORWARD_GROUP" "$FORWARD_LISTEN" "$FORWARD_LISTEN_PORT" "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" "$FORWARD_NETWORK" "$FORWARD_MODE" "$FORWARD_REMARK" "$FORWARD_ENABLED" "$FORWARD_PORT_MAP_JSON" >>"$tmp_records"
        ((imported += 1))
    done

    if ((imported == 0)); then
        rm -f "$tmp_records"
        info "[端口转发] 没有导入任何规则。"
        return 0
    fi

    if ! apply_config "Tunnel 中转"; then
        rm -f "$tmp_records"
        err "[失败] [端口转发] 导入后应用配置失败。"
        return 1
    fi

    state_snapshot="$(create_state_snapshot)" || {
        rm -f "$tmp_records"
        rollback_config_after_state_failure "Tunnel 批量导入"
        return 1
    }

    while IFS=$'\037' read -r FORWARD_TAG FORWARD_TYPE FORWARD_GROUP FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED FORWARD_PORT_MAP_JSON; do
        if ! state_sync_forward_rule; then
            restore_state_snapshot "$state_snapshot" || true
            rm -f "$state_snapshot" "$tmp_records"
            rollback_config_after_state_failure "Tunnel 批量导入"
            return 1
        fi
    done <"$tmp_records"
    rm -f "$state_snapshot" "$tmp_records"

    state_set_meta_action "导入端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 已导入 ${imported} 条转发规则。"
}

export_tunnel_bundle() {
    local timestamp bundle_dir old_export_dir exported_file

    timestamp="$(date +%Y%m%d%H%M%S)"
    mkdir -p "${TUNNEL_BUNDLE_EXPORT_DIR:-/root}" || return 1
    bundle_dir="$(mktemp -d "${TUNNEL_BUNDLE_EXPORT_DIR:-/root}/xray-tunnel-bundle-${timestamp}.XXXXXX")" || {
        err "[失败] [Tunnel] 创建部署包目录失败: $bundle_dir"
        return 1
    }

    old_export_dir="${FORWARD_EXPORT_DIR:-}"
    FORWARD_EXPORT_DIR="$bundle_dir"
    export_forward_rules >/dev/null || {
        FORWARD_EXPORT_DIR="$old_export_dir"
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    }
    FORWARD_EXPORT_DIR="$old_export_dir"

    exported_file="${FORWARD_EXPORTED_FILE:-}"
    [[ -n "$exported_file" ]] || {
        err "[失败] [Tunnel] 未找到导出的 tunnels.json。"
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    }
    mv "$exported_file" "$bundle_dir/tunnels.json" || {
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    }
    chmod 600 "$bundle_dir/tunnels.json" || {
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    }

    if ! cat >"$bundle_dir/README.txt" <<EOF
Xray-OneClick Tunnel 部署包

本目录包含:
- tunnels.json: Tunnel 规则导出文件
- install-tunnels.sh: 可选辅助导入脚本

在另一台 Linux 机器上导入:

curl -fsSL ${RAW_SCRIPT_URL} -o install.sh
XRAY_ONECLICK_YES=1 bash install.sh bootstrap
ike tunnel import /root/tunnels.json

也可以使用非交互导入:

ike tunnel import /root/tunnels.json --yes
ike tunnel bundle import /root/xray-tunnel-bundle-YYYYmmddHHMMSS --yes

说明:
- --yes 遇到 tag 冲突时会自动改名。
- 导入不会覆盖非 Tunnel 协议入站。
EOF
    then
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    fi

    if ! cat >"$bundle_dir/install-tunnels.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh"
SCRIPT_PATH="/root/install.sh"
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
XRAY_ONECLICK_YES=1 bash "$SCRIPT_PATH" bootstrap
bash "$SCRIPT_PATH" tunnel bundle import "$BUNDLE_DIR" --yes
EOF
    then
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    fi
    chmod 600 "$bundle_dir/README.txt" || {
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    }
    chmod 700 "$bundle_dir/install-tunnels.sh" || {
        remove_managed_tree "$bundle_dir" >/dev/null 2>&1 || true
        return 1
    }

    ok "[完成] Tunnel 部署包已导出: $bundle_dir"
    ok "[部署包] tunnels.json: $bundle_dir/tunnels.json"
    ok "[部署包] README.txt: $bundle_dir/README.txt"
    ok "[部署包] install-tunnels.sh: $bundle_dir/install-tunnels.sh"
}

generate_tunnel_script_bundle() {
    local label="$1"

    info "[Tunnel] ${label}"
    export_tunnel_bundle
}

import_tunnel_bundle() {
    local import_path="${1:-}"

    if [[ -n "$import_path" ]]; then
        import_path="$(resolve_tunnel_import_file "$import_path")" || return 1
        shift || true
        import_forward_rules "$import_path" "$@"
    else
        import_forward_rules "$@"
    fi
}

configure_tunnel_portmap_rule() {
    local input local_port target target_port map_tmp first_target="" first_target_port="" first_local_port="" local_ports=()

    FORWARD_TYPE="portMap"
    FORWARD_MODE="relay"
    FORWARD_NETWORK="tcp"
    FORWARD_REMARK=""
    FORWARD_GROUP=""
    FORWARD_PORT_MAP_JSON="{}"

    echo -e "\n${YELLOW}[Tunnel 中转] 多端口落地组（portMap）${PLAIN}"
    info "[提示] portMap 会优先生成单个 Tunnel inbound；如果 Xray 校验失败，会自动回退为多条 single Tunnel。"
    read -r -p "分组名称 (建议填写，例如 landing-us): " FORWARD_GROUP
    read -r -p "本机监听地址 (默认: 0.0.0.0): " FORWARD_LISTEN
    FORWARD_LISTEN="${FORWARD_LISTEN:-0.0.0.0}"
    if [[ "$FORWARD_LISTEN" =~ [[:space:]] || -z "$FORWARD_LISTEN" ]]; then
        err "[失败] [Tunnel] 本机监听地址无效。"
        return 1
    fi

    read -r -p "模式 safe / relay (默认: relay): " input
    FORWARD_MODE="${input:-relay}"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [Tunnel] 模式无效。"
        return 1
    }

    read -r -p "网络类型 tcp / udp / tcp,udp (默认: tcp): " input
    FORWARD_NETWORK="${input:-tcp}"
    validate_forward_network "$FORWARD_NETWORK" || {
        err "[失败] [Tunnel] 网络类型无效。"
        return 1
    }

    map_tmp="$(mktemp)" || return 1
    printf '{}\n' >"$map_tmp"
    while true; do
        read -r -p "本地端口 (留空结束): " local_port
        [[ -z "$local_port" && ${#local_ports[@]} -gt 0 ]] && break
        if ! validate_port "$local_port"; then
            err "端口无效，请输入 1-65535 之间的数字。"
            continue
        fi

        read -r -p "目标地址，例如 1.2.3.4 或 example.com: " target
        if [[ -z "$target" || "$target" =~ [[:space:]] ]]; then
            err "[失败] [Tunnel] 目标地址无效。"
            continue
        fi
        while true; do
            read -r -p "目标端口: " target_port
            validate_port "$target_port" && break
            err "端口无效，请输入 1-65535 之间的数字。"
        done

        if [[ ${#local_ports[@]} -eq 0 ]]; then
            first_local_port="$local_port"
            first_target="$target"
            first_target_port="$target_port"
        fi
        local_ports+=("$local_port")
        if ! jq --arg port "$local_port" --arg value "${target}:${target_port}" '. + {($port): $value}' "$map_tmp" >"${map_tmp}.new" ||
            ! mv "${map_tmp}.new" "$map_tmp"; then
            rm -f "$map_tmp" "${map_tmp}.new"
            err "[失败] [Tunnel] 生成 portMap 失败。"
            return 1
        fi
    done

    read -r -p "备注名称，可选: " FORWARD_REMARK
    FORWARD_LISTEN_PORT="$(
        IFS=,
        printf '%s' "${local_ports[*]}"
    )"
    FORWARD_TARGET="$first_target"
    FORWARD_TARGET_PORT="$first_target_port"
    FORWARD_PORT_MAP_JSON="$(cat "$map_tmp")"
    rm -f "$map_tmp" "${map_tmp}.new"

    [[ -n "$first_local_port" ]] || {
        err "[失败] [Tunnel] 至少需要添加一条端口映射。"
        return 1
    }

    confirm_forward_safety_warnings || {
        err "[取消] 已取消添加 Tunnel portMap。"
        return 1
    }
}

install_tunnel_portmap_rule() {
    local tmp_records line local_port value target target_port state_snapshot

    FORWARD_TYPE="portMap"
    FORWARD_ENABLED="true"
    validate_forward_mode "$FORWARD_MODE" || return 1
    install_or_update_xray || return 1
    probe_tunnel_protocol
    generate_forward_tag
    backup_config || {
        err "[失败] [Tunnel] 配置备份失败。"
        return 1
    }
    write_forward_config_from_vars || return 1

    if apply_config "Tunnel portMap"; then
        if ! state_sync_forward_rule; then
            rollback_config_after_state_failure "Tunnel portMap"
            return 1
        fi
        state_set_meta_action "添加 Tunnel portMap" || err "[状态] 最近变更记录失败。"
        ok "[完成] Tunnel portMap 已添加: ${FORWARD_TAG}"
        return 0
    fi

    info "[Tunnel] portMap 配置校验或重启失败，正在回退为多条 single Tunnel。"
    backup_config || {
        err "[失败] [Tunnel] fallback 前配置备份失败。"
        return 1
    }
    tmp_records="$(mktemp)" || return 1
    while IFS=$'\t' read -r local_port value; do
        local_port="${local_port//$'\r'/}"
        value="${value//$'\r'/}"
        target="${value%:*}"
        target_port="${value##*:}"
        FORWARD_TYPE="single"
        FORWARD_LISTEN_PORT="$local_port"
        FORWARD_TARGET="$target"
        FORWARD_TARGET_PORT="$target_port"
        FORWARD_PORT_MAP_JSON="{}"
        generate_forward_tag
        write_forward_config_from_vars || {
            rm -f "$tmp_records"
            return 1
        }
        printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$FORWARD_TAG" "$FORWARD_TYPE" "$FORWARD_GROUP" "$FORWARD_LISTEN" "$FORWARD_LISTEN_PORT" "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" "$FORWARD_NETWORK" "$FORWARD_MODE" "$FORWARD_REMARK" "$FORWARD_ENABLED" "$FORWARD_PORT_MAP_JSON" >>"$tmp_records"
    done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$FORWARD_PORT_MAP_JSON")

    if ! apply_config "Tunnel portMap fallback"; then
        rm -f "$tmp_records"
        err "[失败] [Tunnel] portMap fallback 应用配置失败。"
        return 1
    fi

    state_snapshot="$(create_state_snapshot)" || {
        rm -f "$tmp_records"
        rollback_config_after_state_failure "Tunnel portMap fallback"
        return 1
    }

    while IFS=$'\037' read -r FORWARD_TAG FORWARD_TYPE FORWARD_GROUP FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED FORWARD_PORT_MAP_JSON; do
        if ! state_sync_forward_rule; then
            restore_state_snapshot "$state_snapshot" || true
            rm -f "$state_snapshot" "$tmp_records"
            rollback_config_after_state_failure "Tunnel portMap fallback"
            return 1
        fi
    done <"$tmp_records"
    rm -f "$state_snapshot" "$tmp_records"
    state_set_meta_action "添加 Tunnel portMap fallback" || err "[状态] 最近变更记录失败。"
    ok "[完成] portMap 已回退为多条 single Tunnel。"
}

configure_forward_menu() {
    local choice

    while true; do
        echo -e "\n${YELLOW}[Tunnel 中转管理]${PLAIN}"
        echo " 1) 单端口落地中转（relay/tcp,udp）"
        echo " 2) 多端口落地组（portMap / fallback 多条 single）"
        echo " 3) 普通公网转发（safe/tcp）"
        echo " 4) 内网服务暴露（relay/tcp）"
        echo " 5) UDP 游戏/语音转发（safe 或 relay，可选 udp/tcp,udp）"
        echo " 6) 自定义 Tunnel"
        echo " 7) 查看 Tunnel 规则"
        echo " 8) 修改 Tunnel 规则"
        echo " 9) 启用/停用 Tunnel 规则"
        echo "10) 删除 Tunnel 规则"
        echo "11) 测试 Tunnel 目标"
        echo "12) 诊断 Tunnel 规则"
        echo "13) Tunnel 分组统计/诊断"
        echo "14) 生成导入模板"
        echo "15) 查看脚本管理端口"
        echo "16) 导出/导入 Tunnel 规则"
        echo "17) 返回主菜单"
        read -r -p "选项 (默认: 17): " choice

        case "${choice:-17}" in
            1)
                if ! { prepare_system && configure_forward_scenario "landing" && install_forward_rule; }; then
                    err "[失败] 添加单端口落地中转未完成，请查看上方错误信息。"
                fi
                ;;
            2)
                if ! { prepare_system && configure_tunnel_portmap_rule && install_tunnel_portmap_rule; }; then
                    err "[失败] 添加多端口落地组未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                if ! { prepare_system && configure_forward_scenario "public" && install_forward_rule; }; then
                    err "[失败] 添加普通公网转发未完成，请查看上方错误信息。"
                fi
                ;;
            4)
                if ! { prepare_system && configure_forward_scenario "lan" && install_forward_rule; }; then
                    err "[失败] 添加内网服务暴露未完成，请查看上方错误信息。"
                fi
                ;;
            5)
                if ! { prepare_system && configure_forward_scenario "udp" && install_forward_rule; }; then
                    err "[失败] 添加 UDP 转发未完成，请查看上方错误信息。"
                fi
                ;;
            6)
                if ! { prepare_system && configure_forward_scenario "custom" && install_forward_rule; }; then
                    err "[失败] 添加自定义 Tunnel 未完成，请查看上方错误信息。"
                fi
                ;;
            7)
                list_forward_rules
                ;;
            8)
                if ! { prepare_system && edit_forward_rule; }; then
                    err "[失败] 修改 Tunnel 规则未完成，请查看上方错误信息。"
                fi
                ;;
            9)
                echo " 1) 启用 Tunnel 规则"
                echo " 2) 停用 Tunnel 规则"
                read -r -p "选项: " choice
                case "$choice" in
                    1) prepare_system && set_forward_enabled "true" ;;
                    2) prepare_system && set_forward_enabled "false" ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            10)
                if ! { prepare_system && delete_forward_rule; }; then
                    err "[失败] 删除 Tunnel 规则未完成，请查看上方错误信息。"
                fi
                ;;
            11)
                test_forward_rule || err "[失败] 测试 Tunnel 目标未完成，请查看上方错误信息。"
                ;;
            12)
                doctor_forward_rules || err "[失败] 诊断 Tunnel 规则未完成，请查看上方错误信息。"
                ;;
            13)
                echo " 1) 分组统计"
                echo " 2) 分组诊断"
                read -r -p "选项: " choice
                case "$choice" in
                    1) list_tunnel_groups ;;
                    2) doctor_tunnel_groups ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            14)
                generate_forward_template || err "[失败] 生成导入模板未完成，请查看上方错误信息。"
                ;;
            15)
                list_managed_ports || err "[失败] 查看脚本管理端口未完成，请查看上方错误信息。"
                ;;
            16)
                echo " 1) 导出 Tunnel 规则"
                echo " 2) 导入 Tunnel 规则"
                read -r -p "选项: " choice
                case "$choice" in
                    1) export_forward_rules ;;
                    2) prepare_system && import_forward_rules ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            17)
                return 0
                ;;
            *)
                err "无效选项。"
                ;;
        esac

        echo
        read -r -p "按回车返回 Tunnel 菜单..." || return 0
    done
}

run_bootstrap_command() {
    local import_file restart=if-active import_args=()

    [[ $# -eq 0 ]] || {
        err "[失败] bootstrap 不接受额外参数；Tunnel 导入请使用 XRAY_ONECLICK_TUNNEL_IMPORT。"
        return 1
    }
    prepare_system || {
        err "[失败] Bootstrap 系统准备失败。"
        return 1
    }
    if [[ -z "${XRAY_ONECLICK_TUNNEL_IMPORT:-}" ]]; then restart=always; fi
    install_or_update_xray false "$restart" || {
        err "[失败] Bootstrap 安装/更新 Xray 失败。"
        return 1
    }
    if [[ -n "${XRAY_ONECLICK_TUNNEL_IMPORT:-}" ]]; then
        import_file="$(resolve_tunnel_import_file "$XRAY_ONECLICK_TUNNEL_IMPORT")" || return 1
        if tunnel_import_auto_yes_enabled; then
            import_args+=(--yes)
        fi
        import_forward_rules "$import_file" "${import_args[@]}" || {
            err "[失败] Bootstrap 导入 Tunnel 规则失败。"
            return 1
        }
    else
        info "[Bootstrap] 未设置 XRAY_ONECLICK_TUNNEL_IMPORT，跳过 Tunnel 导入。"
    fi

    echo
    show_version
    list_forward_rules
    view_config "$LINK_VIEW_MODE" "doctor"
}

run_tunnel_command() {
    local action="${1:-}"
    local mode="${2:-safe}"
    local tag_arg="${2:-}"
    local subaction="${2:-}"

    case "$action" in
        list | "")
            list_forward_rules
            ;;
        add)
            if [[ "$mode" == "map" ]]; then
                prepare_system || {
                    err "[失败] 系统准备失败，无法添加 Tunnel portMap。"
                    return 1
                }
                configure_tunnel_portmap_rule && install_tunnel_portmap_rule
                return $?
            fi
            if ! validate_forward_mode "$mode"; then
                err "[失败] 未知 tunnel add 模式: $mode"
                echo "用法: ike tunnel add [safe|relay|map]"
                return 1
            fi
            prepare_system || {
                err "[失败] 系统准备失败，无法添加 Tunnel。"
                return 1
            }
            if [[ "$mode" == "relay" ]]; then
                configure_forward_rule "$mode" "tcp,udp" "true" "单端口落地中转（relay/tcp,udp）" && install_forward_rule
            else
                configure_forward_rule "$mode" "tcp" "true" "普通公网转发（safe/tcp）" && install_forward_rule
            fi
            ;;
        enable)
            prepare_system || {
                err "[失败] 系统准备失败，无法启用 Tunnel。"
                return 1
            }
            set_forward_enabled "true" "$tag_arg"
            ;;
        disable)
            prepare_system || {
                err "[失败] 系统准备失败，无法停用 Tunnel。"
                return 1
            }
            set_forward_enabled "false" "$tag_arg"
            ;;
        edit)
            prepare_system || {
                err "[失败] 系统准备失败，无法修改 Tunnel。"
                return 1
            }
            edit_forward_rule "$tag_arg"
            ;;
        test)
            test_forward_rule "$tag_arg"
            ;;
        doctor)
            doctor_forward_rules "$tag_arg"
            ;;
        group)
            case "${2:-list}" in
                list | "")
                    list_tunnel_groups
                    ;;
                doctor)
                    doctor_tunnel_groups
                    ;;
                *)
                    err "[失败] 未知 tunnel group 参数: ${2:-}"
                    echo "用法: ike tunnel group list | ike tunnel group doctor"
                    return 1
                    ;;
            esac
            ;;
        template)
            generate_forward_template
            ;;
        ports)
            list_managed_ports
            ;;
        export)
            export_forward_rules
            ;;
        generate-script)
            generate_tunnel_script_bundle "生成 Tunnel 部署包"
            ;;
        generate-relay-script)
            generate_tunnel_script_bundle "生成中转/落地部署脚本包"
            ;;
        generate-client-script)
            generate_tunnel_script_bundle "生成可导入 Tunnel 规则包"
            ;;
        bundle)
            case "$subaction" in
                export)
                    export_tunnel_bundle
                    ;;
                import)
                    prepare_system || {
                        err "[失败] 系统准备失败，无法导入 Tunnel 部署包。"
                        return 1
                    }
                    shift 2
                    import_tunnel_bundle "$@"
                    ;;
                *)
                    err "[失败] 未知 tunnel bundle 参数: $subaction"
                    echo "用法: ike tunnel bundle export | ike tunnel bundle import [文件或目录] [--yes]"
                    return 1
                    ;;
            esac
            ;;
        import)
            prepare_system || {
                err "[失败] 系统准备失败，无法导入 Tunnel。"
                return 1
            }
            shift
            import_forward_rules "$@"
            ;;
        del | delete | remove)
            prepare_system || {
                err "[失败] 系统准备失败，无法删除 Tunnel。"
                return 1
            }
            delete_forward_rule "$tag_arg"
            ;;
        *)
            err "[失败] 未知 tunnel 参数: $action"
            echo "用法: ike tunnel list | ike tunnel add [safe|relay|map] | ike tunnel enable [tag] | ike tunnel disable [tag] | ike tunnel edit [tag] | ike tunnel test [tag] | ike tunnel doctor [tag] | ike tunnel group list|doctor | ike tunnel template | ike tunnel ports | ike tunnel export | ike tunnel bundle export|import | ike tunnel generate-script | ike tunnel import | ike tunnel del [tag]"
            return 1
            ;;
    esac
}
