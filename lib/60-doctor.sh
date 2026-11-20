#!/usr/bin/env bash
# ike doctor command implementations.

doctor_reality_config() {
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    [[ -x "$BIN_PATH" ]] && diag_ok "xray 二进制存在" || diag_warn "xray 二进制不存在: $BIN_PATH"
    if [[ "${INIT_SYSTEM:-}" == "openrc" ]]; then
        command -v rc-service >/dev/null 2>&1 && diag_ok "rc-service 存在" || diag_warn "rc-service 不存在"
    else
        command -v systemctl >/dev/null 2>&1 && diag_ok "systemctl 存在" || diag_warn "systemctl 不存在或当前系统未使用 systemd"
    fi
    command -v ss >/dev/null 2>&1 && diag_ok "ss 存在" || diag_warn "ss 不存在，端口监听检查将降级"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    command -v openssl >/dev/null 2>&1 && diag_ok "openssl 存在" || diag_warn "openssl 不存在，SNI TLS 探测不可用"
}

doctor_xray_x25519() {
    local output status old_private old_public old_hash

    echo -e "\n${YELLOW}Xray x25519 诊断${PLAIN}"
    echo "----------------------------------------"
    if [[ ! -x "$BIN_PATH" ]]; then
        diag_warn "xray 二进制不存在，跳过 x25519 检查: $BIN_PATH"
        return 0
    fi

    output="$("$BIN_PATH" x25519 2>&1)"
    status=$?
    if ((status != 0)); then
        diag_fail "xray x25519 执行失败，退出码: ${status}"
        print_masked_x25519_output "$output"
        return 0
    fi

    old_private="${REALITY_PRIVATE_KEY:-}"
    old_public="${REALITY_PUBLIC_KEY:-}"
    old_hash="${REALITY_X25519_HASH32:-}"
    if parse_xray_x25519_output "$output"; then
        diag_ok "xray x25519 输出可解析"
        diag_ok "privateKey 已识别（脱敏）: $(mask_x25519_value "$REALITY_PRIVATE_KEY")"
        diag_ok "publicKey/pbk 已识别（脱敏）: $(mask_x25519_value "$REALITY_PUBLIC_KEY")"
        [[ -n "${REALITY_X25519_HASH32:-}" ]] && diag_info "Hash32: $(mask_x25519_value "$REALITY_X25519_HASH32")"
    else
        diag_fail "当前 Xray x25519 输出格式未被识别"
        print_masked_x25519_output "$output"
    fi
    REALITY_PRIVATE_KEY="$old_private"
    REALITY_PUBLIC_KEY="$old_public"
    REALITY_X25519_HASH32="$old_hash"
}

doctor_reality_routing() {
    local sni="$1"

    if jq -e --arg defender "$REALITY_DEFENDER_TAG" --arg sni "$sni" --arg block "$BLOCK_OUTBOUND_TAG" '
      .routing.rules as $rules |
      ($rules | map((.inboundTag // []) == [$defender] and (.domain // []) == ["full:" + $sni] and (.outboundTag == "direct" or .outboundTag == "DIRECT")) | index(true)) as $direct |
      ($rules | map((.inboundTag // []) == [$defender] and .outboundTag == $block) | index(true)) as $block_idx |
      ($direct != null and $block_idx != null and $direct < $block_idx)
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        diag_ok "Reality routing 顺序正确"
    else
        diag_fail "Reality routing 顺序异常，full:SNI -> direct 必须在 defender -> BLOCK 前面"
    fi
}

doctor_reality_port() {
    local port="$1"
    local defender_port="$2"

    if port_listening "$port"; then
        diag_ok "Reality 主端口正在监听: ${port}"
    elif [[ $? -eq 2 ]]; then
        diag_warn "未找到 ss，跳过 Reality 主端口监听检查"
    else
        diag_warn "Reality 主端口未监听: ${port}；如服务未运行，请执行 ike service restart"
    fi
    if [[ "$port" != "443" ]]; then
        diag_warn "Reality 主端口当前不是 443，最新 Xray 可能会提示非 443 warning。"
    fi

    if port_listening_localhost "$defender_port"; then
        diag_ok "Reality defender 端口仅本地监听: 127.0.0.1:${defender_port}"
    elif [[ $? -eq 2 ]]; then
        diag_warn "未找到 ss，跳过 defender 端口监听检查"
    else
        diag_warn "Reality defender 端口未检测到 127.0.0.1 监听: ${defender_port}"
    fi
}

doctor_reality_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        diag_warn "installer-state.json 不存在"
        return 0
    fi
    jq -e ".${REALITY_STATE_KEY}.port and .${REALITY_STATE_KEY}.defender_port and .${REALITY_STATE_KEY}.uuid and .${REALITY_STATE_KEY}.public_key and .${REALITY_STATE_KEY}.default_short_id and .${REALITY_STATE_KEY}.server_name and .${REALITY_STATE_KEY}.flow and .${REALITY_STATE_KEY}.link" "$STATE_FILE" >/dev/null 2>&1 &&
        diag_ok "Reality state 字段完整" ||
        diag_warn "Reality state 字段不完整，可重新执行 ike reality install"
}

doctor_reality_sni() {
    local sni="$1"

    if validate_reality_sni "$sni"; then
        diag_ok "SNI 格式合理"
    else
        diag_fail "SNI 格式异常: ${sni}"
    fi
    if env_truthy "${XRAY_ONECLICK_DOCTOR_TLS:-}"; then
        if test_reality_target_tls "$sni"; then
            diag_ok "SNI TLS 探测通过: ${sni}:443"
        else
            diag_warn "SNI TLS 探测失败，建议更换域名或稍后重试"
        fi
    else
        diag_info "如需探测 SNI TLS，可执行: XRAY_ONECLICK_DOCTOR_TLS=1 ike doctor reality"
    fi
}

doctor_reality_output() {
    local public_key sni

    public_key="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
    sni="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    [[ -n "$sni" ]] && diag_info "SNI: ${sni}"
    [[ -n "$public_key" ]] && diag_info "PublicKey: ${public_key}"
}

doctor_reality() {
    local r_in d_in port defender_port sni flow target short_count state_flow state_link link_has_flow

    echo -e "\n${YELLOW}Reality 诊断${PLAIN}"
    echo "----------------------------------------"
    doctor_reality_config
    doctor_xray_x25519
    if ! inbound_exists "$REALITY_TAG"; then
        diag_info "Reality 未安装，跳过 Reality 专项检查"
        return 0
    fi
    inbound_exists "$REALITY_DEFENDER_TAG" && diag_ok "Reality defender 已安装" || diag_fail "Reality defender 未安装"
    diag_ok "Reality inbound 已安装"

    r_in="$(jq -c --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    d_in="$(jq -c --arg tag "$REALITY_DEFENDER_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    port="$(echo "$r_in" | jq -r '.port // empty')"
    defender_port="$(echo "$d_in" | jq -r '.port // empty')"
    sni="$(echo "$r_in" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')"
    flow="$(echo "$r_in" | jq -r '.settings.clients[0].flow // empty')"
    target="$(echo "$r_in" | jq -r '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty')"
    short_count="$(echo "$r_in" | jq -r '.streamSettings.realitySettings.shortIds | length')"

    echo "$r_in" | jq -e '.protocol == "vless" and .streamSettings.network == "tcp" and .streamSettings.security == "reality"' >/dev/null && diag_ok "Reality inbound 协议/传输/安全类型正确" || diag_fail "Reality inbound 协议/传输/安全类型异常"
    echo "$r_in" | jq -e '(.settings.clients[0].id // "") != ""' >/dev/null && diag_ok "Reality UUID 存在" || diag_fail "Reality UUID 缺失"
    if [[ "$flow" == "$REALITY_FLOW_DEFAULT" ]]; then
        diag_ok "Reality flow 一致：${REALITY_FLOW_DEFAULT}"
    elif [[ -z "$flow" ]]; then
        diag_warn "普通 VLESS TCP REALITY 缺少 Vision flow，建议重新执行 ike reality install 或运行 migrate。"
    else
        diag_fail "Reality flow 异常: ${flow}"
    fi
    if [[ "$port" != "443" ]]; then
        diag_warn "Reality 主端口当前不是 443，最新 Xray 可能会提示非 443 warning。"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        state_flow="$(jq -r ".${REALITY_STATE_KEY}.flow // empty" "$STATE_FILE" 2>/dev/null)"
        state_link="$(jq -r ".${REALITY_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
        link_has_flow="false"
        [[ "$state_link" == *"flow=${REALITY_FLOW_DEFAULT}"* ]] && link_has_flow="true"
        if [[ "$flow" == "$REALITY_FLOW_DEFAULT" && "$state_flow" == "$REALITY_FLOW_DEFAULT" && "$link_has_flow" == "true" ]]; then
            diag_ok "Reality flow 在 config/state/link 中一致"
        else
            diag_warn "Reality flow 在 config/state/link 中不完全一致，建议运行 ike migrate 或重新安装 Reality。"
        fi
    fi
    echo "$r_in" | jq -e '(.streamSettings.realitySettings.privateKey // "") != ""' >/dev/null && diag_ok "Reality privateKey 已写入服务端配置（默认不输出值）" || diag_fail "Reality privateKey 缺失"
    [[ -n "$sni" ]] && diag_ok "Reality serverNames 已配置" || diag_fail "Reality serverNames 缺失"
    ((short_count == 8)) && diag_ok "Reality shortIds 数量为 8" || diag_warn "Reality shortIds 数量为 ${short_count}"
    [[ "$target" == "127.0.0.1:${defender_port}" ]] && diag_ok "Reality target 指向 defender: ${target}" || diag_fail "Reality target 异常: ${target}"
    echo "$d_in" | jq -e --arg sni "$sni" '.listen == "127.0.0.1" and .protocol == "dokodemo-door" and .settings.address == $sni and .settings.port == 443 and .settings.network == "tcp"' >/dev/null && diag_ok "Reality defender 配置正确" || diag_fail "Reality defender 配置异常"
    doctor_reality_routing "$sni"
    doctor_reality_state
    doctor_reality_port "$port" "$defender_port"
    doctor_reality_sni "$sni"
    cnblock_reality_risk_notice
    doctor_reality_output
}

doctor_xhttp() {
    local x_in state_enabled config_has_fm link fm path

    echo -e "\n${YELLOW}XHTTP-FinalMask 诊断${PLAIN}"
    echo "----------------------------------------"
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    if ! inbound_exists "$VLESS_XHTTP_FM_TAG"; then
        diag_info "XHTTP-FinalMask 未安装，跳过 XHTTP 专项检查"
        return 0
    fi
    x_in="$(jq -c --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    path="$(echo "$x_in" | jq -r '.streamSettings.xhttpSettings.path // empty')"
    echo "$x_in" | jq -e '.protocol == "vless" and (.settings.decryption // "") != "" and .streamSettings.network == "xhttp" and .streamSettings.security == "none"' >/dev/null && diag_ok "XHTTP inbound 协议/加密/传输配置正确" || diag_fail "XHTTP inbound 配置异常"
    validate_xhttp_path "$path" && diag_ok "XHTTP path 合法: ${path}" || diag_fail "XHTTP path 非法: ${path}"
    if [[ -f "$STATE_FILE" ]]; then
        jq -e ".${VLESS_XHTTP_FM_STATE_KEY}.port and .${VLESS_XHTTP_FM_STATE_KEY}.path and .${VLESS_XHTTP_FM_STATE_KEY}.encryption and (.${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled != null) and .${VLESS_XHTTP_FM_STATE_KEY}.link" "$STATE_FILE" >/dev/null 2>&1 &&
            diag_ok "XHTTP state 字段完整" ||
            diag_warn "XHTTP state 字段不完整"
        state_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        link="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    else
        diag_warn "installer-state.json 不存在"
        state_enabled="false"
        link=""
    fi
    config_has_fm="$(echo "$x_in" | jq -r '.streamSettings | has("finalmask")')"
    if [[ "$state_enabled" == "true" ]]; then
        [[ "$config_has_fm" == "true" ]] && diag_ok "FinalMask 已写入 config" || diag_fail "state 显示 FinalMask on，但 config 未写 finalmask"
        jq -e ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json" "$STATE_FILE" >/dev/null 2>&1 && diag_ok "FinalMask JSON 已写入 state" || diag_fail "FinalMask JSON 缺失"
        [[ "$link" == *"fm="* ]] && diag_ok "分享链接包含 fm 参数" || diag_fail "分享链接缺少 fm 参数"
        fm="${link#*fm=}"
        fm="${fm%%#*}"
        [[ "$fm" != *"{"* && "$fm" != *"}"* && "$fm" != *" "* && "$fm" != *"\""* ]] && diag_ok "fm 参数已 URL 编码" || diag_fail "fm 参数包含未编码 JSON 字符"
    else
        [[ "$config_has_fm" == "false" ]] && diag_ok "FinalMask off 时 config 未写 finalmask" || diag_fail "FinalMask off 时 config 仍存在 finalmask"
        [[ "$link" != *"fm="* ]] && diag_ok "FinalMask off 时链接不含 fm" || diag_fail "FinalMask off 时链接仍含 fm"
    fi
    diag_info "Encryption: $(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
}

doctor_advanced_profile() {
    local kind="$1"
    local tag state_key name network in path state_link config_has_fm state_enabled fm port target
    local fallback_limit_mode fallback_limit_upload fallback_limit_download
    local config_flow state_flow link_has_flow

    tag="$(advanced_profile_tag "$kind")" || return 1
    state_key="$(advanced_profile_state_key "$kind")" || return 1
    name="$(advanced_profile_name "$kind")" || return 1
    network="$(advanced_profile_network "$kind")" || return 1

    echo -e "\n${YELLOW}${name} 诊断${PLAIN}"
    echo "----------------------------------------"
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    if ! inbound_exists "$tag"; then
        diag_info "${name} 未安装，跳过专项检查"
        return 0
    fi

    in="$(jq -c --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    echo "$in" | jq -e --arg network "$network" '.protocol == "vless" and .streamSettings.network == $network and .streamSettings.security == "reality"' >/dev/null &&
        diag_ok "inbound 协议/传输/REALITY 配置正确" ||
        diag_fail "inbound 协议/传输/REALITY 配置异常"
    echo "$in" | jq -e '(.settings.clients[0].id // "") != ""' >/dev/null && diag_ok "UUID 存在" || diag_fail "UUID 缺失"
    echo "$in" | jq -e '(.streamSettings.realitySettings.privateKey // "") != ""' >/dev/null && diag_ok "privateKey 已写入服务端配置（默认不输出值）" || diag_fail "privateKey 缺失"
    target="$(echo "$in" | jq -r '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty')"
    echo "$in" | jq -e '(.streamSettings.realitySettings.serverNames[0] // "") != "" and ((.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // "") | endswith(":443"))' >/dev/null &&
        diag_ok "REALITY target/serverNames 已配置" ||
        diag_fail "REALITY target/serverNames 配置异常"
    echo "$in" | jq -e '(.streamSettings.realitySettings.shortIds | length) == 8' >/dev/null && diag_ok "shortIds 数量为 8" || diag_warn "shortIds 数量不是 8"
    config_flow="$(echo "$in" | jq -r '.settings.clients[0].flow // "none"')"
    [[ -n "$config_flow" ]] || config_flow="$REALITY_FLOW_NONE"

    if advanced_profile_has_xhttp "$kind"; then
        path="$(echo "$in" | jq -r '.streamSettings.xhttpSettings.path // empty')"
        validate_xhttp_path "$path" && diag_ok "XHTTP path 合法: ${path}" || diag_fail "XHTTP path 非法: ${path}"
    fi
    if advanced_profile_has_encryption "$kind"; then
        echo "$in" | jq -e '(.settings.decryption // "") != "" and .settings.decryption != "none"' >/dev/null &&
            diag_ok "服务端 decryption 已写入（默认不输出值）" ||
            diag_fail "服务端 decryption 缺失"
        jq -e ".${state_key}.encryption" "$STATE_FILE" >/dev/null 2>&1 && diag_ok "客户端 encryption 已写入 state" || diag_warn "客户端 encryption 缺失"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        jq -e ".${state_key}.port and .${state_key}.uuid and .${state_key}.public_key and .${state_key}.default_short_id and .${state_key}.server_name and .${state_key}.link" "$STATE_FILE" >/dev/null 2>&1 &&
            diag_ok "state 字段完整" ||
            diag_warn "state 字段不完整"
        state_link="$(jq -r ".${state_key}.link // empty" "$STATE_FILE" 2>/dev/null)"
        state_flow="$(jq -r ".${state_key}.flow // \"$REALITY_FLOW_NONE\"" "$STATE_FILE" 2>/dev/null)"
        [[ "$state_link" == *"security=reality"* && "$state_link" == *"pbk="* && "$state_link" == *"sid="* ]] && diag_ok "分享链接包含 REALITY 必要参数" || diag_warn "分享链接缺少部分 REALITY 参数"
    else
        diag_warn "installer-state.json 不存在"
        state_link=""
        state_flow="$REALITY_FLOW_NONE"
    fi
    link_has_flow="false"
    [[ "$state_link" == *"flow=${REALITY_FLOW_DEFAULT}"* ]] && link_has_flow="true"
    if [[ "$state_flow" == "$REALITY_FLOW_DEFAULT" || "$config_flow" == "$REALITY_FLOW_DEFAULT" || "$link_has_flow" == "true" ]]; then
        if [[ "$state_flow" == "$REALITY_FLOW_DEFAULT" && "$config_flow" == "$REALITY_FLOW_DEFAULT" && "$link_has_flow" == "true" ]]; then
            diag_ok "Vision flow 已启用且 config/state/link 一致"
        else
            diag_fail "Vision flow 配置不一致，请重新执行 ike ${kind} install --flow vision 或 --flow none"
        fi
        diag_warn "高级组合启用 Vision flow 可能存在客户端兼容风险。"
    else
        diag_ok "Vision flow 未启用（高级组合默认）"
    fi
    cnblock_reality_risk_notice
    if advanced_profile_has_fallback_limit "$kind"; then
        fallback_limit_mode="$(jq -r ".${state_key}.fallback_limit_mode // \"off\"" "$STATE_FILE" 2>/dev/null)"
        fallback_limit_upload="$(jq -c ".${state_key}.fallback_limit_upload // null" "$STATE_FILE" 2>/dev/null)"
        fallback_limit_download="$(jq -c ".${state_key}.fallback_limit_download // null" "$STATE_FILE" 2>/dev/null)"
        if [[ "$fallback_limit_mode" == "conservative" ]]; then
            diag_ok "Fallback limit 已启用: conservative"
            diag_info "Fallback upload: ${fallback_limit_upload}"
            diag_info "Fallback download: ${fallback_limit_download}"
        else
            diag_ok "Fallback limit 未启用"
        fi
    fi
    if advanced_profile_has_finalmask "$kind"; then
        state_enabled="$(jq -r ".${state_key}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        config_has_fm="$(echo "$in" | jq -r '.streamSettings | has("finalmask")')"
        if [[ "$state_enabled" == "true" ]]; then
            [[ "$config_has_fm" == "true" ]] && diag_ok "FinalMask on 时 config 已写 finalmask" || diag_fail "FinalMask on 但 config 未写 finalmask"
            [[ "$state_link" == *"fm="* ]] && diag_ok "分享链接包含 fm 参数" || diag_fail "分享链接缺少 fm 参数"
            fm="${state_link#*fm=}"
            fm="${fm%%#*}"
            [[ "$fm" != *"{"* && "$fm" != *"}"* && "$fm" != *" "* && "$fm" != *"\""* ]] && diag_ok "fm 参数已 URL 编码" || diag_fail "fm 参数包含未编码 JSON 字符"
        else
            [[ "$config_has_fm" == "false" ]] && diag_ok "FinalMask off 时 config 未写 finalmask" || diag_fail "FinalMask off 时 config 仍存在 finalmask"
            [[ "$state_link" != *"fm="* ]] && diag_ok "FinalMask off 时链接不含 fm" || diag_fail "FinalMask off 时链接仍含 fm"
        fi
    fi
    port="$(echo "$in" | jq -r '.port // empty')"
    if port_listening "$port"; then
        diag_ok "入口端口正在监听: ${port}"
    elif [[ $? -eq 2 ]]; then
        diag_warn "未找到 ss，跳过端口监听检查"
    else
        diag_warn "入口端口未监听: ${port}"
    fi
    diag_info "Xray 配置校验: $(xray_config_test_status)"
}

doctor_proxy() {
    local tags ports

    echo -e "\n${YELLOW}Xray 代理总览诊断${PLAIN}"
    echo "----------------------------------------"
    [[ -x "$BIN_PATH" ]] && diag_ok "xray 二进制存在" || diag_warn "xray 二进制不存在"
    diag_info "Xray binary: $BIN_PATH"
    diag_info "Xray version: $(detect_xray_version 2>/dev/null || printf '%s' '未安装')"
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    if [[ "$INIT_SYSTEM" == "systemd" || "$INIT_SYSTEM" == "openrc" ]]; then
        [[ "$(xray_service_status)" == "运行中" ]] && diag_ok "xray 服务运行中" || diag_warn "xray 服务当前未运行"
    else
        diag_warn "未检测到 systemd/OpenRC，跳过服务状态检查"
    fi
    [[ -f "$CONFIG_FILE" && -x "$BIN_PATH" ]] && diag_info "Xray 配置校验: $(xray_config_test_status)"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        tags="$(jq -r '[.inbounds[]?.tag] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        ports="$(jq -r '[.inbounds[]? | select(.port != null) | (.tag + ":" + (.port|tostring))] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        diag_info "已安装 inbound tags: ${tags:-无}"
        diag_info "监听端口: ${ports:-无}"
    fi
    default_safety_block_enabled && diag_ok "默认安全屏蔽规则存在" || diag_warn "默认安全屏蔽规则未完整启用"
    diag_info "中国大陆直连屏蔽: $(china_direct_block_status)"
    cnblock_reality_risk_notice
    detect_xray_feature_support
    doctor_xray_x25519
    if view_config dual quick >/dev/null 2>&1; then
        diag_ok "ike view 可以输出"
    else
        diag_warn "ike view 输出失败，请检查配置和 state"
    fi
}

run_doctor_command() {
    local target="${1:-all}"

    [[ $# -le 1 ]] || {
        err "[失败] doctor 参数过多。"
        return 1
    }
    check_os
    detect_arch

    case "$target" in
        preflight) preflight_system ;;
        reality-key) doctor_xray_x25519 ;;
        reality) doctor_reality ;;
        xhttp) doctor_xhttp ;;
        xhttp-reality) doctor_advanced_profile "xhttp-reality" ;;
        enc-reality) doctor_advanced_profile "enc-reality" ;;
        fullstack) doctor_advanced_profile "fullstack" ;;
        proxy) doctor_proxy ;;
        all | "")
            preflight_system || true
            view_config "$LINK_VIEW_MODE" "doctor" || true
            doctor_proxy
            doctor_reality
            doctor_xhttp
            doctor_advanced_profile "xhttp-reality"
            doctor_advanced_profile "enc-reality"
            doctor_advanced_profile "fullstack"
            ;;
        *)
            err "[失败] 未知 doctor 参数: $target"
            echo "用法: ike doctor preflight|reality-key|reality|xhttp|xhttp-reality|enc-reality|fullstack|proxy|all"
            return 1
            ;;
    esac
}

show_journal_recent() {
    if [[ "${INIT_SYSTEM:-}" == "openrc" ]]; then
        if tail_xray_service_logs 80; then
            return 0
        fi
        diag_warn "未找到 $(log_dir_path) 日志，请先 ike service restart"
        return 0
    fi
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 | redact_sensitive_stream || true
    else
        diag_warn "journalctl 不存在，无法读取最近日志"
    fi
}

run_xray_config_test_verbose() {
    if [[ ! -x "$BIN_PATH" ]]; then
        diag_warn "xray 不存在，跳过 xray run -test"
        return 0
    fi
    if validate_config_file; then
        diag_ok "xray run -test 通过"
        return 0
    fi
    diag_fail "xray run -test 失败"
    return 1
}
