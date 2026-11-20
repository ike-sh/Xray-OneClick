#!/usr/bin/env bash
# VLESS Encryption protocol install.

ask_vless_auth() {
    echo -e "\n${YELLOW}[配置] VLESS Encryption 认证方式:${PLAIN}"
    echo -e "  1) X25519 ${GREEN}(推荐，链接更短)${PLAIN}"
    echo "  2) ML-KEM-768 (后量子认证，链接很长)"
    read -r -p "选项 (默认: 1): " V_AUTH_OPT
    case "${V_AUTH_OPT:-1}" in
        2) VLESS_AUTH="mlkem768" ;;
        *) VLESS_AUTH="x25519" ;;
    esac
}

configure_vless_advanced_options() {
    local enc_opt rtt_opt ticket_opt custom_ticket

    VLESS_MODE="advanced"

    # VLESS reverse/relay needs coordinated routing on both ends; do not fake one-click support here.
    echo -e "\n${YELLOW}[高级] VLESS Encryption 外观混淆方法:${PLAIN}"
    echo -e "  1) native ${GREEN}(默认，原始格式)${PLAIN}"
    echo "  2) xorpub (混淆公钥部分)"
    echo "  3) random (完整随机外观)"
    read -r -p "选项 (默认: 1): " enc_opt
    case "${enc_opt:-1}" in
        2) VLESS_ENC_METHOD="xorpub" ;;
        3) VLESS_ENC_METHOD="random" ;;
        *) VLESS_ENC_METHOD="native" ;;
    esac

    echo -e "\n${YELLOW}[高级] 客户端会话恢复:${PLAIN}"
    echo -e "  1) 0rtt ${GREEN}(默认，尝试快速恢复)${PLAIN}"
    echo "  2) 1rtt (强制完整握手)"
    read -r -p "选项 (默认: 1): " rtt_opt
    case "${rtt_opt:-1}" in
        2) VLESS_CLIENT_RTT="1rtt" ;;
        *) VLESS_CLIENT_RTT="0rtt" ;;
    esac

    echo -e "\n${YELLOW}[高级] 服务端 ticket 有效期:${PLAIN}"
    echo -e "  1) 600s ${GREEN}(默认)${PLAIN}"
    echo "  2) 300s"
    echo "  3) 自定义，例如 100-500s 或 900s"
    read -r -p "选项 (默认: 1): " ticket_opt
    case "${ticket_opt:-1}" in
        2) VLESS_SERVER_TICKET="300s" ;;
        3)
            read -r -p "请输入 ticket 有效期: " custom_ticket
            if [[ "$custom_ticket" =~ ^[0-9]+s$ || "$custom_ticket" =~ ^[0-9]+-[0-9]+s$ ]]; then
                VLESS_SERVER_TICKET="$custom_ticket"
            else
                info "[提示] 格式无效，使用默认 600s。"
                VLESS_SERVER_TICKET="600s"
            fi
            ;;
        *) VLESS_SERVER_TICKET="600s" ;;
    esac

    info "[提示] VLESS reverse/relay 等协议层能力当前脚本暂未暴露，请手动编辑 Xray 配置实现。"
}

configure_vless_encryption() {
    ensure_xray_vlessenc || return 1

    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"

    echo -e "\n${YELLOW}[配置] VLESS Encryption 配置模式:${PLAIN}"
    echo -e "  1) 基础模式 ${GREEN}(推荐，保持当前简单体验)${PLAIN}"
    echo "  2) 高级模式 (外观混淆、0-RTT/1-RTT、ticket 有效期)"
    read -r -p "选项 (默认: 1): " V_MODE_OPT || return 1
    [[ "${V_MODE_OPT:-1}" == "2" ]] && configure_vless_advanced_options

    ask_vless_auth || return 1

    ask_port "VLESS Encryption 端口" "8443" VLESS_PORT || return 1
    VLESS_LISTEN="0.0.0.0"
    VLESS_UUID="$(generate_uuid)" || return 1

    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
}

state_set_vless() {
    init_state || return 1
    local tmp
    tmp="$(state_temp_file)" || return 1
    if ! jq --arg tag "$VLESS_TAG" \
        --arg uuid "$VLESS_UUID" \
        --arg encryption "$VLESS_ENCRYPTION" \
        --arg auth "$VLESS_AUTH" \
        --arg mode "$VLESS_MODE" \
        --arg enc_method "$VLESS_ENC_METHOD" \
        --arg client_rtt "$VLESS_CLIENT_RTT" \
        --arg server_ticket "$VLESS_SERVER_TICKET" \
        --arg port "$VLESS_PORT" \
        --arg listen_scope "$(protocol_listen_scope "${VLESS_LISTEN:-}")" '
        .vless_encryption = {
          "tag": $tag,
          "uuid": $uuid,
          "encryption": $encryption,
          "auth": $auth,
          "mode": $mode,
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "port": ($port|tonumber),
          "listen_scope": $listen_scope
        }
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [VLESS Encryption] 生成状态文件失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [VLESS Encryption] 写入状态文件失败。"
        return 1
    fi
    rm -f "$tmp"
    ensure_config_security || return 1
}

install_vless_encryption() {
    if ! backup_config; then
        err "[失败] [VLESS Encryption] 配置备份失败。"
        return 1
    fi

    local tmp
    tmp="$(config_temp_file)" || {
        err "[失败] [VLESS Encryption] 创建临时文件失败。"
        return 1
    }
    if ! jq --arg tag "$VLESS_TAG" \
        --arg listen "$VLESS_LISTEN" \
        --arg port "$VLESS_PORT" \
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
                "email": "vless@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "tcp",
            "security": "none"
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        }]
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [VLESS Encryption] 生成配置失败。"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [VLESS Encryption] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
    rm -f "$tmp"

    apply_config || return 1
    if ! state_set_vless; then
        rollback_config_after_state_failure "VLESS Encryption"
        return 1
    fi
    state_set_meta_action "安装 VLESS Encryption" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption 已写入 Xray 配置。"
    view_config
}

# ---------------------------------------------------------------------------
# VLESS Encryption + FinalMask (sudoku) over plain TCP
# ---------------------------------------------------------------------------

build_finalmask_sudoku_json() {
    local password
    password="$(openssl rand -hex 16 2>/dev/null)"
    [[ -n "$password" ]] || password="$(generate_uuid | tr -d '-')"
    jq -cn --arg pw "$password" '{ tcp: [ { type: "sudoku", settings: { password: $pw, ascii: "prefer_ascii", paddingMin: 0, paddingMax: 3 } } ] }'
}

configure_vless_enc_finalmask() {
    local mode="${1:-interactive}"

    if [[ "$mode" != "dry-run" ]]; then
        ensure_xray_vlessenc || return 1
    fi

    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"
    VLESS_ENC_FM_LISTEN="0.0.0.0"

    if [[ "$mode" == "interactive" ]]; then
        ask_vless_auth
        ask_port "VLESS Encryption + FinalMask 端口" "8444" VLESS_ENC_FM_PORT
    else
        VLESS_AUTH="${VLESS_AUTH:-x25519}"
        if [[ -n "${VLESS_ENC_FM_PORT_REQUEST:-}" ]]; then
            validate_port "$VLESS_ENC_FM_PORT_REQUEST" || {
                err "[ENC-FinalMask] 端口无效: $VLESS_ENC_FM_PORT_REQUEST"
                return 1
            }
            if port_used_in_config "$VLESS_ENC_FM_PORT_REQUEST" || ! check_port "$VLESS_ENC_FM_PORT_REQUEST"; then
                err "[ENC-FinalMask] 端口已被占用或已存在于 config.json: $VLESS_ENC_FM_PORT_REQUEST"
                return 1
            fi
            VLESS_ENC_FM_PORT="$VLESS_ENC_FM_PORT_REQUEST"
        else
            VLESS_ENC_FM_PORT="8444"
        fi
    fi

    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
    VLESS_ENC_FM_JSON="$(build_finalmask_sudoku_json)" || return 1
}

build_vless_enc_finalmask_share_link() {
    local port="${VLESS_ENC_FM_PORT:-}"
    local uuid="${VLESS_UUID:-}"
    local encryption="${VLESS_ENCRYPTION:-}"
    local finalmask_json="${VLESS_ENC_FM_JSON:-}"
    local host link_port endpoint_pair enc_uri fm_uri name_uri

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        encryption="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
        finalmask_json="$(jq -c ".${VLESS_ENC_FM_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$uuid" && -n "$encryption" ]] || return 1
    endpoint_pair="$(link_endpoint_for_tag "$port" "$VLESS_ENC_FM_TAG" "$VLESS_ENC_FM_STATE_KEY")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    enc_uri="$(url_encode "$encryption")"
    name_uri="$(url_encode "Xray-ENC-FinalMask")"

    printf 'vless://%s@%s:%s?type=tcp&security=none&encryption=%s' \
        "$uuid" "$host" "$link_port" "$enc_uri"
    if [[ -n "$finalmask_json" && "$finalmask_json" != "null" ]]; then
        fm_uri="$(json_url_encode "$finalmask_json")" || return 1
        printf '&fm=%s' "$fm_uri"
    fi
    printf '#%s' "$name_uri"
}

state_set_vless_enc_finalmask() {
    init_state || return 1
    local tmp link timestamp
    link="$(build_vless_enc_finalmask_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(state_temp_file)" || return 1
    if ! jq --arg key "$VLESS_ENC_FM_STATE_KEY" \
        --arg tag "$VLESS_ENC_FM_TAG" \
        --arg uuid "$VLESS_UUID" \
        --arg encryption "$VLESS_ENCRYPTION" \
        --arg auth "$VLESS_AUTH" \
        --arg enc_method "$VLESS_ENC_METHOD" \
        --arg client_rtt "$VLESS_CLIENT_RTT" \
        --arg server_ticket "$VLESS_SERVER_TICKET" \
        --arg port "$VLESS_ENC_FM_PORT" \
        --argjson finalmask_json "${VLESS_ENC_FM_JSON:-null}" \
        --arg link "$link" \
        --arg updated "$timestamp" \
        --arg listen_scope "$(protocol_listen_scope "${VLESS_ENC_FM_LISTEN:-}")" '
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
          "finalmask_type": "sudoku",
          "finalmask_json": $finalmask_json,
          "link": $link,
          "listen_scope": $listen_scope,
          "updated_at": $updated
        }
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[状态] 生成 ENC-FinalMask 状态失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[状态] 写入 ENC-FinalMask 状态失败。"
        return 1
    fi
    ensure_config_security || return 1
}

install_vless_enc_finalmask() {
    local tmp config_source base_tmp

    config_source="$CONFIG_FILE"
    if [[ "${VLESS_ENC_FM_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${VLESS_ENC_FM_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[ENC-FinalMask] 配置备份失败。"
            return 1
        }
    fi

    tmp="$(config_temp_file "${VLESS_ENC_FM_DRY_RUN:-false}")" || return 1
    if ! jq --arg tag "$VLESS_ENC_FM_TAG" \
        --arg listen "${VLESS_ENC_FM_LISTEN:-0.0.0.0}" \
        --arg port "$VLESS_ENC_FM_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" \
        --argjson finalmask_json "${VLESS_ENC_FM_JSON:-null}" '
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
                "email": "tcp-finalmask@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "tcp",
            "security": "none",
            "finalmask": $finalmask_json
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        }]
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[ENC-FinalMask] jq 生成配置失败。"
        return 1
    fi

    if [[ "${VLESS_ENC_FM_DRY_RUN:-false}" == "true" ]]; then
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
        err "[ENC-FinalMask] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "VLESS Encryption + FinalMask"; then
        err "[ENC-FinalMask] 配置未通过 Xray 校验；sudoku FinalMask 需要较新的 Xray-core 支持。"
        return 1
    fi
    if ! state_set_vless_enc_finalmask; then
        rollback_config_after_state_failure "ENC-FinalMask"
        return 1
    fi
    state_set_meta_action "安装 VLESS Encryption + FinalMask" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption + FinalMask 已写入 Xray 配置。"
    print_vless_enc_finalmask_result
}

print_vless_enc_finalmask_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port uuid encryption auth

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[ENC-FinalMask] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[ENC-FinalMask] 未安装。"
        return 0
    fi

    port="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    encryption="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
    auth="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.auth // \"x25519\"" "$STATE_FILE" 2>/dev/null)"
    link="$(build_vless_enc_finalmask_share_link 2>/dev/null || jq -r ".${VLESS_ENC_FM_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"

    echo -e "\n${YELLOW}--- VLESS Encryption + FinalMask (sudoku) ---${PLAIN}"
    echo -e "端口: ${port}"
    echo -e "UUID: ${uuid}"
    echo -e "认证: ${auth}"
    echo -e "FinalMask: sudoku (tcp)"
    if [[ -z "$encryption" ]]; then
        err "[提示] 缺少客户端 encryption，无法生成完整链接。请重装该协议。"
    else
        echo -e "客户端 encryption: ${encryption}"
        [[ -n "$link" ]] && echo -e "链接: ${link}"
    fi
}
