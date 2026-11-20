#!/usr/bin/env bash
# View config links, reset secrets, uninstall helpers.

view_config() {
    local mode="${1:-$LINK_VIEW_MODE}"
    local detail="${2:-quick}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "错误：未找到配置文件，请先安装协议。"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        err "错误：缺少 jq，无法读取配置。"
        return 1
    fi

    get_public_addresses
    host_candidates "$mode"
    CURRENT_LINK_VIEW_MODE="$mode"

    echo -e "\n${GREEN}========= 当前 Xray 配置信息 =========${PLAIN}"
    if [[ "$detail" == "doctor" ]]; then
        echo -e "查看模式: ${YELLOW}完整诊断${PLAIN}"
    else
        echo -e "查看模式: ${YELLOW}快速${PLAIN} (${GREEN}完整诊断: ike view doctor${PLAIN})"
    fi
    echo -e "链接显示模式: ${YELLOW}${mode}${PLAIN}"
    echo -e "最近变更: ${YELLOW}$(state_meta_value last_action)${PLAIN}"
    echo -e "最近更新时间: ${YELLOW}$(state_meta_value last_updated_at)${PLAIN}"
    if [[ -n "$(endpoint_custom_value)" ]]; then
        echo -e "连接 endpoint: ${YELLOW}$(endpoint_custom_value)${PLAIN}"
    else
        echo -e "连接 endpoint: ${YELLOW}自动检测，Tunnel 可用 ike endpoint set 自定义${PLAIN}"
    fi
    echo -e "默认安全屏蔽: ${YELLOW}$(default_safety_block_status)${PLAIN}"
    echo -e "默认私网规则: ${YELLOW}$(default_private_block_mode)${PLAIN}"
    echo -e "增强安全屏蔽: ${YELLOW}$(enhanced_safety_block_status)${PLAIN}"
    echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
    echo -e "Tunnel 中转: ${YELLOW}$(forward_rule_count) 条${PLAIN}"
    if [[ "$detail" == "doctor" ]]; then
        echo -e "geoip.dat: ${YELLOW}$(resource_file_status "$ASSET_DIR/geoip.dat")${PLAIN}"
        echo -e "geosite.dat: ${YELLOW}$(resource_file_status "$ASSET_DIR/geosite.dat")${PLAIN}"
        echo -e "Xray 配置校验: ${YELLOW}$(xray_config_test_status)${PLAIN}"
        echo -e "Xray 服务状态: ${YELLOW}$(xray_service_status)${PLAIN}"
        [[ -n "$PUBLIC_IPV4" ]] && echo -e "公网 IPv4: ${PUBLIC_IPV4}"
        [[ -n "$PUBLIC_IPV6" ]] && echo -e "公网 IPv6: ${PUBLIC_IPV6}"
        echo -e "已安装协议: ${YELLOW}$(installed_protocols_summary)${PLAIN}"
        list_forward_rules
        show_footer
        return 0
    elif [[ -z "$IPV4_HOST" && -z "$IPV6_HOST" ]]; then
        info "[提示] 未检测到公网地址，请使用 ike endpoint set 手动设置连接入口。"
    fi

    local ss_in ssp ssw ssm user_info
    ss_in="$(jq -c --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$ss_in" ]]; then
        ssp="$(echo "$ss_in" | jq -r '.port')"
        ssw="$(echo "$ss_in" | jq -r '.settings.password')"
        ssm="$(echo "$ss_in" | jq -r '.settings.method')"
        user_info="$(printf '%s' "${ssm}:${ssw}" | b64_url_no_pad)"

        echo -e "\n${YELLOW}--- Shadowsocks 2022 ---${PLAIN}"
        echo -e "端口: ${ssp}"
        echo -e "加密: ${ssm}"
        echo -e "密码: ${ssw}"
        [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: ss://${user_info}@${IPV4_HOST}:${ssp}#SS2022-IPv4"
        if should_print_ipv6_link "$mode" "$SS_TAG" "ss2022"; then
            echo -e "IPv6链接: ss://${user_info}@${IPV6_HOST}:${ssp}#SS2022-IPv6"
        elif [[ "$mode" == "ipv6" ]]; then
            print_ipv6_status_hint "$SS_TAG" "ss2022"
        fi
    fi

    local vless_in vp vu venc vmode vmethod vrtt vticket venc_uri
    vless_in="$(jq -c --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$vless_in" ]]; then
        vp="$(echo "$vless_in" | jq -r '.port')"
        vu="$(echo "$vless_in" | jq -r '.settings.clients[0].id')"
        venc="$(jq -r '.vless_encryption.encryption // empty' "$STATE_FILE" 2>/dev/null)"
        vmode="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
        vmethod="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
        vrtt="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
        vticket="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"

        echo -e "\n${YELLOW}--- VLESS Encryption ---${PLAIN}"
        echo -e "端口: ${vp}"
        echo -e "UUID: ${vu}"
        echo -e "模式: ${vmode}"
        echo -e "外观混淆: ${vmethod}"
        echo -e "客户端握手: ${vrtt}"
        echo -e "服务端 ticket: ${vticket}"
        if [[ -z "$venc" ]]; then
            err "[提示] 缺少客户端 encryption，无法生成完整 VLESS 链接。请重新安装或重置 VLESS Encryption。"
        else
            echo -e "客户端 encryption: ${venc}"
            venc_uri="$(url_encode "$venc")"
            [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: vless://${vu}@${IPV4_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv4"
            if should_print_ipv6_link "$mode" "$VLESS_TAG" "vless_encryption"; then
                echo -e "IPv6链接: vless://${vu}@${IPV6_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv6"
            elif [[ "$mode" == "ipv6" ]]; then
                print_ipv6_status_hint "$VLESS_TAG" "vless_encryption"
            fi
        fi
    fi

    print_reality_result
    print_vless_xhttp_finalmask_result
    print_vless_enc_finalmask_result
    print_vless_enc_xhttp_result
    print_advanced_profile_result "xhttp-reality"
    print_advanced_profile_result "enc-reality"
    print_advanced_profile_result "fullstack"
    print_hysteria2_result

    local socks_in sp su sw
    socks_in="$(jq -c --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$socks_in" ]]; then
        sp="$(echo "$socks_in" | jq -r '.port')"
        su="$(echo "$socks_in" | jq -r '.settings.accounts[0].user')"
        sw="$(echo "$socks_in" | jq -r '.settings.accounts[0].pass')"

        echo -e "\n${YELLOW}--- SOCKS5 ---${PLAIN}"
        echo -e "端口: ${sp}"
        echo -e "用户: ${su}"
        echo -e "密码: ${sw}"
        [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: socks5://${su}:${sw}@${IPV4_HOST}:${sp}"
        if should_print_ipv6_link "$mode" "$SOCKS_TAG" "socks5"; then
            echo -e "IPv6链接: socks5://${su}:${sw}@${IPV6_HOST}:${sp}"
        elif [[ "$mode" == "ipv6" ]]; then
            print_ipv6_status_hint "$SOCKS_TAG" "socks5"
        fi
    fi

    show_footer
}

set_link_view_mode() {
    echo -e "\n${YELLOW}[设置] 链接显示模式${PLAIN}"
    echo " 1) 双栈 (IPv4 + IPv6)"
    echo " 2) 仅 IPv4"
    echo " 3) 仅 IPv6"
    read -r -p "选项 (默认: 1): " MODE_OPT

    case "${MODE_OPT:-1}" in
        1) LINK_VIEW_MODE="dual" ;;
        2) LINK_VIEW_MODE="ipv4" ;;
        3) LINK_VIEW_MODE="ipv6" ;;
        *) LINK_VIEW_MODE="dual" ;;
    esac

    ok "[完成] 当前链接显示模式: ${LINK_VIEW_MODE}"
}

_reset_inbound_present() {
    jq -e --arg tag "$1" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

_reset_any_vlessenc_present() {
    local tag
    for tag in "$VLESS_TAG" "$VLESS_ENC_FM_TAG" "$VLESS_ENC_XHTTP_TAG" \
        "$VLESS_XHTTP_FM_TAG" "$VLESS_ENC_REALITY_TAG" "$VLESS_FULLSTACK_TAG"; do
        _reset_inbound_present "$tag" && return 0
    done
    return 1
}

# Rotate UUID + Encryption for VLESS Encryption + FinalMask (sudoku/TCP).
# Returns 0 when rotated, 2 when not installed, 1 on error.
reset_vless_enc_finalmask_secret() {
    _reset_inbound_present "$VLESS_ENC_FM_TAG" || {
        info "[跳过] 未找到 VLESS Encryption + FinalMask 入站。"
        return 2
    }
    local listen tmp
    VLESS_AUTH="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.auth // \"x25519\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_ENC_METHOD="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.enc_method // \"native\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_CLIENT_RTT="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.client_rtt // \"0rtt\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_SERVER_TICKET="$(jq -r ".${VLESS_ENC_FM_STATE_KEY}.server_ticket // \"600s\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_ENC_FM_PORT="$(jq -r --arg tag "$VLESS_ENC_FM_TAG" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE" 2>/dev/null)"
    VLESS_ENC_FM_JSON="$(jq -c ".${VLESS_ENC_FM_STATE_KEY}.finalmask_json // null" "$STATE_FILE" 2>/dev/null)"
    listen="$(jq -r --arg tag "$VLESS_ENC_FM_TAG" '.inbounds[] | select(.tag == $tag).listen // "0.0.0.0"' "$CONFIG_FILE" 2>/dev/null)"
    VLESS_ENC_FM_LISTEN="${listen:-0.0.0.0}"
    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$VLESS_ENC_FM_TAG" --arg uuid "$VLESS_UUID" --arg decryption "$VLESS_DECRYPTION" '
        (.inbounds[] | select(.tag == $tag).settings.clients[0].id) = $uuid |
        (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    state_set_vless_enc_finalmask || return 1
    ok "[完成] VLESS Encryption + FinalMask 的 UUID 与 Encryption 已重置。"
    return 0
}

# Rotate UUID + Encryption for VLESS Encryption + XHTTP.
reset_vless_enc_xhttp_secret() {
    _reset_inbound_present "$VLESS_ENC_XHTTP_TAG" || {
        info "[跳过] 未找到 VLESS Encryption + XHTTP 入站。"
        return 2
    }
    local listen tmp
    VLESS_AUTH="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.auth // \"x25519\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_ENC_METHOD="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.enc_method // \"native\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_CLIENT_RTT="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.client_rtt // \"0rtt\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_SERVER_TICKET="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.server_ticket // \"600s\"" "$STATE_FILE" 2>/dev/null)"
    ENC_XHTTP_PORT="$(jq -r --arg tag "$VLESS_ENC_XHTTP_TAG" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE" 2>/dev/null)"
    ENC_XHTTP_PATH="$(jq -r ".${VLESS_ENC_XHTTP_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
    listen="$(jq -r --arg tag "$VLESS_ENC_XHTTP_TAG" '.inbounds[] | select(.tag == $tag).listen // "0.0.0.0"' "$CONFIG_FILE" 2>/dev/null)"
    ENC_XHTTP_LISTEN="${listen:-0.0.0.0}"
    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$VLESS_ENC_XHTTP_TAG" --arg uuid "$VLESS_UUID" --arg decryption "$VLESS_DECRYPTION" '
        (.inbounds[] | select(.tag == $tag).settings.clients[0].id) = $uuid |
        (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    state_set_vless_enc_xhttp || return 1
    ok "[完成] VLESS Encryption + XHTTP 的 UUID 与 Encryption 已重置。"
    return 0
}

# Rotate UUID + Encryption for VLESS Encryption + XHTTP + FinalMask.
reset_vless_xhttp_finalmask_secret() {
    _reset_inbound_present "$VLESS_XHTTP_FM_TAG" || {
        info "[跳过] 未找到 VLESS Encryption + XHTTP + FinalMask 入站。"
        return 2
    }
    local tmp
    VLESS_AUTH="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.auth // \"x25519\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_ENC_METHOD="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.enc_method // \"native\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_CLIENT_RTT="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.client_rtt // \"0rtt\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_SERVER_TICKET="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.server_ticket // \"600s\"" "$STATE_FILE" 2>/dev/null)"
    XHTTP_PORT="$(jq -r --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE" 2>/dev/null)"
    XHTTP_PATH="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
    XHTTP_FINALMASK_ENABLED="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
    XHTTP_FINALMASK_JSON="$(jq -c ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json // null" "$STATE_FILE" 2>/dev/null)"
    XHTTP_FINALMASK_MODE="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
    XHTTP_FINALMASK_PRESET="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_preset // \"none\"" "$STATE_FILE" 2>/dev/null)"
    XHTTP_FINALMASK_SUMMARY="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_summary // \"off\"" "$STATE_FILE" 2>/dev/null)"
    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$VLESS_XHTTP_FM_TAG" --arg uuid "$VLESS_UUID" --arg decryption "$VLESS_DECRYPTION" '
        (.inbounds[] | select(.tag == $tag).settings.clients[0].id) = $uuid |
        (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    state_set_vless_xhttp_finalmask || return 1
    ok "[完成] VLESS Encryption + XHTTP + FinalMask 的 UUID 与 Encryption 已重置。"
    return 0
}

# Rotate UUID + REALITY keypair for standalone VLESS TCP REALITY (short IDs preserved).
reset_reality_secret() {
    _reset_inbound_present "$REALITY_TAG" || {
        info "[跳过] 未找到 VLESS TCP REALITY 入站。"
        return 2
    }
    local tmp
    REALITY_PORT="$(jq -r ".${REALITY_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    REALITY_DEFENDER_PORT="$(jq -r ".${REALITY_STATE_KEY}.defender_port // empty" "$STATE_FILE" 2>/dev/null)"
    REALITY_SERVER_NAME="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    REALITY_SPIDER_X="$(jq -r ".${REALITY_STATE_KEY}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
    REALITY_FLOW="$(jq -r ".${REALITY_STATE_KEY}.flow // \"$REALITY_FLOW_DEFAULT\"" "$STATE_FILE" 2>/dev/null)"
    REALITY_DEFAULT_SHORT_ID="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
    REALITY_SHORT_IDS_JSON="$(jq -c ".${REALITY_STATE_KEY}.short_ids // []" "$STATE_FILE" 2>/dev/null)"
    REALITY_EMPTY_CLIENTS="$(jq -r ".${REALITY_STATE_KEY}.empty_clients // false" "$STATE_FILE" 2>/dev/null)"
    REALITY_UUID="$(generate_uuid)" || return 1
    generate_reality_keys || return 1
    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$REALITY_TAG" --arg uuid "$REALITY_UUID" --arg pk "$REALITY_PRIVATE_KEY" '
        (.inbounds[] | select(.tag == $tag).streamSettings.realitySettings.privateKey) = $pk |
        (.inbounds[] | select(.tag == $tag) | select((.settings.clients | length) > 0).settings.clients[0].id) = $uuid
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    state_set_reality || return 1
    ok "[完成] VLESS TCP REALITY 的 UUID 与 REALITY 密钥对已重置。"
    return 0
}

# Rotate secrets for an advanced combo profile (xhttp-reality / enc-reality / fullstack).
# REALITY keypair + UUID always rotated; VLESS Encryption rotated when the profile uses it.
# Short IDs, path, SNI, flow and FinalMask settings are preserved.
reset_advanced_secret() {
    local kind="$1"
    local tag state_key tmp has_enc
    tag="$(advanced_profile_tag "$kind")" || return 1
    state_key="$(advanced_profile_state_key "$kind")" || return 1
    _reset_inbound_present "$tag" || {
        info "[跳过] 未找到 $(advanced_profile_name "$kind") 入站。"
        return 2
    }

    ADVANCED_PORT="$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE" 2>/dev/null)"
    ADVANCED_PATH="$(jq -r ".${state_key}.path // empty" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_SERVER_NAME="$(jq -r ".${state_key}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_SPIDER_X="$(jq -r ".${state_key}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FLOW="$(jq -r ".${state_key}.flow // \"$REALITY_FLOW_NONE\"" "$STATE_FILE" 2>/dev/null)"
    REALITY_DEFAULT_SHORT_ID="$(jq -r ".${state_key}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
    REALITY_SHORT_IDS_JSON="$(jq -c ".${state_key}.short_ids // []" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FALLBACK_LIMIT_MODE="$(jq -r ".${state_key}.fallback_limit_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FALLBACK_LIMIT_UPLOAD_JSON="$(jq -c ".${state_key}.fallback_limit_upload // null" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FALLBACK_LIMIT_DOWNLOAD_JSON="$(jq -c ".${state_key}.fallback_limit_download // null" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FINALMASK_ENABLED="$(jq -r ".${state_key}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FINALMASK_JSON="$(jq -c ".${state_key}.finalmask_json // null" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FINALMASK_MODE="$(jq -r ".${state_key}.finalmask_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FINALMASK_PRESET="$(jq -r ".${state_key}.finalmask_preset // \"none\"" "$STATE_FILE" 2>/dev/null)"
    ADVANCED_FINALMASK_SUMMARY="$(jq -r ".${state_key}.finalmask_summary // \"off\"" "$STATE_FILE" 2>/dev/null)"

    ADVANCED_UUID="$(generate_uuid)" || return 1
    generate_reality_keys || return 1

    has_enc="false"
    if advanced_profile_has_encryption "$kind"; then
        has_enc="true"
        VLESS_AUTH="$(jq -r ".${state_key}.auth // \"x25519\"" "$STATE_FILE" 2>/dev/null)"
        VLESS_ENC_METHOD="$(jq -r ".${state_key}.enc_method // \"native\"" "$STATE_FILE" 2>/dev/null)"
        VLESS_CLIENT_RTT="$(jq -r ".${state_key}.client_rtt // \"0rtt\"" "$STATE_FILE" 2>/dev/null)"
        VLESS_SERVER_TICKET="$(jq -r ".${state_key}.server_ticket // \"600s\"" "$STATE_FILE" 2>/dev/null)"
        generate_vless_encryption_pair "$VLESS_AUTH" || return 1
    else
        VLESS_DECRYPTION=""
        VLESS_ENCRYPTION=""
    fi

    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$tag" --arg uuid "$ADVANCED_UUID" --arg pk "$REALITY_PRIVATE_KEY" \
        --arg has_enc "$has_enc" --arg decryption "${VLESS_DECRYPTION:-}" '
        (.inbounds[] | select(.tag == $tag).streamSettings.realitySettings.privateKey) = $pk |
        (.inbounds[] | select(.tag == $tag) | select((.settings.clients | length) > 0).settings.clients[0].id) = $uuid |
        if $has_enc == "true" then
          (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption
        else . end
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    state_set_advanced_profile "$kind" || return 1
    ok "[完成] $(advanced_profile_name "$kind") 的 UUID 与密钥已重置。"
    return 0
}

jq_config_update() {
    local tmp

    tmp="$(mktemp "${CONFIG_FILE}.next.XXXXXX")" || return 1
    if ! jq "$@" "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

discard_secret_reset_working_copy() {
    local real_config="$1" real_state="$2" working_config="$3" working_state="$4"
    local config_snapshot="$5" state_snapshot="$6"

    CONFIG_FILE="$real_config"
    STATE_FILE="$real_state"
    rm -f "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
}

restore_secret_reset_snapshots() {
    local config_snapshot="$1" state_snapshot="$2"
    local restored="true"

    cp -a "$config_snapshot" "$CONFIG_FILE" || restored="false"
    cp -a "$state_snapshot" "$STATE_FILE" || restored="false"
    ensure_config_security || restored="false"
    [[ "$restored" == "true" ]]
}

reset_secrets() {
    install_or_update_xray || return 1
    [[ -f "$CONFIG_FILE" ]] || {
        err "[错误] 未找到配置文件。"
        return 1
    }

    echo -e "\n${YELLOW}[维护] 重置密钥/密码（端口不变）${PLAIN}"
    echo " 1) 重置 SS2022 密码"
    echo " 2) 重置全部 VLESS / REALITY 系列 UUID 与密钥"
    echo " 3) 重置 SOCKS5 密码"
    echo " 4) 一键重置全部"
    read -r -p "选项: " R_OPT
    case "$R_OPT" in
        1 | 2 | 3 | 4) ;;
        *)
            err "[错误] 未知选项: ${R_OPT:-空}"
            return 1
            ;;
    esac

    init_state || return 1
    if [[ "$R_OPT" == "2" || "$R_OPT" == "4" ]] && _reset_any_vlessenc_present; then
        ensure_xray_vlessenc || return 1
    fi
    if ! backup_config; then
        err "[失败] 重置前配置备份失败。"
        return 1
    fi

    local real_config real_state working_config working_state config_snapshot state_snapshot
    local changed current_method current_port current_auth rc resetter argument
    real_config="$CONFIG_FILE"
    real_state="$STATE_FILE"
    working_config="$(mktemp "${real_config}.reset-new.XXXXXX")" || return 1
    working_state="$(mktemp "${real_state}.reset-new.XXXXXX")" || {
        rm -f "$working_config"
        return 1
    }
    config_snapshot="$(mktemp "${real_config}.reset-old.XXXXXX")" || {
        rm -f "$working_config" "$working_state"
        return 1
    }
    state_snapshot="$(mktemp "${real_state}.reset-old.XXXXXX")" || {
        rm -f "$working_config" "$working_state" "$config_snapshot"
        return 1
    }
    if ! cp -a "$real_config" "$working_config" ||
        ! cp -a "$real_state" "$working_state" ||
        ! cp -a "$real_config" "$config_snapshot" ||
        ! cp -a "$real_state" "$state_snapshot"; then
        discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
        err "[失败] 无法创建重置事务快照。"
        return 1
    fi

    CONFIG_FILE="$working_config"
    STATE_FILE="$working_state"
    changed="false"

    if [[ "$R_OPT" == "1" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            current_method="$(jq -r --arg tag "$SS_TAG" '.inbounds[] | select(.tag == $tag).settings.method' "$CONFIG_FILE")"
            SS_PASSWORD="$(generate_ss2022_password "$current_method")"
            if [[ -z "$SS_PASSWORD" ]] || ! jq_config_update --arg tag "$SS_TAG" --arg pass "$SS_PASSWORD" \
                '(.inbounds[] | select(.tag == $tag).settings.password) = $pass'; then
                discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
                err "[失败] 生成或写入 SS2022 新密码失败，未修改原配置。"
                return 1
            fi
            ok "[完成] SS2022 密码已重置。"
            changed="true"
        else
            info "[跳过] 未找到 SS2022 入站。"
        fi
    fi

    if [[ "$R_OPT" == "2" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            current_port="$(jq -r --arg tag "$VLESS_TAG" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE")"
            current_auth="$(jq -r '.vless_encryption.auth // "x25519"' "$STATE_FILE" 2>/dev/null)"
            VLESS_AUTH="$current_auth"
            VLESS_PORT="$current_port"
            VLESS_LISTEN="$(jq -r --arg tag "$VLESS_TAG" '.inbounds[] | select(.tag == $tag).listen // "0.0.0.0"' "$CONFIG_FILE")"
            VLESS_MODE="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
            VLESS_ENC_METHOD="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
            VLESS_CLIENT_RTT="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
            VLESS_SERVER_TICKET="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"
            if ! VLESS_UUID="$(generate_uuid)" || ! generate_vless_encryption_pair "$VLESS_AUTH" ||
                ! jq_config_update --arg tag "$VLESS_TAG" --arg uuid "$VLESS_UUID" --arg decryption "$VLESS_DECRYPTION" '
                    (.inbounds[] | select(.tag == $tag).settings.clients[0].id) = $uuid |
                    (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption |
                    del(.inbounds[] | select(.tag == $tag).settings.clients[0].flow)
                   ' || ! state_set_vless; then
                discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
                err "[失败] 重置 VLESS Encryption 失败，未修改原配置。"
                return 1
            fi
            ok "[完成] VLESS Encryption 的 UUID 与 Encryption 已重置。"
            changed="true"
        else
            info "[跳过] 未找到 VLESS Encryption 入站。"
        fi

        while IFS='|' read -r resetter argument; do
            if [[ -n "$argument" ]]; then
                "$resetter" "$argument"
            else
                "$resetter"
            fi
            rc=$?
            if [[ $rc -eq 1 ]]; then
                discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
                err "[失败] 密钥重置事务失败，未修改原配置。"
                return 1
            fi
            [[ $rc -eq 0 ]] && changed="true"
        done <<'EOF'
reset_vless_enc_finalmask_secret|
reset_vless_enc_xhttp_secret|
reset_vless_xhttp_finalmask_secret|
reset_reality_secret|
reset_advanced_secret|xhttp-reality
reset_advanced_secret|enc-reality
reset_advanced_secret|fullstack
EOF
    fi

    if [[ "$R_OPT" == "3" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            S_PASS="$(openssl rand -hex 8)"
            [[ -n "$S_PASS" ]] || S_PASS="$(generate_uuid | tr -d '-')"
            if [[ -z "$S_PASS" ]] || ! jq_config_update --arg tag "$SOCKS_TAG" --arg pass "$S_PASS" \
                '(.inbounds[] | select(.tag == $tag).settings.accounts[0].pass) = $pass'; then
                discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
                err "[失败] 生成或写入 SOCKS5 新密码失败，未修改原配置。"
                return 1
            fi
            ok "[完成] SOCKS5 密码已重置。"
            changed="true"
        else
            info "[跳过] 未找到 SOCKS5 入站。"
        fi
    fi

    if [[ "$changed" != "true" ]]; then
        discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
        info "[提示] 没有可更新的配置。"
        return 0
    fi

    if ! validate_config_file; then
        discard_secret_reset_working_copy "$real_config" "$real_state" "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
        err "[失败] 重置后的配置校验失败，未修改原配置。"
        return 1
    fi

    CONFIG_FILE="$real_config"
    STATE_FILE="$real_state"
    if ! mv "$working_config" "$CONFIG_FILE" || ! mv "$working_state" "$STATE_FILE" || ! ensure_config_security; then
        restore_secret_reset_snapshots "$config_snapshot" "$state_snapshot" || true
        rm -f "$working_config" "$working_state" "$config_snapshot" "$state_snapshot"
        err "[失败] 提交重置事务失败，已恢复原配置。"
        return 1
    fi
    if ! restart_service; then
        err "[失败] 重置后服务重启失败，正在恢复原配置。"
        restore_secret_reset_snapshots "$config_snapshot" "$state_snapshot" || true
        restart_service >/dev/null 2>&1 || true
        rm -f "$config_snapshot" "$state_snapshot"
        return 1
    fi

    rm -f "$config_snapshot" "$state_snapshot"
    state_set_meta_action "重置密钥/密码" || err "[状态] 最近变更记录失败。"
    view_config
}

remove_inbound() {
    local tag="$1"
    local tmp
    init_config || return 1
    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

remove_simple_inbound_config() {
    local tag="$1"
    local state_key="$2"
    local label="$3"

    [[ -f "$CONFIG_FILE" ]] || {
        info "[${label}] 未找到配置文件，视为未安装。"
        state_delete_key "$state_key" || return 1
        return 0
    }

    if ! jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        state_delete_key "$state_key" || return 1
        ok "[完成] ${label} 未安装或已删除。"
        return 0
    fi

    backup_config || {
        err "[失败] [${label}] 配置备份失败。"
        return 1
    }

    remove_inbound "$tag" || return 1

    if ! apply_config "${label} 删除"; then
        err "[失败] [${label}] 应用删除失败，已尝试自动回滚。"
        return 1
    fi

    if ! state_delete_key "$state_key"; then
        rollback_config_after_state_failure "${label} 删除"
        return 1
    fi
    state_set_meta_action "删除 ${label}" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${label} 已删除。"
}

state_delete_key() {
    local key="$1"
    local tmp
    init_state || return 1
    tmp="$(state_temp_file)" || return 1
    if ! jq --arg key "$key" 'del(.[$key])' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    ensure_config_security || return 1
}

installed_protocols_summary() {
    local protocols=()
    local summary i

    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1 && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        jq -e --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("SS2022")
        jq -e --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("VLESS Encryption")
        jq -e --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("Reality")
        jq -e --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("XHTTP-FinalMask")
        jq -e --arg tag "$VLESS_ENC_FM_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("ENC-FinalMask")
        jq -e --arg tag "$VLESS_ENC_XHTTP_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("ENC-XHTTP")
        jq -e --arg tag "$VLESS_XHTTP_REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("XHTTP-Reality")
        jq -e --arg tag "$VLESS_ENC_REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("Enc-Reality")
        jq -e --arg tag "$VLESS_FULLSTACK_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("FullStack")
        jq -e --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("SOCKS5")
        jq -e --arg tag "$HY2_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("Hysteria2")
    fi

    if [[ ${#protocols[@]} -eq 0 ]]; then
        printf '%s' "未配置入站协议"
        return 0
    fi

    summary="${protocols[0]}"
    for ((i = 1; i < ${#protocols[@]}; i++)); do
        summary="${summary} + ${protocols[$i]}"
    done
    printf '%s' "$summary"
}

render_uninstall_menu() {
    echo -e "\n${YELLOW}[卸载] 选择:${PLAIN}"
    echo " 1) 删除 SS2022 配置"
    echo " 2) 删除 VLESS Encryption 配置"
    echo " 3) 删除 VLESS TCP REALITY 配置"
    echo " 4) 删除 VLESS Encryption + XHTTP + FinalMask 配置"
    echo " 5) 删除 VLESS Encryption + XHTTP 配置"
    echo " 6) 删除 VLESS Encryption + FinalMask (sudoku) 配置"
    echo " 7) 删除 VLESS XHTTP + REALITY 配置"
    echo " 8) 删除 VLESS Encryption + REALITY 配置"
    echo " 9) 删除 VLESS Encryption + XHTTP + REALITY + FinalMask 配置"
    echo "10) 删除 SOCKS5 配置"
    echo "11) 删除 Hysteria2 配置"
    echo "12) 卸载全部 Xray"
    echo "13) 返回主菜单"
}

uninstall() {
    render_uninstall_menu
    read -r -p "选项: " OPT

    case "$OPT" in
        1)
            remove_simple_inbound_config "$SS_TAG" "ss2022" "SS2022"
            ;;
        2)
            remove_simple_inbound_config "$VLESS_TAG" "vless_encryption" "VLESS Encryption"
            ;;
        3)
            remove_reality_config
            ;;
        4)
            remove_vless_xhttp_finalmask_config
            ;;
        5)
            remove_simple_inbound_config "$VLESS_ENC_XHTTP_TAG" "$VLESS_ENC_XHTTP_STATE_KEY" "VLESS Encryption + XHTTP"
            ;;
        6)
            remove_simple_inbound_config "$VLESS_ENC_FM_TAG" "$VLESS_ENC_FM_STATE_KEY" "VLESS Encryption + FinalMask"
            ;;
        7)
            remove_advanced_profile_config "xhttp-reality"
            ;;
        8)
            remove_advanced_profile_config "enc-reality"
            ;;
        9)
            remove_advanced_profile_config "fullstack"
            ;;
        10)
            remove_simple_inbound_config "$SOCKS_TAG" "socks5" "SOCKS5"
            ;;
        11)
            remove_hysteria2_config
            ;;
        12)
            local service_file
            validate_xray_binary_path "$BIN_PATH" || return 1
            read -r -p "确认卸载 Xray、配置和快捷命令? [y/N]: " CONFIRM
            [[ "$CONFIRM" =~ ^[yY]$ ]] || return 0
            stop_service || return 1
            service_file="$(service_file_path)"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                if [[ -f "$service_file" ]] && grep -q "Managed by Xray-OneClick" "$service_file"; then
                    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                    rm -f -- "$service_file" || return 1
                    systemctl daemon-reload >/dev/null 2>&1 || true
                elif [[ -f "$service_file" ]]; then
                    info "[卸载] 检测到非本项目 service，已保留: $service_file"
                fi
            elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
                if [[ -f "$service_file" ]] && grep -q "Managed by Xray-OneClick" "$service_file"; then
                    rc-update del "$SERVICE_NAME" >/dev/null 2>&1 || true
                    rm -f -- "$service_file" || return 1
                elif [[ -f "$service_file" ]]; then
                    info "[卸载] 检测到非本项目 OpenRC service，已保留: $service_file"
                fi
            fi
            remove_managed_tree "$CONFIG_DIR" || return 1
            remove_managed_tree "$ASSET_DIR" || return 1
            remove_managed_tree "$INSTALLER_DIR" || return 1
            rm -f -- "$BIN_PATH" "$SHORTCUT_PATH" || return 1
            ok "[完成] Xray 已彻底卸载。当前 shell 如仍缓存 ike 路径，可执行 hash -r。"
            exit 0
            ;;
        13)
            return 0
            ;;
        "")
            return 0
            ;;
        *)
            err "无效选项。"
            ;;
    esac
}

show_footer() {
    local protocol_summary
    protocol_summary="$(installed_protocols_summary)"

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}   核心: Xray / 协议: ${protocol_summary}${PLAIN}"
    echo -e "${YELLOW}   快捷命令: ${SHORTCUT_PATH} / ike view [ipv4|ipv6]${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}\n"
}

pause_return_menu() {
    echo
    read -r -p "按回车返回主菜单..." || exit 0
}

configure_advanced_profiles_menu() {
    local opt del_opt

    while true; do
        echo -e "\n${YELLOW}[高级协议组合]${PLAIN}"
        echo " 1. 安装 VLESS XHTTP + REALITY"
        echo " 2. 安装 VLESS Encryption + REALITY"
        echo " 3. 安装 VLESS Encryption + XHTTP + REALITY + FinalMask"
        echo " 4. 查看高级协议组合"
        echo " 5. 删除高级协议组合"
        echo " 6. 返回主菜单"
        read -r -p "选项: " opt
        case "$opt" in
            1)
                if ! { prepare_system && configure_advanced_profile "xhttp-reality" "interactive" && install_advanced_profile "xhttp-reality"; }; then
                    err "[失败] VLESS XHTTP + REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            2)
                if ! { prepare_system && configure_advanced_profile "enc-reality" "interactive" && install_advanced_profile "enc-reality"; }; then
                    err "[失败] VLESS Encryption + REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                if ! { prepare_system && configure_advanced_profile "fullstack" "interactive" && install_advanced_profile "fullstack"; }; then
                    err "[失败] VLESS Encryption + XHTTP + REALITY + FinalMask 安装未完成，请查看上方错误信息。"
                fi
                ;;
            4)
                init_state || return 1
                print_advanced_profile_result "xhttp-reality" "show"
                print_advanced_profile_result "enc-reality" "show"
                print_advanced_profile_result "fullstack" "show"
                ;;
            5)
                echo -e "\n${YELLOW}[删除高级协议组合]${PLAIN}"
                echo " 1) 删除 VLESS XHTTP + REALITY"
                echo " 2) 删除 VLESS Encryption + REALITY"
                echo " 3) 删除 VLESS Encryption + XHTTP + REALITY + FinalMask"
                echo " 4) 返回"
                read -r -p "选项: " del_opt
                case "$del_opt" in
                    1) prepare_system && remove_advanced_profile_config "xhttp-reality" ;;
                    2) prepare_system && remove_advanced_profile_config "enc-reality" ;;
                    3) prepare_system && remove_advanced_profile_config "fullstack" ;;
                    4 | "") ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            6 | "") return 0 ;;
            *) err "无效选项。" ;;
        esac
        pause_return_menu
    done
}
