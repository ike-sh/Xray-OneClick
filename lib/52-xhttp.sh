#!/usr/bin/env bash
# VLESS XHTTP + FinalMask protocol.

random_xhttp_path() {
    if command -v openssl >/dev/null 2>&1; then
        printf '/api/%s' "$(openssl rand -hex 8)"
    else
        printf '/api/test%s' "$RANDOM"
    fi
}

validate_xhttp_path() {
    local path="$1"

    [[ "$path" == /* ]] || return 1
    [[ "$path" != *" "* && "$path" != *"?"* && "$path" != *"#"* && "$path" != *"\\"* ]] || return 1
    [[ ${#path} -ge 2 && ${#path} -le 128 ]] || return 1
}

build_finalmask_preset_json() {
    local preset="${1:-balanced}"
    local length delay max_split

    case "$preset" in
        default) preset="balanced" ;;
    esac
    case "$preset" in
        conservative)
            length="120-240"
            delay="5-10"
            max_split="2-4"
            ;;
        balanced)
            length="100-200"
            delay="10-20"
            max_split="3-6"
            ;;
        aggressive)
            length="80-160"
            delay="10-30"
            max_split="4-8"
            ;;
        *)
            err "[FinalMask] 未知预设: $preset"
            return 1
            ;;
    esac
    build_finalmask_custom_json "tlshello" "$length" "$delay" "$max_split"
}

validate_finalmask_packets() {
    [[ "${1:-}" == "tlshello" ]]
}

validate_finalmask_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local start end

    [[ "$value" =~ ^[0-9]+(-[0-9]+)?$ ]] || return 1
    if [[ "$value" == *-* ]]; then
        start="${value%-*}"
        end="${value#*-}"
    else
        start="$value"
        end="$value"
    fi
    ((start <= end)) || return 1
    ((start >= min && end <= max))
}

build_finalmask_custom_json() {
    local packets="${1:-tlshello}"
    local length="${2:-100-200}"
    local delay="${3:-10-20}"
    local max_split="${4:-3-6}"

    validate_finalmask_packets "$packets" || {
        err "[FinalMask] packets 目前仅支持 tlshello。"
        return 1
    }
    validate_finalmask_range "$length" 1 1500 || {
        err "[FinalMask] length 必须是 1-1500 内的整数或 A-B 范围。"
        return 1
    }
    validate_finalmask_range "$delay" 0 1000 || {
        err "[FinalMask] delay 必须是 0-1000 内的整数或 A-B 范围。"
        return 1
    }
    validate_finalmask_range "$max_split" 1 20 || {
        err "[FinalMask] maxSplit 必须是 1-20 内的整数或 A-B 范围。"
        return 1
    }
    jq -cn --arg packets "$packets" --arg length "$length" --arg delay "$delay" --arg max_split "$max_split" '{
      tcp: [
        {
          type: "fragment",
          settings: {
            packets: $packets,
            length: $length,
            delay: $delay,
            maxSplit: $max_split
          }
        }
      ]
    }'
}

validate_finalmask_json() {
    local json="$1"

    [[ -n "$json" ]] || return 1
    jq -e 'type == "object" and ((has("tcp") | not) or (.tcp | type == "array"))' >/dev/null 2>&1 <<<"$json"
}

canonical_json() {
    jq -cS . 2>/dev/null <<<"$1"
}

finalmask_summary_from_json() {
    local json="$1"
    local summary

    summary="$(jq -r '
      if (.tcp? | type) == "array" and (.tcp[0]? // null) != null then
        (.tcp[0] | "fragment \(.settings.packets // "unknown") length=\(.settings.length // "unknown") delay=\(.settings.delay // "unknown") maxSplit=\(.settings.maxSplit // "unknown")")
      else
        "custom/raw-json"
      end
    ' 2>/dev/null <<<"$json")"
    printf '%s' "${summary:-custom/raw-json}"
}

detect_finalmask_preset() {
    local json="$1"
    local canon preset preset_json

    canon="$(canonical_json "$json" || true)"
    for preset in conservative balanced aggressive; do
        preset_json="$(build_finalmask_preset_json "$preset" 2>/dev/null || true)"
        if [[ -n "$canon" && "$canon" == "$(canonical_json "$preset_json" || true)" ]]; then
            printf '%s' "$preset"
            return 0
        fi
    done
    return 1
}

set_finalmask_metadata_from_json() {
    local json="$1"
    local mode_hint="${2:-auto}"
    local preset_hint="${3:-}"
    local detected

    FINALMASK_SUMMARY="$(finalmask_summary_from_json "$json")"
    if [[ "$mode_hint" == "preset" ]]; then
        FINALMASK_MODE="preset"
        FINALMASK_PRESET="${preset_hint:-balanced}"
    elif [[ "$mode_hint" == "custom" ]]; then
        FINALMASK_MODE="custom"
        FINALMASK_PRESET="custom"
    elif [[ "$mode_hint" == "raw-json" ]]; then
        FINALMASK_MODE="raw-json"
        FINALMASK_PRESET="raw-json"
    elif detected="$(detect_finalmask_preset "$json" 2>/dev/null)"; then
        FINALMASK_MODE="preset"
        FINALMASK_PRESET="$detected"
    else
        FINALMASK_MODE="raw-json"
        FINALMASK_PRESET="raw-json"
    fi
}

set_finalmask_metadata_from_requests() {
    local json="$1"
    local preset

    if [[ -n "${FINALMASK_JSON_REQUEST:-}" ]]; then
        set_finalmask_metadata_from_json "$json" "raw-json" "raw-json"
    elif [[ -n "${FINALMASK_PACKETS_REQUEST:-}${FINALMASK_LENGTH_REQUEST:-}${FINALMASK_DELAY_REQUEST:-}${FINALMASK_MAX_SPLIT_REQUEST:-}" ]]; then
        set_finalmask_metadata_from_json "$json" "custom" "custom"
    else
        preset="${FINALMASK_PRESET_REQUEST:-balanced}"
        [[ "$preset" == "default" ]] && preset="balanced"
        set_finalmask_metadata_from_json "$json" "preset" "$preset"
    fi
}

finalmask_extra_options_specified() {
    [[ -n "${FINALMASK_PRESET_REQUEST:-}" ||
        -n "${FINALMASK_JSON_REQUEST:-}" ||
        -n "${FINALMASK_PACKETS_REQUEST:-}" ||
        -n "${FINALMASK_LENGTH_REQUEST:-}" ||
        -n "${FINALMASK_DELAY_REQUEST:-}" ||
        -n "${FINALMASK_MAX_SPLIT_REQUEST:-}" ]]
}

build_finalmask_json() {
    local preset packets length delay max_split json

    if [[ -n "${FINALMASK_JSON_REQUEST:-}" ]]; then
        validate_finalmask_json "$FINALMASK_JSON_REQUEST" || {
            err "[FinalMask] --finalmask-json 不是可用的 FinalMask JSON。"
            return 1
        }
        json="$(jq -c . <<<"$FINALMASK_JSON_REQUEST")" || return 1
        set_finalmask_metadata_from_json "$json" "raw-json" "raw-json"
        printf '%s' "$json"
        return 0
    fi

    if [[ -n "${FINALMASK_PRESET_REQUEST:-}" ]] &&
        [[ -n "${FINALMASK_PACKETS_REQUEST:-}${FINALMASK_LENGTH_REQUEST:-}${FINALMASK_DELAY_REQUEST:-}${FINALMASK_MAX_SPLIT_REQUEST:-}" ]]; then
        err "[FinalMask] --finalmask-preset 不能和 --fm-* 自定义参数同时使用。"
        return 1
    fi

    if [[ -n "${FINALMASK_PACKETS_REQUEST:-}${FINALMASK_LENGTH_REQUEST:-}${FINALMASK_DELAY_REQUEST:-}${FINALMASK_MAX_SPLIT_REQUEST:-}" ]]; then
        packets="${FINALMASK_PACKETS_REQUEST:-tlshello}"
        length="${FINALMASK_LENGTH_REQUEST:-100-200}"
        delay="${FINALMASK_DELAY_REQUEST:-10-20}"
        max_split="${FINALMASK_MAX_SPLIT_REQUEST:-3-6}"
        json="$(build_finalmask_custom_json "$packets" "$length" "$delay" "$max_split")" || return 1
        set_finalmask_metadata_from_json "$json" "custom" "custom"
        printf '%s' "$json"
        return 0
    fi

    preset="${FINALMASK_PRESET_REQUEST:-balanced}"
    [[ "$preset" == "default" ]] && preset="balanced"
    json="$(build_finalmask_preset_json "$preset")" || return 1
    set_finalmask_metadata_from_json "$json" "preset" "$preset"
    printf '%s' "$json"
}

print_finalmask_summary() {
    local enabled="$1"
    local mode="$2"
    local preset="$3"
    local summary="$4"

    echo "FinalMask: $([[ "$enabled" == "true" ]] && printf on || printf off)"
    echo "FinalMask 模式: ${mode:-off}"
    echo "FinalMask 预设: ${preset:-none}"
    [[ -n "$summary" ]] && echo "FinalMask 摘要: ${summary}"
}

ask_finalmask_config() {
    local input packets length delay max_split raw_json

    echo -e "\n${YELLOW}[FinalMask] 选择参数模板:${PLAIN}"
    echo "  1) 保守 conservative：更稳，分片较轻"
    echo "  2) 均衡 balanced：默认推荐，当前实测模板"
    echo "  3) 激进 aggressive：混淆更强，可能影响速度和兼容性"
    echo "  4) 自定义参数 custom"
    echo "  5) 粘贴完整 JSON raw-json"
    read -r -p "选项 (默认: 2): " input

    FINALMASK_PRESET_REQUEST=""
    FINALMASK_JSON_REQUEST=""
    FINALMASK_PACKETS_REQUEST=""
    FINALMASK_LENGTH_REQUEST=""
    FINALMASK_DELAY_REQUEST=""
    FINALMASK_MAX_SPLIT_REQUEST=""

    case "${input:-2}" in
        1) FINALMASK_PRESET_REQUEST="conservative" ;;
        2) FINALMASK_PRESET_REQUEST="balanced" ;;
        3) FINALMASK_PRESET_REQUEST="aggressive" ;;
        4)
            while true; do
                read -r -p "packets (默认: tlshello): " packets
                packets="${packets:-tlshello}"
                validate_finalmask_packets "$packets" && break
                err "[FinalMask] packets 目前仅支持 tlshello。"
            done
            while true; do
                read -r -p "length 范围 (默认: 100-200): " length
                length="${length:-100-200}"
                validate_finalmask_range "$length" 1 1500 && break
                err "[FinalMask] length 必须是 1-1500 内的整数或 A-B 范围，且 A <= B。"
            done
            while true; do
                read -r -p "delay 范围 ms (默认: 10-20): " delay
                delay="${delay:-10-20}"
                validate_finalmask_range "$delay" 0 1000 && break
                err "[FinalMask] delay 必须是 0-1000 内的整数或 A-B 范围，且 A <= B。"
            done
            while true; do
                read -r -p "maxSplit 范围 (默认: 3-6): " max_split
                max_split="${max_split:-3-6}"
                validate_finalmask_range "$max_split" 1 20 && break
                err "[FinalMask] maxSplit 必须是 1-20 内的整数或 A-B 范围，且 A <= B。"
            done
            FINALMASK_PACKETS_REQUEST="$packets"
            FINALMASK_LENGTH_REQUEST="$length"
            FINALMASK_DELAY_REQUEST="$delay"
            FINALMASK_MAX_SPLIT_REQUEST="$max_split"
            ;;
        5)
            info "[FinalMask] 原始 JSON 属于高级功能，错误配置可能导致 Xray 校验失败，失败会自动回滚。"
            read -r -p "粘贴完整 FinalMask JSON: " raw_json
            FINALMASK_JSON_REQUEST="$raw_json"
            ;;
        *)
            err "[FinalMask] 无效选项。"
            return 1
            ;;
    esac
    build_finalmask_json >/dev/null
}

parse_finalmask_args() {
    local option="${1:-}"
    local value="${2:-}"

    FINALMASK_ARG_SHIFT=0
    case "$option" in
        --finalmask-preset)
            [[ -n "$value" ]] || {
                err "[FinalMask] --finalmask-preset 缺少值。"
                return 1
            }
            FINALMASK_PRESET_REQUEST="$value"
            FINALMASK_ARG_SHIFT=2
            ;;
        --fm-packets)
            [[ -n "$value" ]] || {
                err "[FinalMask] --fm-packets 缺少值。"
                return 1
            }
            FINALMASK_PACKETS_REQUEST="$value"
            FINALMASK_ARG_SHIFT=2
            ;;
        --fm-length)
            [[ -n "$value" ]] || {
                err "[FinalMask] --fm-length 缺少值。"
                return 1
            }
            FINALMASK_LENGTH_REQUEST="$value"
            FINALMASK_ARG_SHIFT=2
            ;;
        --fm-delay)
            [[ -n "$value" ]] || {
                err "[FinalMask] --fm-delay 缺少值。"
                return 1
            }
            FINALMASK_DELAY_REQUEST="$value"
            FINALMASK_ARG_SHIFT=2
            ;;
        --fm-max-split)
            [[ -n "$value" ]] || {
                err "[FinalMask] --fm-max-split 缺少值。"
                return 1
            }
            FINALMASK_MAX_SPLIT_REQUEST="$value"
            FINALMASK_ARG_SHIFT=2
            ;;
        --finalmask-json)
            [[ -n "$value" ]] || {
                err "[FinalMask] --finalmask-json 缺少值。"
                return 1
            }
            FINALMASK_JSON_REQUEST="$value"
            FINALMASK_ARG_SHIFT=2
            ;;
        *)
            return 2
            ;;
    esac
}

configure_vless_xhttp_finalmask() {
    local mode="${1:-interactive}"
    local input port

    if [[ "$mode" != "dry-run" ]]; then
        ensure_xray_vlessenc || return 1
    fi

    VLESS_MODE="${VLESS_MODE:-basic}"
    VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
    VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
    VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"
    VLESS_AUTH="${VLESS_AUTH:-x25519}"

    if [[ "$mode" == "interactive" ]]; then
        echo -e "\n${YELLOW}[配置] VLESS Encryption + XHTTP + FinalMask${PLAIN}"
        echo -e "  1) 基础模式 ${GREEN}(X25519/native/0rtt/600s)${PLAIN}"
        echo "  2) 高级模式 (认证、外观混淆、RTT、ticket)"
        read -r -p "选项 (默认: 1): " input
        if [[ "${input:-1}" == "2" ]]; then
            VLESS_MODE="advanced"
            configure_vless_advanced_options
        fi
        ask_vless_auth

        while true; do
            read -r -p "XHTTP 入口端口 (回车随机 20000-50000): " input
            if [[ -z "$input" ]]; then
                port="$(random_free_port 20000 50000)" || return 1
                info "[XHTTP] 随机选择端口: ${port}"
                XHTTP_PORT="$port"
                break
            fi
            if validate_port "$input" && ! port_used_in_config "$input" && check_port "$input"; then
                XHTTP_PORT="$input"
                break
            fi
            err "[XHTTP] 端口无效、被占用或已存在于 config.json。"
        done

        read -r -p "XHTTP path (回车随机): " input
        XHTTP_PATH="${input:-$(random_xhttp_path)}"
        info "[FinalMask] 属于高级兼容功能，客户端不兼容时请关闭。"
        read -r -p "开启 FinalMask? [y/N]: " input
        case "${input,,}" in
            y | yes) XHTTP_FINALMASK_ENABLED="true" ;;
            *) XHTTP_FINALMASK_ENABLED="false" ;;
        esac
        if [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]]; then
            ask_finalmask_config || return 1
        fi
    else
        if [[ -n "${XHTTP_PORT_REQUEST:-}" ]]; then
            validate_port "$XHTTP_PORT_REQUEST" || {
                err "[XHTTP] 端口无效: $XHTTP_PORT_REQUEST"
                return 1
            }
            if port_used_in_config "$XHTTP_PORT_REQUEST" || ! check_port "$XHTTP_PORT_REQUEST"; then
                err "[XHTTP] 端口已被占用或已存在于 config.json: $XHTTP_PORT_REQUEST"
                return 1
            fi
            XHTTP_PORT="$XHTTP_PORT_REQUEST"
        else
            XHTTP_PORT="$(random_free_port 20000 50000)" || return 1
        fi
        XHTTP_PATH="${XHTTP_PATH_REQUEST:-$(random_xhttp_path)}"
        XHTTP_FINALMASK_ENABLED="${XHTTP_FINALMASK_REQUEST:-false}"
    fi

    validate_xhttp_path "$XHTTP_PATH" || {
        err "[XHTTP] path 无效，必须以 / 开头，长度不超过 128，且不能包含空格、?、# 或反斜杠。"
        return 1
    }
    case "${XHTTP_FINALMASK_ENABLED,,}" in
        true | on | yes | y | 1) XHTTP_FINALMASK_ENABLED="true" ;;
        false | off | no | n | 0) XHTTP_FINALMASK_ENABLED="false" ;;
        *)
            err "[XHTTP] finalmask 参数必须为 on/off。"
            return 1
            ;;
    esac

    if [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]]; then
        XHTTP_FINALMASK_JSON="$(build_finalmask_json)" || return 1
        set_finalmask_metadata_from_requests "$XHTTP_FINALMASK_JSON"
        XHTTP_FINALMASK_MODE="$FINALMASK_MODE"
        XHTTP_FINALMASK_PRESET="$FINALMASK_PRESET"
        XHTTP_FINALMASK_SUMMARY="$FINALMASK_SUMMARY"
    else
        if finalmask_extra_options_specified; then
            info "[FinalMask] FinalMask 已关闭，忽略 FinalMask 参数。"
        fi
        XHTTP_FINALMASK_JSON=""
        XHTTP_FINALMASK_MODE="off"
        XHTTP_FINALMASK_PRESET="none"
        XHTTP_FINALMASK_SUMMARY="off"
    fi
    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
}

encode_finalmask_for_share_link() {
    local finalmask_json="$1"

    json_url_encode "$finalmask_json"
}

build_vless_xhttp_finalmask_share_link() {
    local port="${XHTTP_PORT:-}"
    local path="${XHTTP_PATH:-}"
    local uuid="${VLESS_UUID:-}"
    local encryption="${VLESS_ENCRYPTION:-}"
    local finalmask_enabled="${XHTTP_FINALMASK_ENABLED:-}"
    local finalmask_json="${XHTTP_FINALMASK_JSON:-}"
    local host link_port endpoint_pair enc_uri path_uri fm_uri name_uri

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        path="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        encryption="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
        finalmask_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        finalmask_json="$(jq -c ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$path" && -n "$uuid" && -n "$encryption" ]] || return 1
    endpoint_pair="$(link_endpoint_for_tag "$port" "$VLESS_XHTTP_FM_TAG" "$VLESS_XHTTP_FM_STATE_KEY")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    enc_uri="$(url_encode "$encryption")"
    path_uri="$(url_encode "$path")"
    name_uri="$(url_encode "Xray-XHTTP-FinalMask")"

    printf 'vless://%s@%s:%s?type=xhttp&security=none&path=%s&encryption=%s' \
        "$uuid" "$host" "$link_port" "$path_uri" "$enc_uri"
    if [[ "${finalmask_enabled,,}" == "true" && -n "$finalmask_json" && "$finalmask_json" != "null" ]]; then
        fm_uri="$(encode_finalmask_for_share_link "$finalmask_json")" || return 1
        printf '&fm=%s' "$fm_uri"
    fi
    printf '#%s' "$name_uri"
}

state_set_vless_xhttp_finalmask() {
    init_state || return 1
    local tmp link timestamp finalmask_json
    local finalmask_mode finalmask_preset finalmask_summary

    link="$(build_vless_xhttp_finalmask_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    finalmask_json="null"
    finalmask_mode="${XHTTP_FINALMASK_MODE:-off}"
    finalmask_preset="${XHTTP_FINALMASK_PRESET:-none}"
    finalmask_summary="${XHTTP_FINALMASK_SUMMARY:-off}"
    if [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]]; then
        finalmask_json="$XHTTP_FINALMASK_JSON"
        if [[ "$finalmask_mode" == "off" || "$finalmask_preset" == "none" || "$finalmask_summary" == "off" || -z "$finalmask_summary" ]]; then
            set_finalmask_metadata_from_json "$finalmask_json"
            finalmask_mode="$FINALMASK_MODE"
            finalmask_preset="$FINALMASK_PRESET"
            finalmask_summary="$FINALMASK_SUMMARY"
        fi
    fi

    tmp="$(state_temp_file)" || return 1
    if ! MSYS2_ENV_CONV_EXCL="XHTTP_JQ_VALUE" XHTTP_JQ_VALUE="$XHTTP_PATH" jq --arg port "$XHTTP_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" \
        --arg encryption "$VLESS_ENCRYPTION" \
        --arg auth "$VLESS_AUTH" \
        --arg enc_method "$VLESS_ENC_METHOD" \
        --arg client_rtt "$VLESS_CLIENT_RTT" \
        --arg server_ticket "$VLESS_SERVER_TICKET" \
        --arg finalmask_enabled "$XHTTP_FINALMASK_ENABLED" \
        --arg finalmask_mode "$finalmask_mode" \
        --arg finalmask_preset "$finalmask_preset" \
        --arg finalmask_summary "$finalmask_summary" \
        --argjson finalmask_json "$finalmask_json" \
        --arg listen_scope "ipv4" \
        --arg created_at "$timestamp" \
        --arg link "$link" '
        .vless_xhttp_finalmask = {
          "port": ($port|tonumber),
          "path": env.XHTTP_JQ_VALUE,
          "uuid": $uuid,
          "decryption": $decryption,
          "encryption": $encryption,
          "auth": $auth,
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "finalmask_enabled": ($finalmask_enabled == "true"),
          "finalmask_mode": $finalmask_mode,
          "finalmask_preset": $finalmask_preset,
          "finalmask_summary": $finalmask_summary,
          "finalmask_json": $finalmask_json,
          "listen_scope": $listen_scope,
          "created_at": $created_at,
          "link": $link
        }
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[状态] 生成 XHTTP-FinalMask 状态失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[状态] 写入 XHTTP-FinalMask 状态失败。"
        return 1
    fi
    ensure_config_security || return 1
}

print_xhttp_dry_run() {
    local temp_config="$1"
    local link fm_state

    link="$(build_vless_xhttp_finalmask_share_link || true)"
    fm_state="off"
    [[ "${XHTTP_FINALMASK_ENABLED:-false}" == "true" ]] && fm_state="on"
    echo -e "\n${YELLOW}XHTTP-FinalMask dry-run 预览${PLAIN}"
    echo "----------------------------------------"
    echo "入口端口: ${XHTTP_PORT}"
    echo "Path: ${XHTTP_PATH}"
    echo "FinalMask: ${fm_state}"
    if [[ "$fm_state" == "on" ]]; then
        echo "FinalMask 模式: ${XHTTP_FINALMASK_MODE:-preset}"
        echo "FinalMask 预设: ${XHTTP_FINALMASK_PRESET:-balanced}"
        echo "FinalMask 摘要: ${XHTTP_FINALMASK_SUMMARY:-}"
    fi
    [[ -n "$link" ]] && echo "Masked Link: $(mask_share_link "$link")"
    echo "将写入 inbound:"
    echo "- ${VLESS_XHTTP_FM_TAG}"
    jq empty "$temp_config" >/dev/null && echo "[✓] 临时 JSON 结构有效"
    xray_test_temp_config "$temp_config"
    echo "不会修改真实配置。"
}

install_vless_xhttp_finalmask() {
    local tmp finalmask_json config_source base_tmp

    config_source="$CONFIG_FILE"
    if [[ "${XHTTP_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${XHTTP_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[XHTTP] 配置备份失败。"
            return 1
        }
    fi
    finalmask_json="null"
    [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]] && finalmask_json="$XHTTP_FINALMASK_JSON"

    tmp="$(config_temp_file "${XHTTP_DRY_RUN:-false}")" || return 1
    if ! MSYS2_ENV_CONV_EXCL="XHTTP_JQ_VALUE" XHTTP_JQ_VALUE="$XHTTP_PATH" jq --arg tag "$VLESS_XHTTP_FM_TAG" \
        --arg port "$XHTTP_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" \
        --argjson finalmask_json "$finalmask_json" \
        --arg finalmask_enabled "$XHTTP_FINALMASK_ENABLED" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [({
          "tag": $tag,
          "listen": "0.0.0.0",
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "email": "xhttp-finalmask@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
              "path": env.XHTTP_JQ_VALUE
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        } | if $finalmask_enabled == "true" then
          .streamSettings.finalmask = $finalmask_json
        else
          .
        end)]
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[XHTTP] jq 生成配置失败。"
        return 1
    fi

    if [[ "${XHTTP_DRY_RUN:-false}" == "true" ]]; then
        write_test_config_out "$tmp" || {
            rm -f "$tmp"
            [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
            return 1
        }
        print_xhttp_dry_run "$tmp"
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[XHTTP] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "VLESS Encryption + XHTTP + FinalMask"; then
        if [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]]; then
            err "[XHTTP] FinalMask 模板未通过 Xray 校验，可使用 --finalmask off 重试。"
        fi
        print_xhttp_failure_hint
        return 1
    fi
    if ! state_set_vless_xhttp_finalmask; then
        rollback_config_after_state_failure "XHTTP-FinalMask"
        return 1
    fi
    state_set_meta_action "安装 VLESS Encryption + XHTTP + FinalMask" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption + XHTTP + FinalMask 已写入 Xray 配置。"
    print_vless_xhttp_finalmask_result
}

print_vless_xhttp_finalmask_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port path uuid encryption auth enc_method rtt ticket fm_enabled fm_json endpoint_pair
    local fm_mode fm_preset fm_summary
    local address link_port

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[XHTTP-FinalMask] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[XHTTP-FinalMask] 未安装。"
        return 0
    fi

    link="$(build_vless_xhttp_finalmask_share_link || jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    port="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    path="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    encryption="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
    auth="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
    enc_method="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.enc_method // empty" "$STATE_FILE" 2>/dev/null)"
    rtt="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.client_rtt // empty" "$STATE_FILE" 2>/dev/null)"
    ticket="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.server_ticket // empty" "$STATE_FILE" 2>/dev/null)"
    fm_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
    fm_mode="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
    fm_preset="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_preset // \"none\"" "$STATE_FILE" 2>/dev/null)"
    fm_summary="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_summary // empty" "$STATE_FILE" 2>/dev/null)"
    fm_json="$(jq -c ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
    endpoint_pair="$(link_endpoint_for_tag "$port" "$VLESS_XHTTP_FM_TAG" "$VLESS_XHTTP_FM_STATE_KEY")"
    IFS=$'\t' read -r address link_port <<<"$endpoint_pair"

    echo -e "\n${YELLOW}--- VLESS Encryption + XHTTP + FinalMask ---${PLAIN}"
    echo -e "入口端口: ${port}"
    echo -e "Path: ${path}"
    if [[ "$fm_enabled" == "true" ]]; then
        echo -e "FinalMask: on"
        echo -e "FinalMask 模式: ${fm_mode}"
        echo -e "FinalMask 预设: ${fm_preset}"
        [[ -n "$fm_summary" ]] && echo -e "FinalMask 摘要: ${fm_summary}"
    else
        echo -e "FinalMask: off（未启用 FinalMask）"
        echo -e "FinalMask 模式: off"
        echo -e "FinalMask 预设: none"
    fi
    [[ -n "$link" ]] && echo -e "VLESS URL: ${link}"
    if [[ "${CURRENT_LINK_VIEW_MODE:-dual}" == "ipv6" ]] && ! should_print_ipv6_link "ipv6" "$VLESS_XHTTP_FM_TAG" "$VLESS_XHTTP_FM_STATE_KEY"; then
        print_ipv6_status_hint "$VLESS_XHTTP_FM_TAG" "$VLESS_XHTTP_FM_STATE_KEY"
    fi
    if [[ ${#link} -gt 1800 ]]; then
        info "[XHTTP] FinalMask 链接较长，部分客户端可能需要手动填写参数。"
    fi
    echo "手动参数:"
    echo "  Protocol: VLESS"
    echo "  Transport: XHTTP"
    echo "  Security: none"
    echo "  Address: ${address}"
    echo "  Port: ${link_port}"
    echo "  UUID: ${uuid}"
    echo "  VLESS Encryption: ${encryption}"
    echo "  Path: ${path}"
    echo "  FinalMask: ${fm_enabled}"
    echo "  FinalMask 模式: ${fm_mode}"
    echo "  FinalMask 预设: ${fm_preset}"
    [[ -n "$fm_summary" ]] && echo "  FinalMask 摘要: ${fm_summary}"
    echo "  Auth: ${auth}"
    echo "  EncMethod: ${enc_method}"
    echo "  ClientRTT: ${rtt}"
    echo "  ServerTicket: ${ticket}"
    if [[ "$fm_enabled" == "true" && -n "$fm_json" && "$fm_json" != "null" ]]; then
        if [[ ${#fm_json} -gt 1200 ]]; then
            echo "  FinalMask JSON: 内容较长，可用 ike export clients 查看。"
        else
            echo "  FinalMask JSON: ${fm_json}"
        fi
    fi
    echo "兼容提示:"
    echo "  - XHTTP + FinalMask 需要较新的客户端核心。"
    echo "  - 如果导入失败，先尝试: ike xhttp install --finalmask off"
}

remove_vless_xhttp_finalmask_config() {
    local tmp

    [[ -f "$CONFIG_FILE" ]] || {
        info "[XHTTP] 未找到配置文件，视为未安装。"
        state_delete_key "$VLESS_XHTTP_FM_STATE_KEY" || return 1
        return 0
    }
    backup_config || {
        err "[XHTTP] 配置备份失败。"
        return 1
    }

    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$VLESS_XHTTP_FM_TAG" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag)))
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[XHTTP] jq 删除配置失败。"
        return 1
    fi
    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[XHTTP] 写入 $CONFIG_FILE 失败。"
        return 1
    }
    apply_config "VLESS XHTTP-FinalMask 删除" || return 1
    if ! state_delete_key "$VLESS_XHTTP_FM_STATE_KEY"; then
        rollback_config_after_state_failure "VLESS XHTTP-FinalMask 删除"
        return 1
    fi
    state_set_meta_action "删除 VLESS Encryption + XHTTP + FinalMask" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption + XHTTP + FinalMask 已删除。"
}

# ---------------------------------------------------------------------------
# VLESS Encryption + XHTTP (plain, no FinalMask / no REALITY)
# ---------------------------------------------------------------------------

configure_vless_enc_xhttp() {
    local mode="${1:-interactive}"
    local input port

    if [[ "$mode" != "dry-run" ]]; then
        ensure_xray_vlessenc || return 1
    fi

    VLESS_MODE="${VLESS_MODE:-basic}"
    VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
    VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
    VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"
    VLESS_AUTH="${VLESS_AUTH:-x25519}"
    ENC_XHTTP_LISTEN="0.0.0.0"

    if [[ "$mode" == "interactive" ]]; then
        ask_vless_auth
        while true; do
            read -r -p "XHTTP 入口端口 (回车随机 20000-50000): " input
            if [[ -z "$input" ]]; then
                port="$(random_free_port 20000 50000)" || return 1
                info "[XHTTP] 随机选择端口: ${port}"
                ENC_XHTTP_PORT="$port"
                break
            fi
            if validate_port "$input" && ! port_used_in_config "$input" && check_port "$input"; then
                ENC_XHTTP_PORT="$input"
                break
            fi
            err "[XHTTP] 端口无效、被占用或已存在于 config.json。"
        done
        read -r -p "XHTTP path (回车随机): " input
        ENC_XHTTP_PATH="${input:-$(random_xhttp_path)}"
    else
        if [[ -n "${ENC_XHTTP_PORT_REQUEST:-}" ]]; then
            validate_port "$ENC_XHTTP_PORT_REQUEST" || {
                err "[XHTTP] 端口无效: $ENC_XHTTP_PORT_REQUEST"
                return 1
            }
            if port_used_in_config "$ENC_XHTTP_PORT_REQUEST" || ! check_port "$ENC_XHTTP_PORT_REQUEST"; then
                err "[XHTTP] 端口已被占用或已存在于 config.json: $ENC_XHTTP_PORT_REQUEST"
                return 1
            fi
            ENC_XHTTP_PORT="$ENC_XHTTP_PORT_REQUEST"
        else
            ENC_XHTTP_PORT="$(random_free_port 20000 50000)" || return 1
        fi
        ENC_XHTTP_PATH="${ENC_XHTTP_PATH_REQUEST:-$(random_xhttp_path)}"
    fi

    validate_xhttp_path "$ENC_XHTTP_PATH" || {
        err "[XHTTP] path 无效，必须以 / 开头，长度不超过 128，且不能包含空格、?、# 或反斜杠。"
        return 1
    }

    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
}

build_vless_enc_xhttp_share_link() {
    local port="${ENC_XHTTP_PORT:-}"
    local path="${ENC_XHTTP_PATH:-}"
    local uuid="${VLESS_UUID:-}"
    local encryption="${VLESS_ENCRYPTION:-}"
    local host link_port endpoint_pair enc_uri path_uri name_uri

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        path="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        encryption="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$path" && -n "$uuid" && -n "$encryption" ]] || return 1
    endpoint_pair="$(link_endpoint_for_tag "$port" "$VLESS_ENC_XHTTP_TAG" "$VLESS_ENC_XHTTP_STATE_KEY")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    enc_uri="$(url_encode "$encryption")"
    path_uri="$(url_encode "$path")"
    name_uri="$(url_encode "Xray-ENC-XHTTP")"

    printf 'vless://%s@%s:%s?type=xhttp&security=none&path=%s&encryption=%s#%s' \
        "$uuid" "$host" "$link_port" "$path_uri" "$enc_uri" "$name_uri"
}

state_set_vless_enc_xhttp() {
    init_state || return 1
    local tmp link timestamp
    link="$(build_vless_enc_xhttp_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(state_temp_file)" || return 1
    if ! jq --arg key "$VLESS_ENC_XHTTP_STATE_KEY" \
        --arg tag "$VLESS_ENC_XHTTP_TAG" \
        --arg uuid "$VLESS_UUID" \
        --arg encryption "$VLESS_ENCRYPTION" \
        --arg auth "$VLESS_AUTH" \
        --arg enc_method "$VLESS_ENC_METHOD" \
        --arg client_rtt "$VLESS_CLIENT_RTT" \
        --arg server_ticket "$VLESS_SERVER_TICKET" \
        --arg port "$ENC_XHTTP_PORT" \
        --arg path "$ENC_XHTTP_PATH" \
        --arg link "$link" \
        --arg updated "$timestamp" \
        --arg listen_scope "$(protocol_listen_scope "${ENC_XHTTP_LISTEN:-}")" '
        .[$key] = {
          "tag": $tag,
          "uuid": $uuid,
          "encryption": $encryption,
          "auth": $auth,
          "mode": "basic",
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "port": ($port|tonumber),
          "path": $path,
          "link": $link,
          "listen_scope": $listen_scope,
          "updated_at": $updated
        }
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[状态] 生成 ENC-XHTTP 状态失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[状态] 写入 ENC-XHTTP 状态失败。"
        return 1
    fi
    ensure_config_security || return 1
}

install_vless_enc_xhttp() {
    local tmp config_source base_tmp

    config_source="$CONFIG_FILE"
    if [[ "${ENC_XHTTP_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${ENC_XHTTP_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[ENC-XHTTP] 配置备份失败。"
            return 1
        }
    fi

    tmp="$(config_temp_file "${ENC_XHTTP_DRY_RUN:-false}")" || return 1
    if ! MSYS2_ENV_CONV_EXCL="ENC_XHTTP_JQ_PATH" ENC_XHTTP_JQ_PATH="$ENC_XHTTP_PATH" jq --arg tag "$VLESS_ENC_XHTTP_TAG" \
        --arg listen "${ENC_XHTTP_LISTEN:-0.0.0.0}" \
        --arg port "$ENC_XHTTP_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "email": "enc-xhttp@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
              "path": env.ENC_XHTTP_JQ_PATH
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        }]
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[ENC-XHTTP] jq 生成配置失败。"
        return 1
    fi

    if [[ "${ENC_XHTTP_DRY_RUN:-false}" == "true" ]]; then
        write_test_config_out "$tmp" || {
            rm -f "$tmp"
            [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
            return 1
        }
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[ENC-XHTTP] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "VLESS Encryption + XHTTP"; then
        print_xhttp_failure_hint
        return 1
    fi
    if ! state_set_vless_enc_xhttp; then
        rollback_config_after_state_failure "ENC-XHTTP"
        return 1
    fi
    state_set_meta_action "安装 VLESS Encryption + XHTTP" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption + XHTTP 已写入 Xray 配置。"
    print_vless_enc_xhttp_result
}

print_vless_enc_xhttp_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port path uuid encryption auth

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[ENC-XHTTP] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[ENC-XHTTP] 未安装。"
        return 0
    fi

    port="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    path="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    encryption="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
    auth="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.auth // \"x25519\"" "$STATE_FILE" 2>/dev/null)"
    link="$(build_vless_enc_xhttp_share_link 2>/dev/null || jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"

    echo -e "\n${YELLOW}--- VLESS Encryption + XHTTP ---${PLAIN}"
    echo -e "端口: ${port}"
    echo -e "Path: ${path}"
    echo -e "UUID: ${uuid}"
    echo -e "认证: ${auth}"
    if [[ -z "$encryption" ]]; then
        err "[提示] 缺少客户端 encryption，无法生成完整链接。请重装该协议。"
    else
        echo -e "客户端 encryption: ${encryption}"
        [[ -n "$link" ]] && echo -e "链接: ${link}"
    fi
}
