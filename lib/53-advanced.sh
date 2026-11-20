#!/usr/bin/env bash
# Advanced VLESS profile combinations.

advanced_profile_tag() {
    case "$1" in
        xhttp-reality) printf '%s' "$VLESS_XHTTP_REALITY_TAG" ;;
        enc-reality) printf '%s' "$VLESS_ENC_REALITY_TAG" ;;
        fullstack) printf '%s' "$VLESS_FULLSTACK_TAG" ;;
        *) return 1 ;;
    esac
}

advanced_profile_state_key() {
    case "$1" in
        xhttp-reality) printf '%s' "$VLESS_XHTTP_REALITY_STATE_KEY" ;;
        enc-reality) printf '%s' "$VLESS_ENC_REALITY_STATE_KEY" ;;
        fullstack) printf '%s' "$VLESS_FULLSTACK_STATE_KEY" ;;
        *) return 1 ;;
    esac
}

advanced_profile_name() {
    case "$1" in
        xhttp-reality) printf '%s' "VLESS XHTTP + REALITY" ;;
        enc-reality) printf '%s' "VLESS Encryption + REALITY" ;;
        fullstack) printf '%s' "VLESS Encryption + XHTTP + REALITY + FinalMask" ;;
        *) return 1 ;;
    esac
}

advanced_profile_link_name() {
    case "$1" in
        xhttp-reality) printf '%s' "Xray-XHTTP-Reality" ;;
        enc-reality) printf '%s' "Xray-Enc-Reality" ;;
        fullstack) printf '%s' "Xray-FullStack" ;;
        *) return 1 ;;
    esac
}

advanced_profile_network() {
    case "$1" in
        xhttp-reality | fullstack) printf '%s' "xhttp" ;;
        enc-reality) printf '%s' "tcp" ;;
        *) return 1 ;;
    esac
}

advanced_profile_has_xhttp() {
    [[ "$1" == "xhttp-reality" || "$1" == "fullstack" ]]
}

advanced_profile_has_encryption() {
    [[ "$1" == "enc-reality" || "$1" == "fullstack" ]]
}

advanced_profile_has_finalmask() {
    [[ "$1" == "fullstack" ]]
}

advanced_profile_has_fallback_limit() {
    [[ "$1" == "xhttp-reality" || "$1" == "enc-reality" || "$1" == "fullstack" ]]
}

random_limit_number() {
    local min="$1"
    local max="$2"
    local span rand random_hex

    ((min <= max)) || return 1
    span=$((max - min + 1))
    if command -v openssl >/dev/null 2>&1; then
        random_hex="$(openssl rand -hex 4 2>/dev/null || true)"
        if [[ "$random_hex" =~ ^[[:xdigit:]]{8}$ ]]; then
            rand=$((16#$random_hex))
        else
            rand=$RANDOM
        fi
    else
        rand=$RANDOM
    fi
    printf '%s' "$((min + rand % span))"
}

build_advanced_fallback_limit_json() {
    local direction="${1:-upload}"
    local after_bytes bytes_per_sec burst_bytes_per_sec

    case "$direction" in
        upload)
            after_bytes="$(random_limit_number 0 1048576)" || return 1
            bytes_per_sec="$(random_limit_number 65536 262144)" || return 1
            burst_bytes_per_sec="$(random_limit_number 0 131072)" || return 1
            ;;
        download)
            after_bytes="$(random_limit_number 0 10485760)" || return 1
            bytes_per_sec="$(random_limit_number 131072 524288)" || return 1
            burst_bytes_per_sec="$(random_limit_number 0 262144)" || return 1
            ;;
        *)
            return 1
            ;;
    esac

    jq -cn --argjson after_bytes "$after_bytes" \
        --argjson bytes_per_sec "$bytes_per_sec" \
        --argjson burst_bytes_per_sec "$burst_bytes_per_sec" '{
      afterBytes: $after_bytes,
      bytesPerSec: $bytes_per_sec,
      burstBytesPerSec: $burst_bytes_per_sec
    }'
}

remove_state_key() {
    state_delete_key "$1"
}

port_belongs_to_tag() {
    local port="$1"
    local tag="$2"

    [[ -f "$CONFIG_FILE" ]] || return 1
    validate_port "$port" || return 1
    jq -e --argjson port "$port" --arg tag "$tag" 'any(.inbounds[]?; (.port? // empty) == $port and .tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

port_used_in_config_except_tag() {
    local port="$1"
    local tag="$2"

    [[ -f "$CONFIG_FILE" ]] || return 1
    validate_port "$port" || return 1
    jq -e --argjson port "$port" --arg tag "$tag" 'any(.inbounds[]?; (.port? // empty) == $port and .tag != $tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

random_free_port_except_tag() {
    local min="$1"
    local max="$2"
    local tag="$3"
    local span port rand attempt random_hex

    validate_port "$min" || return 1
    validate_port "$max" || return 1
    ((min <= max)) || return 1
    span=$((max - min + 1))

    for ((attempt = 0; attempt < 200; attempt++)); do
        if command -v openssl >/dev/null 2>&1; then
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
        if ! port_used_in_config_except_tag "$port" "$tag" && { check_port "$port" || port_belongs_to_tag "$port" "$tag"; }; then
            printf '%s' "$port"
            return 0
        fi
    done

    for ((port = min; port <= max; port++)); do
        if ! port_used_in_config_except_tag "$port" "$tag" && { check_port "$port" || port_belongs_to_tag "$port" "$tag"; }; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

ask_or_random_advanced_port() {
    local prompt="$1"
    local requested="$2"
    local tag="$3"
    local __resultvar="$4"
    local input port

    if [[ -n "$requested" ]]; then
        validate_port "$requested" || {
            err "[高级组合] 端口无效: $requested"
            return 1
        }
        if port_used_in_config_except_tag "$requested" "$tag"; then
            err "[高级组合] 端口已存在于其它 inbound: $requested"
            return 1
        fi
        if ! check_port "$requested" && ! port_belongs_to_tag "$requested" "$tag"; then
            err "[高级组合] 端口已被系统监听占用: $requested"
            return 1
        fi
        printf -v "$__resultvar" '%s' "$requested"
        return 0
    fi

    if [[ "${ADVANCED_CONFIG_MODE:-interactive}" != "interactive" ]]; then
        port="$(random_free_port_except_tag "$REALITY_PORT_MIN" "$REALITY_PORT_MAX" "$tag")" || {
            err "[高级组合] 无法在 ${REALITY_PORT_MIN}-${REALITY_PORT_MAX} 中找到可用端口。"
            return 1
        }
        printf -v "$__resultvar" '%s' "$port"
        return 0
    fi

    while true; do
        read -r -p "${prompt} (回车随机 ${REALITY_PORT_MIN}-${REALITY_PORT_MAX}): " input
        if [[ -z "$input" ]]; then
            port="$(random_free_port_except_tag "$REALITY_PORT_MIN" "$REALITY_PORT_MAX" "$tag")" || {
                err "[高级组合] 无法找到可用端口。"
                return 1
            }
            info "[高级组合] 随机选择端口: ${port}"
            printf -v "$__resultvar" '%s' "$port"
            return 0
        fi
        if ! validate_port "$input"; then
            err "[高级组合] 端口无效，请输入 1-65535。"
            continue
        fi
        if port_used_in_config_except_tag "$input" "$tag" || { ! check_port "$input" && ! port_belongs_to_tag "$input" "$tag"; }; then
            err "[高级组合] 端口 ${input} 已被占用或存在于其它 inbound。"
            continue
        fi
        warn_reserved_port "$input"
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

print_advanced_compat_hint() {
    local kind="$1"

    echo "兼容提示:"
    case "$kind" in
        xhttp-reality)
            echo "  - XHTTP + REALITY 需要较新的 Xray-core 和客户端核心。"
            echo "  - 如果客户端无法导入，建议退回普通 Reality 或 XHTTP-FinalMask off。"
            ;;
        enc-reality)
            echo "  - VLESS Encryption + REALITY 是高兼容要求组合。"
            echo "  - 如果客户端不支持 encryption + reality 同时导入，建议使用普通 Reality 或普通 VLESS Encryption。"
            ;;
        fullstack)
            echo "  - FullStack 是最高级组合，客户端兼容性要求最高。"
            echo "  - 不兼容时请按降级路径切换："
            echo "    1. ike fullstack install --finalmask off"
            echo "    2. ike xhttp-reality install"
            echo "    3. ike enc-reality install"
            echo "    4. ike reality install"
            echo "    5. ike xhttp install --finalmask off"
            echo "    6. 菜单 4 安装 VLESS Encryption"
            echo "    7. SS2022 / SOCKS5"
            ;;
    esac
    echo "  - 该高级组合默认不启用 Vision flow；如需开启，可使用 --flow vision。"
    echo "  - 如需更保守的回落限制，可使用 --fallback-limit conservative；它只是限流，不是绝对安全开关。"
    echo "  - privateKey 是服务端字段，不要填入客户端，也不要泄露。"
    echo "  - publicKey/pbk 是客户端字段。"
}

print_advanced_target_risk_notice() {
    diag_warn "未通过 REALITY 认证的流量会被转发到 target。"
    diag_warn "不建议把 CDN、公共代理敏感目标或异常目标作为默认 target。"
    diag_warn "非 443 target 可能触发 Xray 新版本 warning。"
}

configure_advanced_profile() {
    local kind="$1"
    local mode="${2:-interactive}"
    local tag name input port

    tag="$(advanced_profile_tag "$kind")" || return 1
    name="$(advanced_profile_name "$kind")" || return 1
    ADVANCED_CONFIG_MODE="$mode"
    REALITY_CONFIG_MODE="$mode"

    if [[ "$mode" != "dry-run" ]]; then
        install_or_update_xray || return 1
    fi

    ask_or_random_advanced_port "${name} 入口端口" "${ADVANCED_PORT_REQUEST:-}" "$tag" ADVANCED_PORT || return 1

    if advanced_profile_has_xhttp "$kind"; then
        if [[ "$mode" == "interactive" ]]; then
            read -r -p "XHTTP path (回车随机): " input
            ADVANCED_PATH="${input:-$(random_xhttp_path)}"
        else
            ADVANCED_PATH="${ADVANCED_PATH_REQUEST:-$(random_xhttp_path)}"
        fi
        validate_xhttp_path "$ADVANCED_PATH" || {
            err "[高级组合] path 无效，必须以 / 开头，长度不超过 128，且不能包含空格、?、# 或反斜杠。"
            return 1
        }
    else
        ADVANCED_PATH=""
    fi

    ask_or_random_reality_sni "${ADVANCED_SNI_REQUEST:-}" ADVANCED_SERVER_NAME || return 1
    info "[高级组合] REALITY target 使用 ${ADVANCED_SERVER_NAME}:443，security=reality，不使用 TLS 证书。"
    print_advanced_target_risk_notice
    if ! test_reality_target_tls "$ADVANCED_SERVER_NAME"; then
        err "[高级组合] ${ADVANCED_SERVER_NAME}:443 TLS 探测失败。"
        if [[ "$mode" == "interactive" ]]; then
            confirm_yes_no "仍然继续写入高级组合配置?" "n" || return 1
        elif ! { env_truthy "${XRAY_ONECLICK_YES:-}" || env_truthy "${ADVANCED_ASSUME_YES:-}"; }; then
            err "[高级组合] 非交互模式默认取消；确认目标可用后可设置 XRAY_ONECLICK_YES=1 重试。"
            return 1
        fi
    fi

    if [[ "$mode" == "interactive" ]]; then
        read -r -p "启用 Vision flow? [y/N]: " input
        case "${input,,}" in
            y | yes) ADVANCED_FLOW="$REALITY_FLOW_DEFAULT" ;;
            *) ADVANCED_FLOW="$REALITY_FLOW_NONE" ;;
        esac
    else
        ADVANCED_FLOW="${ADVANCED_FLOW:-$REALITY_FLOW_NONE}"
    fi
    ADVANCED_FLOW="$(normalize_reality_flow "$ADVANCED_FLOW")" || {
        err "[高级组合] --flow 仅支持 none 或 vision。"
        return 1
    }
    [[ "$ADVANCED_FLOW" == "$REALITY_FLOW_DEFAULT" ]] && print_advanced_flow_warning

    ADVANCED_FALLBACK_LIMIT_MODE="${ADVANCED_FALLBACK_LIMIT_REQUEST:-off}"
    case "$ADVANCED_FALLBACK_LIMIT_MODE" in
        off | conservative) ;;
        *)
            err "[高级组合] --fallback-limit 仅支持 off 或 conservative。"
            return 1
            ;;
    esac
    ADVANCED_FALLBACK_LIMIT_UPLOAD_JSON="null"
    ADVANCED_FALLBACK_LIMIT_DOWNLOAD_JSON="null"
    if [[ "$ADVANCED_FALLBACK_LIMIT_MODE" == "conservative" ]]; then
        ADVANCED_FALLBACK_LIMIT_UPLOAD_JSON="$(build_advanced_fallback_limit_json upload)" || return 1
        ADVANCED_FALLBACK_LIMIT_DOWNLOAD_JSON="$(build_advanced_fallback_limit_json download)" || return 1
        info "[高级组合] 已启用 conservative fallback limit。"
    fi

    ADVANCED_UUID="$(generate_uuid)" || {
        err "[高级组合] UUID 生成失败。"
        return 1
    }
    ADVANCED_SPIDER_X="/"
    generate_reality_keys || return 1
    generate_reality_short_ids || return 1

    if advanced_profile_has_encryption "$kind"; then
        [[ "$mode" != "dry-run" ]] && { ensure_xray_vlessenc || return 1; }
        VLESS_MODE="${VLESS_MODE:-basic}"
        VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
        VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
        VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"
        VLESS_AUTH="${VLESS_AUTH:-x25519}"
        if [[ "$mode" == "interactive" ]]; then
            echo -e "\n${YELLOW}[配置] ${name} 的 VLESS Encryption${PLAIN}"
            echo -e "  1) 基础模式 ${GREEN}(X25519/native/0rtt/600s)${PLAIN}"
            echo "  2) 高级模式 (认证、外观混淆、RTT、ticket)"
            read -r -p "选项 (默认: 1): " input
            if [[ "${input:-1}" == "2" ]]; then
                VLESS_MODE="advanced"
                configure_vless_advanced_options
            fi
            ask_vless_auth
        fi
        generate_vless_encryption_pair "$VLESS_AUTH" || return 1
    else
        VLESS_DECRYPTION=""
        VLESS_ENCRYPTION=""
    fi

    if advanced_profile_has_finalmask "$kind"; then
        if [[ "$mode" == "interactive" ]]; then
            info "[FinalMask] 属于高级兼容功能，客户端不兼容时请关闭。"
            read -r -p "开启 FinalMask? [y/N]: " input
            case "${input,,}" in
                y | yes) ADVANCED_FINALMASK_ENABLED="true" ;;
                *) ADVANCED_FINALMASK_ENABLED="false" ;;
            esac
            if [[ "$ADVANCED_FINALMASK_ENABLED" == "true" ]]; then
                ask_finalmask_config || return 1
            fi
        else
            ADVANCED_FINALMASK_ENABLED="${ADVANCED_FINALMASK_REQUEST:-false}"
        fi
        case "${ADVANCED_FINALMASK_ENABLED,,}" in
            true | on | yes | y | 1) ADVANCED_FINALMASK_ENABLED="true" ;;
            false | off | no | n | 0) ADVANCED_FINALMASK_ENABLED="false" ;;
            *)
                err "[高级组合] finalmask 参数必须为 on/off。"
                return 1
                ;;
        esac
        if [[ "$ADVANCED_FINALMASK_ENABLED" == "true" ]]; then
            ADVANCED_FINALMASK_JSON="$(build_finalmask_json)" || return 1
            set_finalmask_metadata_from_requests "$ADVANCED_FINALMASK_JSON"
            ADVANCED_FINALMASK_MODE="$FINALMASK_MODE"
            ADVANCED_FINALMASK_PRESET="$FINALMASK_PRESET"
            ADVANCED_FINALMASK_SUMMARY="$FINALMASK_SUMMARY"
        else
            if finalmask_extra_options_specified; then
                info "[FinalMask] FinalMask 已关闭，忽略 FinalMask 参数。"
            fi
            ADVANCED_FINALMASK_JSON=""
            ADVANCED_FINALMASK_MODE="off"
            ADVANCED_FINALMASK_PRESET="none"
            ADVANCED_FINALMASK_SUMMARY="off"
        fi
    else
        ADVANCED_FINALMASK_ENABLED="false"
        ADVANCED_FINALMASK_JSON=""
    fi
}

build_advanced_share_link() {
    local kind="$1"
    local state_key port uuid path encryption public_key short_id server_name spider_x fm_enabled fm_json flow flow_link
    local endpoint_pair host link_port name network path_uri pbk_uri sni_uri sid_uri spx_uri enc_uri fm_uri flow_uri name_uri

    state_key="$(advanced_profile_state_key "$kind")" || return 1
    network="$(advanced_profile_network "$kind")" || return 1
    port="${ADVANCED_PORT:-}"
    uuid="${ADVANCED_UUID:-}"
    path="${ADVANCED_PATH:-}"
    encryption="${VLESS_ENCRYPTION:-}"
    public_key="${REALITY_PUBLIC_KEY:-}"
    short_id="${REALITY_DEFAULT_SHORT_ID:-}"
    server_name="${ADVANCED_SERVER_NAME:-}"
    spider_x="${ADVANCED_SPIDER_X:-/}"
    fm_enabled="${ADVANCED_FINALMASK_ENABLED:-false}"
    fm_json="${ADVANCED_FINALMASK_JSON:-}"
    flow="${ADVANCED_FLOW:-$REALITY_FLOW_NONE}"

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${state_key}.port // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${state_key}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        path="$(jq -r ".${state_key}.path // empty" "$STATE_FILE" 2>/dev/null)"
        encryption="$(jq -r ".${state_key}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
        public_key="$(jq -r ".${state_key}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
        short_id="$(jq -r ".${state_key}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
        server_name="$(jq -r ".${state_key}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
        spider_x="$(jq -r ".${state_key}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
        fm_enabled="$(jq -r ".${state_key}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        fm_json="$(jq -c ".${state_key}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
        flow="$(jq -r ".${state_key}.flow // \"$REALITY_FLOW_NONE\"" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" && -n "$server_name" ]] || return 1
    flow="$(flow_state_value "$flow")" || return 1
    flow_link="$(flow_config_value "$flow" || true)"
    if advanced_profile_has_xhttp "$kind"; then
        [[ -n "$path" ]] || return 1
    fi
    if advanced_profile_has_encryption "$kind"; then
        [[ -n "$encryption" ]] || return 1
    fi

    endpoint_pair="$(link_endpoint_for_tag "$port" "$(advanced_profile_tag "$kind")" "$state_key")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    name="$(advanced_profile_link_name "$kind")"
    pbk_uri="$(url_encode "$public_key")"
    sni_uri="$(url_encode "$server_name")"
    sid_uri="$(url_encode "$short_id")"
    spx_uri="$(url_encode "$spider_x")"
    flow_uri="$(url_encode "$flow_link")"
    name_uri="$(url_encode "$name")"

    printf 'vless://%s@%s:%s?type=%s&security=reality' "$uuid" "$host" "$link_port" "$network"
    if advanced_profile_has_xhttp "$kind"; then
        path_uri="$(url_encode "$path")"
        printf '&path=%s' "$path_uri"
    fi
    printf '&pbk=%s&fp=chrome&sni=%s&sid=%s&spx=%s' "$pbk_uri" "$sni_uri" "$sid_uri" "$spx_uri"
    [[ -n "$flow_link" ]] && printf '&flow=%s' "$flow_uri"
    if advanced_profile_has_encryption "$kind"; then
        enc_uri="$(url_encode "$encryption")"
        printf '&encryption=%s' "$enc_uri"
    fi
    if advanced_profile_has_finalmask "$kind" && [[ "${fm_enabled,,}" == "true" && -n "$fm_json" && "$fm_json" != "null" ]]; then
        fm_uri="$(encode_finalmask_for_share_link "$fm_json")" || return 1
        printf '&fm=%s' "$fm_uri"
    fi
    printf '#%s' "$name_uri"
}

state_set_advanced_profile() {
    init_state || return 1
    local kind="$1"
    local state_key tmp link timestamp finalmask_json hash32
    local finalmask_mode finalmask_preset finalmask_summary flow
    local fallback_limit_mode fallback_limit_upload fallback_limit_download

    state_key="$(advanced_profile_state_key "$kind")" || return 1
    link="$(build_advanced_share_link "$kind" || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    hash32="${REALITY_X25519_HASH32:-}"
    flow="$(flow_state_value "${ADVANCED_FLOW:-$REALITY_FLOW_NONE}")" || return 1
    finalmask_json="null"
    finalmask_mode="${ADVANCED_FINALMASK_MODE:-off}"
    finalmask_preset="${ADVANCED_FINALMASK_PRESET:-none}"
    finalmask_summary="${ADVANCED_FINALMASK_SUMMARY:-off}"
    fallback_limit_mode="${ADVANCED_FALLBACK_LIMIT_MODE:-off}"
    fallback_limit_upload="${ADVANCED_FALLBACK_LIMIT_UPLOAD_JSON:-null}"
    fallback_limit_download="${ADVANCED_FALLBACK_LIMIT_DOWNLOAD_JSON:-null}"
    if advanced_profile_has_finalmask "$kind" && [[ "$ADVANCED_FINALMASK_ENABLED" == "true" ]]; then
        finalmask_json="$ADVANCED_FINALMASK_JSON"
        if [[ "$finalmask_mode" == "off" || "$finalmask_preset" == "none" || "$finalmask_summary" == "off" || -z "$finalmask_summary" ]]; then
            set_finalmask_metadata_from_json "$finalmask_json"
            finalmask_mode="$FINALMASK_MODE"
            finalmask_preset="$FINALMASK_PRESET"
            finalmask_summary="$FINALMASK_SUMMARY"
        fi
    fi

    tmp="$(state_temp_file)" || return 1
    if ! MSYS2_ENV_CONV_EXCL="*" ADVANCED_XHTTP_PATH="${ADVANCED_PATH:-}" ADVANCED_SPIDER_X="${ADVANCED_SPIDER_X:-/}" jq --arg state_key "$state_key" \
        --arg kind "$kind" \
        --arg tag "$(advanced_profile_tag "$kind")" \
        --arg port "$ADVANCED_PORT" \
        --arg uuid "$ADVANCED_UUID" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --arg public_key "$REALITY_PUBLIC_KEY" \
        --argjson short_ids "$REALITY_SHORT_IDS_JSON" \
        --arg default_short_id "$REALITY_DEFAULT_SHORT_ID" \
        --arg server_name "$ADVANCED_SERVER_NAME" \
        --arg flow "$flow" \
        --arg decryption "${VLESS_DECRYPTION:-}" \
        --arg encryption "${VLESS_ENCRYPTION:-}" \
        --arg has_encryption "$(advanced_profile_has_encryption "$kind" && printf true || printf false)" \
        --arg auth "${VLESS_AUTH:-}" \
        --arg enc_method "${VLESS_ENC_METHOD:-}" \
        --arg client_rtt "${VLESS_CLIENT_RTT:-}" \
        --arg server_ticket "${VLESS_SERVER_TICKET:-}" \
        --arg finalmask_enabled "${ADVANCED_FINALMASK_ENABLED:-false}" \
        --arg finalmask_mode "$finalmask_mode" \
        --arg finalmask_preset "$finalmask_preset" \
        --arg finalmask_summary "$finalmask_summary" \
        --argjson finalmask_json "$finalmask_json" \
        --arg fallback_limit_mode "$fallback_limit_mode" \
        --argjson fallback_limit_upload "$fallback_limit_upload" \
        --argjson fallback_limit_download "$fallback_limit_download" \
        --arg hash32 "$hash32" \
        --arg listen_scope "ipv4" \
        --arg created_at "$timestamp" \
        --arg link "$link" '
        .[$state_key] = {
          "tag": $tag,
          "kind": $kind,
          "port": ($port|tonumber),
          "uuid": $uuid,
          "private_key": $private_key,
          "public_key": $public_key,
          "short_ids": $short_ids,
          "default_short_id": $default_short_id,
          "server_name": $server_name,
          "flow": $flow,
          "listen_scope": $listen_scope,
          "spider_x": env.ADVANCED_SPIDER_X,
          "created_at": $created_at,
          "link": $link
        } |
        if env.ADVANCED_XHTTP_PATH != "" then .[$state_key].path = env.ADVANCED_XHTTP_PATH else . end |
        if $has_encryption == "true" then
          .[$state_key].decryption = $decryption |
          .[$state_key].encryption = $encryption |
          .[$state_key].auth = $auth |
          .[$state_key].enc_method = $enc_method |
          .[$state_key].client_rtt = $client_rtt |
          .[$state_key].server_ticket = $server_ticket
        else . end |
        .[$state_key].fallback_limit_mode = $fallback_limit_mode |
        .[$state_key].fallback_limit_upload = $fallback_limit_upload |
        .[$state_key].fallback_limit_download = $fallback_limit_download |
        if $kind == "fullstack" then
          .[$state_key].finalmask_enabled = ($finalmask_enabled == "true") |
          .[$state_key].finalmask_mode = $finalmask_mode |
          .[$state_key].finalmask_preset = $finalmask_preset |
          .[$state_key].finalmask_summary = $finalmask_summary |
          .[$state_key].finalmask_json = $finalmask_json
        else . end |
        if $hash32 != "" then .[$state_key].hash32 = $hash32 else . end
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[状态] 生成高级组合状态失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[状态] 写入高级组合状态失败。"
        return 1
    fi
    ensure_config_security || return 1
}

print_advanced_dry_run() {
    local kind="$1"
    local temp_config="$2"
    local link name
    local fallback_limit_mode fallback_limit_upload fallback_limit_download

    name="$(advanced_profile_name "$kind")"
    link="$(build_advanced_share_link "$kind" || true)"
    fallback_limit_mode="${ADVANCED_FALLBACK_LIMIT_MODE:-off}"
    fallback_limit_upload="${ADVANCED_FALLBACK_LIMIT_UPLOAD_JSON:-null}"
    fallback_limit_download="${ADVANCED_FALLBACK_LIMIT_DOWNLOAD_JSON:-null}"
    echo -e "\n${YELLOW}${name} dry-run 预览${PLAIN}"
    echo "----------------------------------------"
    echo "入口端口: ${ADVANCED_PORT}"
    advanced_profile_has_xhttp "$kind" && echo "Path: ${ADVANCED_PATH}"
    echo "SNI: ${ADVANCED_SERVER_NAME}"
    echo "REALITY target: ${ADVANCED_SERVER_NAME}:443"
    echo "Flow: ${ADVANCED_FLOW:-$REALITY_FLOW_NONE}"
    advanced_profile_has_fallback_limit "$kind" && echo "Fallback limit: ${fallback_limit_mode}"
    if advanced_profile_has_fallback_limit "$kind" && [[ "$fallback_limit_mode" == "conservative" ]]; then
        echo "Fallback upload: ${fallback_limit_upload}"
        echo "Fallback download: ${fallback_limit_download}"
    fi
    echo "ShortID: $(mask_value "$REALITY_DEFAULT_SHORT_ID" 2)"
    echo "PublicKey: $(mask_value "$REALITY_PUBLIC_KEY" 6)"
    advanced_profile_has_encryption "$kind" && echo "VLESS Encryption: $(mask_value "$VLESS_ENCRYPTION" 8)"
    advanced_profile_has_finalmask "$kind" && echo "FinalMask: $([[ "${ADVANCED_FINALMASK_ENABLED:-false}" == "true" ]] && printf on || printf off)"
    if advanced_profile_has_finalmask "$kind" && [[ "${ADVANCED_FINALMASK_ENABLED:-false}" == "true" ]]; then
        echo "FinalMask 模式: ${ADVANCED_FINALMASK_MODE:-preset}"
        echo "FinalMask 预设: ${ADVANCED_FINALMASK_PRESET:-balanced}"
        echo "FinalMask 摘要: ${ADVANCED_FINALMASK_SUMMARY:-}"
    fi
    [[ -n "$link" ]] && echo "Masked Link: $(mask_share_link "$link")"
    echo "将写入 inbound:"
    echo "- $(advanced_profile_tag "$kind")"
    jq empty "$temp_config" >/dev/null && echo "[✓] 临时 JSON 结构有效"
    xray_test_temp_config "$temp_config"
    echo "不会修改真实配置。"
}

install_advanced_profile() {
    local kind="$1"
    local tag name tmp config_source base_tmp network finalmask_json flow
    local fallback_limit_mode fallback_limit_upload fallback_limit_download

    tag="$(advanced_profile_tag "$kind")" || return 1
    name="$(advanced_profile_name "$kind")" || return 1
    network="$(advanced_profile_network "$kind")" || return 1
    config_source="$CONFIG_FILE"
    if [[ "${ADVANCED_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${ADVANCED_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[高级组合] 配置备份失败。"
            return 1
        }
    fi

    finalmask_json="null"
    if advanced_profile_has_finalmask "$kind" && [[ "$ADVANCED_FINALMASK_ENABLED" == "true" ]]; then
        finalmask_json="$ADVANCED_FINALMASK_JSON"
    fi
    flow="$(flow_config_value "${ADVANCED_FLOW:-$REALITY_FLOW_NONE}" || true)"
    fallback_limit_mode="${ADVANCED_FALLBACK_LIMIT_MODE:-off}"
    fallback_limit_upload="${ADVANCED_FALLBACK_LIMIT_UPLOAD_JSON:-null}"
    fallback_limit_download="${ADVANCED_FALLBACK_LIMIT_DOWNLOAD_JSON:-null}"

    tmp="$(config_temp_file "${ADVANCED_DRY_RUN:-false}")" || return 1
    if ! MSYS2_ENV_CONV_EXCL="*" ADVANCED_XHTTP_PATH="${ADVANCED_PATH:-}" ADVANCED_SPIDER_X="${ADVANCED_SPIDER_X:-/}" jq --arg tag "$tag" \
        --arg port "$ADVANCED_PORT" \
        --arg uuid "$ADVANCED_UUID" \
        --arg network "$network" \
        --arg sni "$ADVANCED_SERVER_NAME" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --arg min_client_ver "$REALITY_MIN_CLIENT_VERSION" \
        --arg flow "$flow" \
        --argjson short_ids "$REALITY_SHORT_IDS_JSON" \
        --arg decryption "${VLESS_DECRYPTION:-}" \
        --arg has_encryption "$(advanced_profile_has_encryption "$kind" && printf true || printf false)" \
        --arg has_xhttp "$(advanced_profile_has_xhttp "$kind" && printf true || printf false)" \
        --arg finalmask_enabled "$(advanced_profile_has_finalmask "$kind" && printf '%s' "${ADVANCED_FINALMASK_ENABLED:-false}" || printf false)" \
        --argjson finalmask_json "$finalmask_json" \
        --arg fallback_limit_mode "$fallback_limit_mode" \
        --argjson fallback_limit_upload "$fallback_limit_upload" \
        --argjson fallback_limit_download "$fallback_limit_download" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [({
          "tag": $tag,
          "listen": "0.0.0.0",
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              ({
                "id": $uuid,
                "email": "advanced@xray"
              } | if $flow != "" then .flow = $flow else . end)
            ],
            "decryption": (if $has_encryption == "true" then $decryption else "none" end)
          },
          "streamSettings": ({
            "network": $network,
            "security": "reality",
            "realitySettings": {
              "target": ($sni + ":443"),
              "show": false,
              "xver": 0,
              "minClientVer": $min_client_ver,
              "spiderX": env.ADVANCED_SPIDER_X,
              "shortIds": $short_ids,
              "privateKey": $private_key,
              "serverNames": [$sni]
            }
          } |
          if $has_xhttp == "true" then
            .xhttpSettings = {"path": env.ADVANCED_XHTTP_PATH}
          else . end |
          if $finalmask_enabled == "true" then
            .finalmask = $finalmask_json
          else . end |
          if $fallback_limit_mode == "conservative" then
            .realitySettings.limitFallbackUpload = $fallback_limit_upload |
            .realitySettings.limitFallbackDownload = $fallback_limit_download
          else . end),
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        })]
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[高级组合] jq 生成配置失败。"
        return 1
    fi

    if [[ "${ADVANCED_DRY_RUN:-false}" == "true" ]]; then
        write_test_config_out "$tmp" || {
            rm -f "$tmp"
            [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
            return 1
        }
        print_advanced_dry_run "$kind" "$tmp"
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[高级组合] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "$name"; then
        if advanced_profile_has_finalmask "$kind" && [[ "$ADVANCED_FINALMASK_ENABLED" == "true" ]]; then
            print_finalmask_failure_hint
        fi
        print_apply_failure_hint "$kind"
        return 1
    fi
    if ! state_set_advanced_profile "$kind"; then
        rollback_config_after_state_failure "$name"
        return 1
    fi
    state_set_meta_action "安装 ${name}" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${name} 已写入 Xray 配置。"
    print_advanced_profile_result "$kind"
}

print_advanced_profile_result() {
    local kind="$1"
    local missing_mode="${2:-skip}"
    local state_key state_exists link port uuid path encryption server_name public_key short_id spider_x fm_enabled fm_json endpoint_pair flow target
    local fallback_limit_mode fallback_limit_upload fallback_limit_download
    local fm_mode fm_preset fm_summary
    local address link_port name transport

    state_key="$(advanced_profile_state_key "$kind")" || return 1
    name="$(advanced_profile_name "$kind")" || return 1
    transport="$(advanced_profile_network "$kind" | tr '[:lower:]' '[:upper:]')"
    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[${name}] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${state_key}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[${name}] 未安装。"
        return 0
    fi

    link="$(build_advanced_share_link "$kind" || jq -r ".${state_key}.link // empty" "$STATE_FILE" 2>/dev/null)"
    port="$(jq -r ".${state_key}.port // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${state_key}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    path="$(jq -r ".${state_key}.path // empty" "$STATE_FILE" 2>/dev/null)"
    encryption="$(jq -r ".${state_key}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
    server_name="$(jq -r ".${state_key}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    public_key="$(jq -r ".${state_key}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
    short_id="$(jq -r ".${state_key}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
    spider_x="$(jq -r ".${state_key}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
    flow="$(jq -r ".${state_key}.flow // \"$REALITY_FLOW_NONE\"" "$STATE_FILE" 2>/dev/null)"
    fm_enabled="$(jq -r ".${state_key}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
    fm_mode="$(jq -r ".${state_key}.finalmask_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
    fm_preset="$(jq -r ".${state_key}.finalmask_preset // \"none\"" "$STATE_FILE" 2>/dev/null)"
    fm_summary="$(jq -r ".${state_key}.finalmask_summary // empty" "$STATE_FILE" 2>/dev/null)"
    fm_json="$(jq -c ".${state_key}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
    fallback_limit_mode="$(jq -r ".${state_key}.fallback_limit_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
    fallback_limit_upload="$(jq -c ".${state_key}.fallback_limit_upload // null" "$STATE_FILE" 2>/dev/null)"
    fallback_limit_download="$(jq -c ".${state_key}.fallback_limit_download // null" "$STATE_FILE" 2>/dev/null)"
    target=""
    [[ -n "$server_name" ]] && target="${server_name}:443"
    endpoint_pair="$(link_endpoint_for_tag "$port" "$(advanced_profile_tag "$kind")" "$state_key")"
    IFS=$'\t' read -r address link_port <<<"$endpoint_pair"

    echo -e "\n${YELLOW}--- ${name} ---${PLAIN}"
    echo -e "入口端口: ${port}"
    advanced_profile_has_xhttp "$kind" && echo -e "Path: ${path}"
    [[ -n "$target" ]] && echo -e "REALITY target: ${target}"
    echo -e "Flow: ${flow}"
    advanced_profile_has_fallback_limit "$kind" && echo -e "Fallback limit: ${fallback_limit_mode}"
    if advanced_profile_has_fallback_limit "$kind" && [[ "$fallback_limit_mode" == "conservative" ]]; then
        [[ -n "$fallback_limit_upload" && "$fallback_limit_upload" != "null" ]] && echo -e "Fallback upload: ${fallback_limit_upload}"
        [[ -n "$fallback_limit_download" && "$fallback_limit_download" != "null" ]] && echo -e "Fallback download: ${fallback_limit_download}"
    fi
    advanced_profile_has_finalmask "$kind" && echo -e "FinalMask: $([[ "$fm_enabled" == "true" ]] && printf on || printf 'off（未启用 FinalMask）')"
    if advanced_profile_has_finalmask "$kind"; then
        echo -e "FinalMask 模式: ${fm_mode}"
        echo -e "FinalMask 预设: ${fm_preset}"
        [[ -n "$fm_summary" ]] && echo -e "FinalMask 摘要: ${fm_summary}"
    fi
    [[ -n "$link" ]] && echo -e "VLESS URL: ${link}"
    if [[ "${CURRENT_LINK_VIEW_MODE:-dual}" == "ipv6" ]] && ! should_print_ipv6_link "ipv6" "$(advanced_profile_tag "$kind")" "$state_key"; then
        print_ipv6_status_hint "$(advanced_profile_tag "$kind")" "$state_key"
    fi
    if [[ ${#link} -gt 1800 ]]; then
        info "[高级组合] 链接较长，部分客户端可能需要手动填写参数。"
    fi
    echo "手动参数:"
    echo "  Protocol: VLESS"
    echo "  Transport: ${transport}"
    echo "  Security: REALITY"
    echo "  Address: ${address}"
    echo "  Port: ${link_port}"
    echo "  UUID: ${uuid}"
    echo "  Flow: ${flow}"
    advanced_profile_has_xhttp "$kind" && echo "  Path: ${path}"
    echo "  SNI: ${server_name}"
    echo "  PublicKey: ${public_key} (客户端字段)"
    echo "  ShortID: ${short_id}"
    advanced_profile_has_encryption "$kind" && echo "  VLESS Encryption: ${encryption}"
    advanced_profile_has_finalmask "$kind" && echo "  FinalMask: ${fm_enabled}"
    if advanced_profile_has_finalmask "$kind"; then
        echo "  FinalMask 模式: ${fm_mode}"
        echo "  FinalMask 预设: ${fm_preset}"
        [[ -n "$fm_summary" ]] && echo "  FinalMask 摘要: ${fm_summary}"
    fi
    if advanced_profile_has_finalmask "$kind" && [[ "$fm_enabled" == "true" && -n "$fm_json" && "$fm_json" != "null" ]]; then
        echo "  FinalMask JSON: ${fm_json}"
    fi
    echo "  Fingerprint: chrome"
    echo "  SpiderX: ${spider_x}"
    print_advanced_compat_hint "$kind"
}

remove_advanced_profile_config() {
    local kind="$1"
    local tag state_key name tmp

    tag="$(advanced_profile_tag "$kind")" || return 1
    state_key="$(advanced_profile_state_key "$kind")" || return 1
    name="$(advanced_profile_name "$kind")" || return 1

    [[ -f "$CONFIG_FILE" ]] || {
        info "[高级组合] 未找到配置文件，视为未安装。"
        state_delete_key "$state_key" || return 1
        return 0
    }
    backup_config || {
        err "[高级组合] 配置备份失败。"
        return 1
    }

    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[高级组合] jq 删除配置失败。"
        return 1
    fi
    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[高级组合] 写入 $CONFIG_FILE 失败。"
        return 1
    }
    apply_config "${name} 删除" || return 1
    if ! remove_state_key "$state_key"; then
        rollback_config_after_state_failure "${name} 删除"
        return 1
    fi
    state_set_meta_action "删除 ${name}" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${name} 已删除。"
}
