#!/usr/bin/env bash
# VLESS TCP REALITY protocol.

validate_reality_sni() {
    local domain="$1"
    local label
    local -a labels

    [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
    [[ "$domain" != *"://"* && "$domain" != *"/"* && "$domain" != *":"* ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* && "$domain" != *. ]] || return 1
    [[ "$domain" != *..* ]] || return 1

    IFS='.' read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

generate_reality_short_ids() {
    local len id
    local -a lengths=(2 4 6 8 10 12 14 16)

    REALITY_SHORT_IDS=()
    for len in "${lengths[@]}"; do
        if command -v openssl >/dev/null 2>&1; then
            id="$(openssl rand -hex "$((len / 2))" | cut -c "1-${len}")" || return 1
        else
            id="$(printf "%0${len}d" "$len" | cut -c "1-${len}")"
        fi
        REALITY_SHORT_IDS+=("$id")
    done
    REALITY_DEFAULT_SHORT_ID="${REALITY_SHORT_IDS[0]}"
    REALITY_SHORT_IDS_JSON="$(printf '%s\n' "${REALITY_SHORT_IDS[@]}" | jq -R . | jq -s -c .)" || return 1
}

normalize_x25519_key_name() {
    local key="$1"

    key="${key//$'\r'/}"
    key="${key//[[:space:]]/}"
    key="${key//_/}"
    key="${key//-/}"
    key="${key//(/}"
    key="${key//)/}"
    printf '%s' "${key,,}"
}

trim_x25519_value() {
    local value="$1"

    value="${value//$'\r'/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

mask_x25519_value() {
    local value="$1"
    local len="${#value}"

    if [[ -z "$value" ]]; then
        printf '%s' "(空)"
    elif ((len <= 8)); then
        printf '%s' "****"
    else
        printf '%s...%s' "${value:0:4}" "${value: -4}"
    fi
}

print_masked_x25519_output() {
    local output="$1"
    local line key value

    while IFS= read -r line; do
        line="${line//$'\r'/}"
        [[ -n "$line" ]] || continue
        if [[ "$line" == *:* ]]; then
            key="$(trim_x25519_value "${line%%:*}")"
            value="$(trim_x25519_value "${line#*:}")"
            if [[ -n "$value" ]]; then
                printf '  %s: %s\n' "$key" "$(mask_x25519_value "$value")"
            else
                printf '  %s:\n' "$key"
            fi
        else
            printf '  %s\n' "$line"
        fi
    done <<<"$output"
}

parse_xray_x25519_output() {
    local output="$1"
    local line raw_key key key_base key_full value private="" public="" hash32=""

    REALITY_X25519_HASH32=""

    while IFS= read -r line; do
        line="${line//$'\r'/}"
        [[ "$line" == *:* ]] || continue
        raw_key="$(trim_x25519_value "${line%%:*}")"
        value="$(trim_x25519_value "${line#*:}")"
        key_base="$(printf '%s' "$raw_key" | sed -E 's/[[:space:]]*\([^)]*\)//g')"
        key="$(normalize_x25519_key_name "$key_base")"
        key_full="$(normalize_x25519_key_name "$raw_key")"
        [[ -n "$value" ]] || continue
        if [[ "$key_full" == *privatekey* || "$key" == "private" ]]; then
            private="$value"
        elif [[ "$key_full" == *publickey* ]]; then
            public="$value"
        elif [[ "$key" == "password" || "$key_full" == password* ]]; then
            public="$value"
        elif [[ "$key_full" == *hash32* ]]; then
            hash32="$value"
        fi
    done <<<"$output"

    [[ -n "$private" && -n "$public" ]] || return 1
    REALITY_PRIVATE_KEY="$private"
    REALITY_PUBLIC_KEY="$public"
    REALITY_X25519_HASH32="$hash32"
}

generate_reality_keys() {
    local output status

    if env_truthy "${IKE_TEST_MODE:-}" && [[ ! -x "$BIN_PATH" ]]; then
        REALITY_PRIVATE_KEY="test-private-key-for-offline-config-generation"
        REALITY_PUBLIC_KEY="test-public-key-for-offline-config-generation"
        REALITY_X25519_HASH32=""
        return 0
    fi

    output="$("$BIN_PATH" x25519 2>&1)"
    status=$?
    if ((status != 0)); then
        err "[Reality] xray x25519 执行失败，退出码: ${status}"
        err "[Reality] 脱敏输出:"
        print_masked_x25519_output "$output" >&2
        err "[Reality] 请确认 Xray 版本支持 REALITY。"
        return 1
    fi

    if ! parse_xray_x25519_output "$output"; then
        err "[Reality] 当前 Xray x25519 输出格式未被识别。"
        err "[Reality] 脱敏输出:"
        print_masked_x25519_output "$output" >&2
        return 1
    fi
}

test_reality_target_tls() {
    local domain="$1"

    if env_truthy "${REALITY_SKIP_TLS_TEST:-}"; then
        return 0
    fi
    command -v openssl >/dev/null 2>&1 || {
        info "[Reality] 未找到 openssl，已跳过 DOMAIN:443 可达性检测。"
        return 0
    }

    if command -v timeout >/dev/null 2>&1; then
        timeout 8 openssl s_client -servername "$domain" -connect "${domain}:443" </dev/null >/dev/null 2>&1
    else
        openssl s_client -servername "$domain" -connect "${domain}:443" </dev/null >/dev/null 2>&1
    fi
}

ask_or_random_reality_port() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local requested="$4"
    local __resultvar="$5"
    local input port

    if [[ -n "$requested" ]]; then
        validate_port "$requested" || {
            err "[Reality] 端口无效: $requested"
            return 1
        }
        if port_used_in_config "$requested" || ! check_port "$requested"; then
            err "[Reality] 端口已被占用或已存在于 config.json: $requested"
            return 1
        fi
        printf -v "$__resultvar" '%s' "$requested"
        return 0
    fi

    if [[ "${REALITY_CONFIG_MODE:-interactive}" != "interactive" ]]; then
        port="$(random_free_port "$min" "$max")" || {
            err "[Reality] 无法在 ${min}-${max} 中找到可用端口。"
            return 1
        }
        printf -v "$__resultvar" '%s' "$port"
        return 0
    fi

    while true; do
        read -r -p "${prompt} (回车随机 ${min}-${max}；推荐输入 443 以降低 IP 被封风险): " input
        if [[ -z "$input" ]]; then
            port="$(random_free_port "$min" "$max")" || {
                err "[Reality] 无法在 ${min}-${max} 中找到可用端口。"
                return 1
            }
            info "[Reality] 随机选择端口: ${port}"
            info "[Reality] 提示: 非 443 端口 + 借用 SNI 较易被探测封锁，如条件允许建议改用 443。"
            printf -v "$__resultvar" '%s' "$port"
            return 0
        fi
        if ! validate_port "$input"; then
            err "[Reality] 端口无效，请输入 1-65535。"
            continue
        fi
        if port_used_in_config "$input" || ! check_port "$input"; then
            err "[Reality] 端口 ${input} 已被占用或已存在于 config.json。"
            continue
        fi
        warn_reserved_port "$input"
        [[ "$input" != "443" ]] && info "[Reality] 提示: Xray 官方建议优先使用 443，非 443 端口更易被探测封锁。"
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

ask_or_random_reality_sni() {
    local requested="${1:-}"
    local __resultvar="$2"
    local input index domain

    if [[ -n "$requested" ]]; then
        validate_reality_sni "$requested" || {
            err "[Reality] SNI 域名格式无效: $requested"
            return 1
        }
        printf -v "$__resultvar" '%s' "$requested"
        return 0
    fi

    if [[ "${REALITY_CONFIG_MODE:-interactive}" != "interactive" ]]; then
        index=$((RANDOM % ${#REALITY_SNI_CANDIDATES[@]}))
        domain="${REALITY_SNI_CANDIDATES[$index]}"
        printf -v "$__resultvar" '%s' "$domain"
        return 0
    fi

    while true; do
        read -r -p "Reality 伪装域名 SNI (回车随机): " input
        if [[ -z "$input" ]]; then
            index=$((RANDOM % ${#REALITY_SNI_CANDIDATES[@]}))
            domain="${REALITY_SNI_CANDIDATES[$index]}"
            info "[Reality] 随机选择 SNI: ${domain}"
            printf -v "$__resultvar" '%s' "$domain"
            return 0
        fi
        if validate_reality_sni "$input"; then
            printf -v "$__resultvar" '%s' "$input"
            return 0
        fi
        err "[Reality] SNI 域名格式无效，请输入类似 www.example.com 的域名。"
    done
}

normalize_reality_flow() {
    local requested="${1:-$REALITY_FLOW_NONE}"

    case "${requested,,}" in
        vision | xtls-rprx-vision)
            printf '%s' "$REALITY_FLOW_DEFAULT"
            ;;
        none | off | false | 0 | "")
            printf '%s' "$REALITY_FLOW_NONE"
            ;;
        *)
            return 1
            ;;
    esac
}

flow_config_value() {
    local flow="${1:-$REALITY_FLOW_NONE}"

    flow="$(normalize_reality_flow "$flow")" || return 1
    [[ "$flow" == "$REALITY_FLOW_DEFAULT" ]] && printf '%s' "$REALITY_FLOW_DEFAULT"
}

flow_state_value() {
    local flow="${1:-$REALITY_FLOW_NONE}"

    flow="$(normalize_reality_flow "$flow")" || return 1
    printf '%s' "$flow"
}

print_reality_flow_none_warning() {
    diag_warn "普通 Reality 推荐 Vision flow；关闭后可能影响性能和兼容性。"
}

print_advanced_flow_warning() {
    diag_warn "你正在为高级组合启用 xtls-rprx-vision。"
    diag_warn "XHTTP + REALITY / FullStack 与 Vision flow 可能存在客户端兼容风险。"
    diag_warn "如果连接失败，请重新安装并使用 --flow none。"
}

configure_reality() {
    local mode="${1:-interactive}"
    local retry_port

    REALITY_CONFIG_MODE="$mode"
    if [[ "$mode" != "dry-run" ]]; then
        install_or_update_xray || return 1
    fi

    ask_or_random_reality_port "Reality 入口端口" "$REALITY_PORT_MIN" "$REALITY_PORT_MAX" "${REALITY_PORT_REQUEST:-}" REALITY_PORT || return 1
    ask_or_random_reality_port "Reality defender 本地端口" "$REALITY_DEFENDER_PORT_MIN" "$REALITY_DEFENDER_PORT_MAX" "${REALITY_DEFENDER_PORT_REQUEST:-}" REALITY_DEFENDER_PORT || return 1
    if [[ "$REALITY_PORT" == "$REALITY_DEFENDER_PORT" ]]; then
        if [[ -z "${REALITY_DEFENDER_PORT_REQUEST:-}" ]]; then
            for _ in {1..20}; do
                retry_port="$(random_free_port "$REALITY_DEFENDER_PORT_MIN" "$REALITY_DEFENDER_PORT_MAX" || true)"
                [[ -n "$retry_port" && "$retry_port" != "$REALITY_PORT" ]] || continue
                REALITY_DEFENDER_PORT="$retry_port"
                break
            done
        elif [[ -z "${REALITY_PORT_REQUEST:-}" ]]; then
            for _ in {1..20}; do
                retry_port="$(random_free_port "$REALITY_PORT_MIN" "$REALITY_PORT_MAX" || true)"
                [[ -n "$retry_port" && "$retry_port" != "$REALITY_DEFENDER_PORT" ]] || continue
                REALITY_PORT="$retry_port"
                break
            done
        fi
    fi
    if [[ "$REALITY_PORT" == "$REALITY_DEFENDER_PORT" ]]; then
        err "[Reality] 入口端口和 defender 端口不能相同。"
        return 1
    fi

    ask_or_random_reality_sni "${REALITY_SNI_REQUEST:-}" REALITY_SERVER_NAME || return 1
    info "[Reality] 建议 target 使用 ${REALITY_SERVER_NAME}:443；入口端口可随机，defender 始终转发到 443。"
    if ! test_reality_target_tls "$REALITY_SERVER_NAME"; then
        err "[Reality] ${REALITY_SERVER_NAME}:443 TLS 探测失败。"
        if [[ "$mode" == "interactive" ]]; then
            confirm_yes_no "仍然继续写入 Reality 配置?" "n" || return 1
        elif ! { env_truthy "${XRAY_ONECLICK_YES:-}" || env_truthy "${REALITY_ASSUME_YES:-}"; }; then
            err "[Reality] 非交互模式默认取消；确认目标可用后可设置 XRAY_ONECLICK_YES=1 重试。"
            return 1
        fi
    fi

    REALITY_UUID="$(generate_uuid)" || {
        err "[Reality] UUID 生成失败。"
        return 1
    }
    REALITY_SPIDER_X="/"
    REALITY_EMPTY_CLIENTS="${REALITY_EMPTY_CLIENTS:-false}"
    if [[ "$REALITY_EMPTY_CLIENTS" == "true" ]]; then
        REALITY_FLOW="$REALITY_FLOW_NONE"
    else
        REALITY_FLOW="$(normalize_reality_flow "${REALITY_FLOW:-$REALITY_FLOW_DEFAULT}")" || {
            err "[Reality] --flow 仅支持 none 或 vision。"
            return 1
        }
        [[ "$REALITY_FLOW" == "$REALITY_FLOW_NONE" ]] && print_reality_flow_none_warning
    fi
    generate_reality_keys || return 1
    generate_reality_short_ids || return 1
}

build_reality_share_link() {
    local port="${REALITY_PORT:-}"
    local uuid="${REALITY_UUID:-}"
    local public_key="${REALITY_PUBLIC_KEY:-}"
    local short_id="${REALITY_DEFAULT_SHORT_ID:-}"
    local server_name="${REALITY_SERVER_NAME:-}"
    local spider_x="${REALITY_SPIDER_X:-/}"
    local flow="$REALITY_FLOW_DEFAULT"
    local flow_link=""
    local host link_port endpoint_pair
    local pbk_uri sni_uri sid_uri spx_uri flow_uri name_uri

    [[ ${REALITY_FLOW+x} ]] && flow="$REALITY_FLOW"

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${REALITY_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        public_key="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
        short_id="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
        server_name="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
        spider_x="$(jq -r ".${REALITY_STATE_KEY}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
        flow="$(jq -r ".${REALITY_STATE_KEY}.flow // \"$REALITY_FLOW_DEFAULT\"" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" && -n "$server_name" ]] || return 1
    flow="$(flow_state_value "$flow")" || return 1
    flow_link="$(flow_config_value "$flow" || true)"
    endpoint_pair="$(link_endpoint_for_tag "$port" "$REALITY_TAG" "$REALITY_STATE_KEY")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    pbk_uri="$(url_encode "$public_key")"
    sni_uri="$(url_encode "$server_name")"
    sid_uri="$(url_encode "$short_id")"
    spx_uri="$(url_encode "$spider_x")"
    flow_uri="$(url_encode "$flow_link")"
    name_uri="$(url_encode "Xray-Reality")"

    printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s' \
        "$uuid" "$host" "$link_port" "$pbk_uri" "$sni_uri" "$sid_uri"
    [[ -n "$flow_link" ]] && printf '&flow=%s' "$flow_uri"
    printf '&spx=%s#%s' "$spx_uri" "$name_uri"
}

state_set_reality() {
    init_state || return 1
    local tmp link timestamp clients_empty flow
    local hash32

    flow="$REALITY_FLOW_DEFAULT"
    [[ ${REALITY_FLOW+x} ]] && flow="$(flow_state_value "$REALITY_FLOW")"
    hash32="${REALITY_X25519_HASH32:-}"
    link="$(build_reality_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    clients_empty="false"
    [[ "${REALITY_EMPTY_CLIENTS:-false}" == "true" ]] && clients_empty="true"
    tmp="$(state_temp_file)" || return 1
    if ! MSYS2_ENV_CONV_EXCL="REALITY_JQ_SPIDER_X" REALITY_JQ_SPIDER_X="$REALITY_SPIDER_X" jq --argjson short_ids "$REALITY_SHORT_IDS_JSON" \
        --arg port "$REALITY_PORT" \
        --arg defender_port "$REALITY_DEFENDER_PORT" \
        --arg uuid "$REALITY_UUID" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --arg public_key "$REALITY_PUBLIC_KEY" \
        --arg default_short_id "$REALITY_DEFAULT_SHORT_ID" \
        --arg server_name "$REALITY_SERVER_NAME" \
        --arg flow "$flow" \
        --arg hash32 "$hash32" \
        --arg listen_scope "ipv4" \
        --arg created_at "$timestamp" \
        --arg link "$link" \
        --arg clients_empty "$clients_empty" '
        .vless_reality = {
          "port": ($port|tonumber),
          "defender_port": ($defender_port|tonumber),
          "uuid": $uuid,
          "private_key": $private_key,
          "public_key": $public_key,
          "short_ids": $short_ids,
          "default_short_id": $default_short_id,
          "server_name": $server_name,
          "flow": $flow,
          "listen_scope": $listen_scope,
          "spider_x": env.REALITY_JQ_SPIDER_X,
          "empty_clients": ($clients_empty == "true"),
          "created_at": $created_at,
          "link": $link
        } |
        if $hash32 != "" then .vless_reality.hash32 = $hash32 else . end
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[状态] 生成 Reality 状态失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[状态] 写入 Reality 状态失败。"
        return 1
    fi
    ensure_config_security || return 1
}

mask_value() {
    local value="${1:-}"
    local keep="${2:-4}"
    local len

    len="${#value}"
    if [[ -z "$value" ]]; then
        printf '%s' "(空)"
    elif ((len <= keep)); then
        printf '%s' "****"
    else
        printf '%s****' "${value:0:keep}"
    fi
}

mask_share_link() {
    local link="$1"

    printf '%s' "$link" |
        sed -E 's/(pbk=)[^&#]+/\1****/g; s/(sid=)[^&#]+/\1****/g; s/(encryption=)[^&#]+/\1****/g; s/(fm=)[^&#]+/\1****/g'
}

xray_test_temp_config() {
    local config_path="$1"
    local log_file

    [[ -x "$BIN_PATH" ]] || {
        echo "[i] 未检测到 xray，已跳过临时配置 xray run -test。"
        return 0
    }
    log_file="$(mktemp)" || return 1
    if "$BIN_PATH" run -test -c "$config_path" >"$log_file" 2>&1; then
        rm -f "$log_file"
        echo "[✓] 临时配置 xray run -test 通过"
        return 0
    fi
    echo "[!] 临时配置 xray run -test 未通过，真实配置未被修改。"
    sed -n '1,80p' "$log_file" | redact_sensitive_stream
    rm -f "$log_file"
    return 0
}

write_test_config_out() {
    local config_path="$1"
    local output="${IKE_CONFIG_OUT:-}"

    [[ -n "$output" ]] && env_truthy "${IKE_TEST_MODE:-}" || return 0
    mkdir -p "$(dirname "$output")" || return 1
    cp "$config_path" "$output" || return 1
    chmod 600 "$output" 2>/dev/null || true
    echo "[test] offline config written: $output"
}

print_reality_dry_run() {
    local temp_config="$1"
    local link

    link="$(build_reality_share_link || true)"
    echo -e "\n${YELLOW}Reality dry-run 预览${PLAIN}"
    echo "----------------------------------------"
    echo "入口端口: ${REALITY_PORT}"
    echo "Defender: 127.0.0.1:${REALITY_DEFENDER_PORT}"
    echo "SNI: ${REALITY_SERVER_NAME}"
    echo "Flow: ${REALITY_FLOW:-无}"
    echo "ShortID: $(mask_value "$REALITY_DEFAULT_SHORT_ID" 2)"
    echo "PublicKey: $(mask_value "$REALITY_PUBLIC_KEY" 6)"
    [[ -n "$link" ]] && echo "Masked Link: $(mask_share_link "$link")"
    echo "将写入 inbound:"
    echo "- ${REALITY_TAG}"
    echo "- ${REALITY_DEFENDER_TAG}"
    echo "将写入 routing:"
    echo "- ${REALITY_DEFENDER_TAG} + full:${REALITY_SERVER_NAME} -> direct"
    echo "- ${REALITY_DEFENDER_TAG} -> ${BLOCK_OUTBOUND_TAG}"
    jq empty "$temp_config" >/dev/null && echo "[✓] 临时 JSON 结构有效"
    xray_test_temp_config "$temp_config"
    echo "不会修改真实配置。"
}

install_reality() {
    local tmp clients_json flow config_source base_tmp

    config_source="$CONFIG_FILE"
    if [[ "${REALITY_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${REALITY_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[Reality] 配置备份失败。"
            return 1
        }
    fi

    flow="$REALITY_FLOW_DEFAULT"
    [[ ${REALITY_FLOW+x} ]] && flow="$(flow_state_value "$REALITY_FLOW")"
    flow="$(flow_config_value "$flow" || true)"
    if [[ "${REALITY_EMPTY_CLIENTS:-false}" == "true" ]]; then
        clients_json='[]'
    elif [[ -n "$flow" ]]; then
        clients_json="$(jq -cn --arg uuid "$REALITY_UUID" --arg flow "$flow" '[{"id": $uuid, "flow": $flow, "email": "reality@xray"}]')" || return 1
    else
        clients_json="$(jq -cn --arg uuid "$REALITY_UUID" '[{"id": $uuid, "email": "reality@xray"}]')" || return 1
    fi

    tmp="$(config_temp_file "${REALITY_DRY_RUN:-false}")" || return 1
    if ! MSYS2_ENV_CONV_EXCL="REALITY_JQ_SPIDER_X" REALITY_JQ_SPIDER_X="$REALITY_SPIDER_X" jq --arg tag "$REALITY_TAG" \
        --arg defender_tag "$REALITY_DEFENDER_TAG" \
        --arg block "$BLOCK_OUTBOUND_TAG" \
        --arg port "$REALITY_PORT" \
        --arg defender_port "$REALITY_DEFENDER_PORT" \
        --arg sni "$REALITY_SERVER_NAME" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --arg min_client_ver "$REALITY_MIN_CLIENT_VERSION" \
        --argjson short_ids "$REALITY_SHORT_IDS_JSON" \
        --argjson clients "$clients_json" '
        def has_defender_tag:
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $defender_tag) else . == $defender_tag end));
        def reality_rule:
          (.type == "field") and has_defender_tag;
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag and .tag != $defender_tag))) |
        .inbounds += [
          {
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": ($port|tonumber),
            "protocol": "vless",
            "settings": {
              "clients": $clients,
              "decryption": "none"
            },
            "streamSettings": {
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "target": ("127.0.0.1:" + $defender_port),
                "show": false,
                "xver": 0,
                "minClientVer": $min_client_ver,
                "spiderX": env.REALITY_JQ_SPIDER_X,
                "shortIds": $short_ids,
                "privateKey": $private_key,
                "serverNames": [$sni]
              }
            },
            "sniffing": {
              "enabled": true,
              "destOverride": ["http", "tls"]
            }
          },
          {
            "tag": $defender_tag,
            "listen": "127.0.0.1",
            "port": ($defender_port|tonumber),
            "protocol": "dokodemo-door",
            "settings": {
              "port": 443,
              "address": $sni,
              "network": "tcp"
            },
            "sniffing": {
              "enabled": true,
              "routeOnly": true,
              "destOverride": ["tls"]
            }
          }
        ] |
        .routing = (.routing // {}) |
        .routing.rules = ([
          {"type": "field", "inboundTag": [$defender_tag], "domain": ["full:" + $sni], "outboundTag": "direct"},
          {"type": "field", "inboundTag": [$defender_tag], "outboundTag": $block}
        ] + ((.routing.rules // []) | map(select((reality_rule) | not))))
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[Reality] jq 生成配置失败。"
        return 1
    fi

    if [[ "${REALITY_DRY_RUN:-false}" == "true" ]]; then
        write_test_config_out "$tmp" || {
            rm -f "$tmp"
            [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
            return 1
        }
        print_reality_dry_run "$tmp"
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[Reality] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "VLESS TCP REALITY"; then
        err "[Reality] 应用配置失败，已尝试自动回滚。"
        print_reality_failure_hint
        return 1
    fi
    if ! state_set_reality; then
        rollback_config_after_state_failure "Reality"
        return 1
    fi
    state_set_meta_action "安装 VLESS TCP REALITY" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS TCP REALITY 已写入 Xray 配置。"
    print_reality_result
}

print_reality_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port defender_port uuid server_name public_key short_id spider_x private_hint flow target
    local endpoint_pair address link_port

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Reality] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Reality] 未安装。"
        return 0
    fi

    link="$(build_reality_share_link || jq -r ".${REALITY_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    port="$(jq -r ".${REALITY_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    defender_port="$(jq -r ".${REALITY_STATE_KEY}.defender_port // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    server_name="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    public_key="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
    short_id="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
    spider_x="$(jq -r ".${REALITY_STATE_KEY}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
    private_hint="$(jq -r ".${REALITY_STATE_KEY}.private_key // empty" "$STATE_FILE" 2>/dev/null)"
    flow="$(jq -r ".${REALITY_STATE_KEY}.flow // \"$REALITY_FLOW_DEFAULT\"" "$STATE_FILE" 2>/dev/null)"
    target="$(jq -r --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag).streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty' "$CONFIG_FILE" 2>/dev/null)"
    endpoint_pair="$(link_endpoint_for_tag "$port" "$REALITY_TAG" "$REALITY_STATE_KEY")"
    IFS=$'\t' read -r address link_port <<<"$endpoint_pair"

    echo -e "\n${YELLOW}--- VLESS TCP REALITY ---${PLAIN}"
    echo -e "入口端口: ${port}"
    [[ -n "$target" ]] && echo -e "Target: ${target}"
    echo -e "Defender: 127.0.0.1:${defender_port} -> ${server_name}:443"
    if [[ "$port" != "443" ]]; then
        echo -e "提示: 当前 Reality 端口不是 443，最新 Xray 可能会提示非 443 warning。"
        echo -e "提示: 如果追求更自然的 TLS/REALITY 行为，可以手动指定 443，但要确保 443 未被其它服务占用。"
    fi
    [[ -n "$link" ]] && echo -e "VLESS URL / 通用客户端链接: ${link}"
    if [[ "${CURRENT_LINK_VIEW_MODE:-dual}" == "ipv6" ]] && ! should_print_ipv6_link "ipv6" "$REALITY_TAG" "$REALITY_STATE_KEY"; then
        print_ipv6_status_hint "$REALITY_TAG" "$REALITY_STATE_KEY"
    fi
    echo "手动参数:"
    echo "  Protocol: VLESS"
    echo "  Transport: TCP"
    echo "  Security: REALITY"
    echo "  Address: ${address}"
    echo "  Port: ${link_port}"
    echo "  UUID: ${uuid}"
    echo "  Flow: ${flow:-无}"
    echo "  SNI: ${server_name}"
    echo "  PublicKey: ${public_key} (客户端字段)"
    echo "  ShortID: ${short_id}"
    echo "  Fingerprint: chrome"
    echo "  SpiderX: ${spider_x}"
    [[ -n "$private_hint" ]] && echo "  服务端 privateKey 已保存到 installer-state.json，请妥善保护，默认不显示。"
    echo "兼容提示:"
    echo "  - privateKey 是服务端字段，不需要填到客户端。"
    echo "  - publicKey 是客户端字段。"
    echo "  - 如果客户端没有 Reality/Vision 选项，说明客户端内核可能太旧。"
}

remove_reality_config() {
    local tmp

    [[ -f "$CONFIG_FILE" ]] || {
        info "[Reality] 未找到配置文件，视为未安装。"
        state_delete_key "$REALITY_STATE_KEY" || return 1
        return 0
    }
    backup_config || {
        err "[Reality] 配置备份失败。"
        return 1
    }

    tmp="$(config_temp_file)" || return 1
    if ! jq --arg tag "$REALITY_TAG" --arg defender_tag "$REALITY_DEFENDER_TAG" '
        def has_defender_tag:
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $defender_tag) else . == $defender_tag end));
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag and .tag != $defender_tag))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((has_defender_tag) | not)))
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[Reality] jq 删除配置失败。"
        return 1
    fi
    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[Reality] 写入 $CONFIG_FILE 失败。"
        return 1
    }
    apply_config "VLESS TCP REALITY 删除" || return 1
    if ! state_delete_key "$REALITY_STATE_KEY"; then
        rollback_config_after_state_failure "VLESS TCP REALITY 删除"
        return 1
    fi
    state_set_meta_action "删除 VLESS TCP REALITY" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS TCP REALITY 已删除。"
}
