#!/usr/bin/env bash
# Hysteria2 protocol install (QUIC/TLS, self-signed cert, optional Salamander obfs).

hysteria2_cert_path() { printf '%s' "${CONFIG_DIR}/hysteria2-cert.pem"; }
hysteria2_key_path() { printf '%s' "${CONFIG_DIR}/hysteria2-key.pem"; }

verify_hysteria2_cert() {
    local cert_public key_public
    openssl x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1 || return 1
    cert_public="$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null)" || return 1
    key_public="$(openssl pkey -in "$2" -passin pass: -pubout 2>/dev/null)" || return 1
    [[ -n "$cert_public" && "$cert_public" == "$key_public" ]]
}

generate_hysteria2_cert() {
    local cert="$1" key="$2" name="$3" san="DNS:$3"
    if is_valid_ipv4 "$name"; then san="IP:$name"; fi
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj "/CN=$name" -addext "subjectAltName=$san" -keyout "$key" -out "$cert" >/dev/null 2>&1 &&
        verify_hysteria2_cert "$cert" "$key"
}

hysteria2_config_port_free() {
    local config="$1" port="$2" collision
    # Hysteria always uses UDP. TCP-only inbounds may use the same number.
    collision="$(jq -r --arg tag "$HY2_TAG" --argjson port "$port" '
      def includes_port:
        tostring | split(",") | any(.[]; split("-") | map(tonumber?) |
          length > 0 and .[0] <= $port and (.[1] // .[0]) >= $port);
      def uses_udp:
        (.streamSettings.method // .streamSettings.network // "tcp") as $transport |
        (.settings.network // []) as $network |
        (.protocol == "hysteria" or $transport == "hysteria" or $transport == "mkcp" or
         $transport == "kcp" or $transport == "quic" or $transport == "masque" or
         ($transport == "xhttp" and ((.streamSettings.tlsSettings.alpn // []) | index("h3")) != null) or
         ((.protocol == "socks" or .protocol == "mixed") and .settings.udp == true) or
         (if ($network | type) == "string" then $network | split(",") else $network end | index("udp")) != null);
      any(.inbounds[]?; .tag != $tag and uses_udp and (.port | includes_port))
    ' "$config" 2>/dev/null)" || return 1
    [[ "$collision" == "false" ]]
}

read_hysteria2_listeners() {
    local port="$1" sockets
    if command -v ss >/dev/null && sockets="$(ss -H -aunp "sport = :$port" 2>/dev/null)"; then
        printf '%s' "$sockets"
    elif command -v netstat >/dev/null && sockets="$(netstat -anup 2>/dev/null)"; then
        awk -v port="$port" '$1 ~ /^udp/ && $4 ~ ("[.:]" port "$") { print }' <<<"$sockets"
    else
        err "[Hysteria2] 无法检查 UDP 监听，请检查 ss 或 netstat。"
        return 1
    fi
}

hysteria2_listeners_owned_by_xray() {
    local sockets="$1" owner record pid
    owner="$(xray_service_pid)" || return 1
    while IFS= read -r record; do
        # netstat emits PID/program in the last column. ss may list multiple owners.
        if [[ "$record" == udp* && "$record" != *"pid="* ]]; then
            [[ "${record##* }" == "$owner/"* ]] || return 1
            continue
        fi
        [[ "$record" =~ pid=([0-9]+) ]] || return 1
        while [[ "$record" =~ pid=([0-9]+) ]]; do
            pid="${BASH_REMATCH[1]}"
            [[ "$pid" == "$owner" ]] || return 1
            record="${record#*pid=$pid}"
        done
    done <<<"$sockets"
}

hysteria2_port_available() {
    local config="$1" port="$2" mode="$3" sockets
    hysteria2_config_port_free "$config" "$port" || return 1
    [[ "$mode" != "dry-run" ]] || return 0
    sockets="$(read_hysteria2_listeners "$port")" || return 1
    [[ -z "$sockets" ]] ||
        { [[ "$port" == "$HY2_OLD_PORT" ]] && xray_service_is_active && hysteria2_listeners_owned_by_xray "$sockets"; }
}

configure_hysteria2() {
    local mode="$1" operation="$2" config="$3" state="$4" port sni default_port

    HY2_EXISTING_INBOUND="$(jq -ce --arg tag "$HY2_TAG" '
      [.inbounds[]? | select(.tag == $tag)] |
      if length == 0 then "" elif length == 1 and .[0].protocol == "hysteria" then .[0]
      else error("inbound tag conflict") end
    ' "$config" 2>/dev/null)" || {
        err "[Hysteria2] 读取入站失败，请检查 $HY2_TAG 是否与其他入站冲突。"
        return 1
    }
    if [[ "$HY2_EXISTING_INBOUND" == '""' ]]; then HY2_EXISTING_INBOUND=""; fi
    HY2_SNI="localhost"
    HY2_LISTEN="0.0.0.0"
    HY2_CERT="$(hysteria2_cert_path)"
    HY2_KEY="$(hysteria2_key_path)"
    if [[ -n "$HY2_EXISTING_INBOUND" ]]; then
        HY2_OLD_PORT="$(jq -r '.port' <<<"$HY2_EXISTING_INBOUND")" || return 1
        validate_port "$HY2_OLD_PORT" || { err "[Hysteria2] 现有入站端口应为 1–65535 的单一端口。"; return 1; }
        HY2_OLD_PORT=$((10#$HY2_OLD_PORT))
        HY2_LISTEN="$(jq -r '.listen // "0.0.0.0"' <<<"$HY2_EXISTING_INBOUND")" || return 1
        HY2_CERT="$(jq -r '.streamSettings.tlsSettings.certificates[0].certificateFile // empty' <<<"$HY2_EXISTING_INBOUND")"
        HY2_KEY="$(jq -r '.streamSettings.tlsSettings.certificates[0].keyFile // empty' <<<"$HY2_EXISTING_INBOUND")"
        HY2_AUTH="$(jq -r '(.settings.clients // .settings.users)[0].auth // empty' <<<"$HY2_EXISTING_INBOUND")"
        HY2_OBFS="$(jq -r 'first(.streamSettings.finalmask.udp[]? | select(.type == "salamander") | .settings.password) // empty' <<<"$HY2_EXISTING_INBOUND")"
        sni="$(jq -r --arg key "$HY2_STATE_KEY" '.[$key].sni // empty' "$state")"
    elif [[ "$operation" != "install" ]]; then
        err "[Hysteria2] 请先安装 Hysteria2 再轮换。"
        return 1
    fi
    if [[ -z "${sni:-}" && -f "$HY2_CERT" ]]; then
        sni="$(openssl x509 -in "$HY2_CERT" -noout -subject -nameopt RFC2253 2>/dev/null |
            sed -n 's/^subject=CN=\([^,]*\).*$/\1/p')" || sni=""
    fi
    if is_valid_endpoint_hostname "${sni:-}"; then HY2_SNI="$sni"; fi

    default_port="${HY2_OLD_PORT:-443}"
    while true; do
        port="${HY2_PORT_REQUEST:-$default_port}"
        if [[ "$mode" == "interactive" ]]; then
            read -r -p "Hysteria2 UDP 端口 (默认 $default_port): " port || return 1
            port="${port:-$default_port}"
        fi
        if validate_port "$port" && hysteria2_port_available "$config" "$((10#$port))" "$mode"; then
            HY2_PORT=$((10#$port))
            break
        fi
        err "[Hysteria2] UDP 端口无效、已有监听或与配置冲突: $port"
        [[ "$mode" == "interactive" ]] || return 1
    done

    sni="${HY2_SNI_REQUEST:-}"
    if [[ "$mode" == "interactive" && -z "$HY2_EXISTING_INBOUND" ]]; then
        read -r -p "Hysteria2 证书域名或 IPv4 (默认 $HY2_SNI): " sni || return 1
    fi
    if [[ -n "$sni" && "$sni" != "$HY2_SNI" && "$operation" != "rotate-cert" &&
        ( -n "$HY2_EXISTING_INBOUND" || -e "$HY2_CERT" || -e "$HY2_KEY" ) ]]; then
        err "[Hysteria2] 更改现有证书的 SNI 请使用 ike hysteria2 rotate-cert --sni DOMAIN --yes。"
        return 1
    fi
    HY2_SNI="${sni:-$HY2_SNI}"
    if ! is_valid_endpoint_hostname "$HY2_SNI"; then
        err "[Hysteria2] SNI 必须是有效的域名或 IPv4 地址。"
        return 1
    fi
    if [[ "$mode" == "dry-run" && -z "$HY2_EXISTING_INBOUND" ]]; then
        HY2_AUTH="preview-auth"
        HY2_OBFS="preview-obfs"
    elif [[ "$operation" == "rotate-credentials" || -z "$HY2_EXISTING_INBOUND" ]]; then
        HY2_AUTH="$(openssl rand -hex 16)" || return 1
        if [[ -z "$HY2_EXISTING_INBOUND" || -n "$HY2_OBFS" ]]; then
            HY2_OBFS="$(openssl rand -hex 16)" || return 1
        fi
    fi
    if [[ -z "$HY2_AUTH" ]]; then
        err "[Hysteria2] 无法读取或生成认证凭据。"
        return 1
    fi
}

build_hysteria2_share_link() {
    local port="${HY2_PORT:-}" auth="${HY2_AUTH:-}" sni="${HY2_SNI:-}" obfs="${HY2_OBFS:-}"
    local host link_port endpoint_pair auth_uri obfs_uri sni_uri name_uri

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${HY2_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        auth="$(jq -r ".${HY2_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
        sni="$(jq -r ".${HY2_STATE_KEY}.sni // empty" "$STATE_FILE" 2>/dev/null)"
        obfs="$(jq -r ".${HY2_STATE_KEY}.obfs // empty" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$auth" ]] || return 1
    endpoint_pair="$(link_endpoint_for_tag "$port" "$HY2_TAG" "$HY2_STATE_KEY")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    auth_uri="$(url_encode "$auth")"
    obfs_uri="$(url_encode "$obfs")"
    sni_uri="$(url_encode "$sni")"
    name_uri="$(url_encode "Xray-Hysteria2")"

    printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=1' "$auth_uri" "$host" "$link_port" "$sni_uri"
    [[ -n "$obfs" ]] && printf '&obfs=salamander&obfs-password=%s' "$obfs_uri"
    printf '#%s' "$name_uri"
}

render_hysteria2_config() {
    local config="$1" output="$2" cert="$3" key="$4" operation="$5"
    if ! jq --arg tag "$HY2_TAG" --arg listen "$HY2_LISTEN" --argjson port "$HY2_PORT" \
        --arg auth "$HY2_AUTH" --arg obfs "$HY2_OBFS" --arg cert "$cert" --arg key "$key" --arg operation "$operation" '
      def rotate_credentials:
        (if .settings.clients != null then .settings.clients[0].auth = $auth
         else .settings.users[0].auth = $auth end) |
        if $obfs != "" then
          .streamSettings.finalmask.udp |= map(if .type == "salamander" then .settings.password = $obfs else . end)
        else . end;
      if any(.inbounds[]?; .tag == $tag) then
        .inbounds |= map(if .tag != $tag then . else
          .port = $port |
          (if $operation == "rotate-credentials" then rotate_credentials else . end) |
          .streamSettings.tlsSettings.certificates[0] |= (.certificateFile = $cert | .keyFile = $key)
        end)
      else
        .inbounds = ((.inbounds // []) + [{
          tag: $tag, listen: $listen, port: $port, protocol: "hysteria",
          settings: {version: 2, clients: [{auth: $auth, email: "hysteria2@xray"}]},
          streamSettings: {
            network: "hysteria", security: "tls",
            tlsSettings: {alpn: ["h3"], certificates: [{certificateFile: $cert, keyFile: $key}]},
            hysteriaSettings: {version: 2},
            finalmask: {udp: [{type: "salamander", settings: {password: $obfs}}]}
          }
        }])
      end
    ' "$config" >"$output" 2>/dev/null; then
        err "[Hysteria2] jq 生成配置失败。"
        return 1
    fi
}

render_hysteria2_state() (
    local CONFIG_DIR="$DEPLOYMENT_DIR/config" CONFIG_FILE="$1" STATE_FILE="$DEPLOYMENT_DIR/config/installer-state.json"
    local ASSET_DIR="$DEPLOYMENT_DIR/base-assets"
    local output="$2" fingerprint="$3" action="$4" link timestamp
    if [[ -n "${XRAY_ONECLICK_ENDPOINT:-}" && -z "$(endpoint_custom_value)" ]]; then
        apply_env_endpoint_if_needed || return 1
    fi
    link="$(build_hysteria2_share_link)" || return 1
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! jq --arg key "$HY2_STATE_KEY" --arg tag "$HY2_TAG" --argjson port "$HY2_PORT" \
        --arg auth "$HY2_AUTH" --arg sni "$HY2_SNI" --arg obfs "$HY2_OBFS" --arg link "$link" \
        --arg updated "$timestamp" --arg listen_scope "$(protocol_listen_scope "$HY2_LISTEN")" \
        --arg fingerprint "$fingerprint" --arg action "$action" '
        (.[$key] // {}) as $old |
        ($old + {tag: $tag, port: $port, auth: $auth, sni: $sni, obfs: $obfs, link: $link,
                 listen_scope: $listen_scope, certificate_sha256: $fingerprint}) as $new |
        if $new == $old then . else
          .[$key] = ($new + {updated_at: $updated}) |
          .meta = ((.meta // {}) + {last_action: $action, last_updated_at: $updated})
        end
    ' "$STATE_FILE" >"$output" 2>/dev/null; then
        err "[Hysteria2] 生成状态文件失败。"
        return 1
    fi
)

xray_supports_hysteria2() {
    timeout 30 "$1" run -test -c "$DEPLOYMENT_DIR/hysteria2-probe.json" >/dev/null 2>&1
}

deploy_hysteria2() {
    local mode="$1" operation="$2"
    local config="$DEPLOYMENT_DIR/config/config.json" state="$DEPLOYMENT_DIR/config/installer-state.json"
    local proposed="$DEPLOYMENT_DIR/config.json" proposed_state="$DEPLOYMENT_DIR/installer-state.json"
    local HY2_EXISTING_INBOUND="" HY2_OLD_PORT="" HY2_PORT HY2_SNI HY2_AUTH HY2_LISTEN HY2_CERT HY2_KEY HY2_OBFS=""
    local cert key fingerprint sockets action="安装 Hysteria2"
    local config_changed=true cert_changed=false

    if [[ "$mode" == "dry-run" ]] && ! command -v jq >/dev/null; then
        err "[Hysteria2] 预览需要 jq。"
        return 1
    fi
    stage_initial_xray_files "$ASSET_DIR" || return 1
    configure_hysteria2 "$mode" "$operation" "$config" "$state" || return 1

    if [[ "$mode" == "dry-run" ]]; then
        render_hysteria2_config "$config" "$proposed" "$HY2_CERT" "$HY2_KEY" "$operation" || return 1
        if env_truthy "${IKE_TEST_MODE:-}"; then write_test_config_out "$proposed" || return 1; fi
        info "[dry-run] Hysteria2 使用 UDP $HY2_PORT，证书 SNI 为 $HY2_SNI。"
        return 0
    fi

    cert="$HY2_CERT"
    key="$HY2_KEY"
    if [[ "$operation" == "rotate-cert" ]]; then
        if [[ "$cert" != "$(hysteria2_cert_path)" || "$key" != "$(hysteria2_key_path)" ]] ||
            ! jq -e --arg tag "$HY2_TAG" --arg cert "$cert" --arg key "$key" '
              [.inbounds[]? | select(.tag != $tag) | .. | strings | select(. == $cert or . == $key)] | length == 0
            ' "$config" >/dev/null 2>&1; then
            err "[Hysteria2] 当前证书由外部管理或被其他入站引用，请在原证书管理流程中轮换。"
            return 1
        fi
        action="轮换 Hysteria2 证书"
        cert_changed=true
    elif [[ -z "$HY2_EXISTING_INBOUND" && ! -e "$cert" && ! -L "$cert" && ! -e "$key" && ! -L "$key" ]]; then
        cert_changed=true
    elif [[ "$operation" == "rotate-credentials" ]]; then
        action="轮换 Hysteria2 凭据"
    fi
    if [[ "$cert_changed" == "true" ]]; then
        cert="$DEPLOYMENT_DIR/cert.pem"
        key="$DEPLOYMENT_DIR/key.pem"
        if ! generate_hysteria2_cert "$cert" "$key" "$HY2_SNI"; then
            err "[Hysteria2] 生成或验证自签证书失败。"
            return 1
        fi
    elif ! verify_hysteria2_cert "$cert" "$key"; then
        err "[Hysteria2] 证书已过期、无法读取或与私钥不匹配。请检查现有证书文件，已安装节点可使用 rotate-cert --yes。"
        return 1
    fi
    fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2)" || return 1

    local test_config="$proposed" channel
    render_hysteria2_config "$config" "$proposed" "$HY2_CERT" "$HY2_KEY" "$operation" || return 1
    if [[ "$operation" == "install" && "$HY2_PORT" == "$HY2_OLD_PORT" ]]; then
        config_changed=false
        test_config="$config"
    elif [[ "$cert_changed" == "true" ]]; then
        test_config="$DEPLOYMENT_DIR/validate.json"
        render_hysteria2_config "$config" "$test_config" "$cert" "$key" "$operation" || return 1
    fi
    if ! jq --arg tag "$HY2_TAG" '
        {inbounds: [.inbounds[] | select(.tag == $tag)], outbounds: [{protocol: "freedom"}]}
    ' "$test_config" >"$DEPLOYMENT_DIR/hysteria2-probe.json" 2>/dev/null; then
        err "[Hysteria2] 生成 Xray 协议能力检查配置失败。"
        return 1
    fi
    channel="$(normalize_xray_channel "${XRAY_CHANNEL_REQUEST:-${XRAY_CHANNEL:-stable}}")" || return 1
    prepare_deployment_core "${XRAY_VERSION_REQUEST:-${XRAY_VERSION:-latest}}" "$channel" false xray_supports_hysteria2 || return 1
    validate_config_file "$test_config" "$DEPLOYMENT_BINARY" "$DEPLOYMENT_ASSETS" || return 1
    render_hysteria2_state "$proposed" "$proposed_state" "$fingerprint" "$action" || return 1

    mkdir -p "$CONFIG_DIR" || return 1
    mkdir -p "$ASSET_DIR" || return 1
    publish_deployment_core || return 1
    if [[ "$cert_changed" == "true" ]]; then
        publish_deployment_file "$cert" "$HY2_CERT" 644 &&
            publish_deployment_file "$key" "$HY2_KEY" 600 || return 1
    fi
    if [[ "$config_changed" == "true" ]]; then
        publish_deployment_file "$proposed" "$CONFIG_FILE" 600 || return 1
    fi
    create_deployment_service || return 1
    if [[ "$config_changed" == "true" || "$DEPLOYMENT_CORE_CHANGED" == "true" ]] || ! xray_service_is_active; then
        restart_deployment_service || return 1
    fi
    if ! sockets="$(read_hysteria2_listeners "$HY2_PORT")" || [[ -z "$sockets" ]] ||
        ! hysteria2_listeners_owned_by_xray "$sockets"; then
        err "[Hysteria2] Xray 未成功监听 UDP $HY2_PORT。"
        return 1
    fi
    if ! cmp -s -- "$proposed_state" "$STATE_FILE"; then
        publish_deployment_file "$proposed_state" "$STATE_FILE" 600 || return 1
    fi
    ok "[完成] $action，Xray 正在监听 UDP $HY2_PORT。"
}

install_hysteria2() {
    local mode="${1:-cli}" operation="${2:-install}"
    if [[ "$mode" == "dry-run" ]]; then
        run_deployment_transaction deploy_hysteria2 "$mode" "$operation"
        return
    fi
    with_xray_lock install_hysteria2_live "$mode" "$operation"
}

install_hysteria2_live() {
    prepare_system && check_xray_service_ownership || return 1
    run_deployment_transaction deploy_hysteria2 "$@" || return 1
    print_hysteria2_result
}

print_hysteria2_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port auth sni obfs fingerprint

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Hysteria2] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${HY2_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Hysteria2] 未安装。"
        return 0
    fi

    port="$(jq -r ".${HY2_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    auth="$(jq -r ".${HY2_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
    sni="$(jq -r ".${HY2_STATE_KEY}.sni // empty" "$STATE_FILE" 2>/dev/null)"
    obfs="$(jq -r ".${HY2_STATE_KEY}.obfs // empty" "$STATE_FILE" 2>/dev/null)"
    fingerprint="$(jq -r ".${HY2_STATE_KEY}.certificate_sha256 // empty" "$STATE_FILE" 2>/dev/null)"
    link="$(build_hysteria2_share_link 2>/dev/null || jq -r ".${HY2_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"

    echo -e "\n${YELLOW}--- Hysteria2 ---${PLAIN}"
    echo -e "端口(UDP): ${port}"
    echo -e "认证密码: ${auth}"
    echo -e "证书 SNI: ${sni}"
    [[ -z "$fingerprint" ]] || echo "证书 SHA-256: $fingerprint"
    echo -e "Obfs(salamander) 密码: ${obfs}"
    echo -e "提示: 兼容链接中的 insecure=1 会跳过证书校验。"
    [[ -n "$link" ]] && echo -e "链接: ${link}"
    return 0
}

remove_hysteria2_config() {
    remove_simple_inbound_config "$HY2_TAG" "$HY2_STATE_KEY" "Hysteria2" || return 1
    if ! rm -f "$(hysteria2_cert_path)" "$(hysteria2_key_path)"; then
        err "[Hysteria2] 配置已删除，但清理证书文件失败。"
        return 1
    fi
}
