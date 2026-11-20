#!/usr/bin/env bash
# Xray-OneClick Xray-core download, install, and upgrade.

replace_xray_binary() {
    local new_binary="$1"
    local backup_path=""
    local staging_path had_original="false"

    validate_xray_binary_path "$BIN_PATH" || return 1
    [[ ! -d "$BIN_PATH" ]] || return 1
    XRAY_REPLACED_BACKUP_PATH=""
    XRAY_REPLACED_HAD_ORIGINAL="false"
    staging_path="$(mktemp "${BIN_PATH}.new.XXXXXX")" || return 1

    if ! install -m 755 "$new_binary" "$staging_path"; then
        rm -f "$staging_path"
        err "[核心] 写入临时二进制失败: $staging_path"
        return 1
    fi

    if [[ -e "$BIN_PATH" || -L "$BIN_PATH" ]]; then
        backup_path="$(mktemp "${BIN_PATH}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")" || {
            rm -f "$staging_path"
            return 1
        }
        rm -f "$backup_path"
        if ! cp -a -- "$BIN_PATH" "$backup_path"; then
            rm -f "$staging_path"
            err "[核心] 备份旧 Xray 二进制失败，已中止更新。"
            return 1
        fi
        had_original="true"
    fi

    if ! mv -f -- "$staging_path" "$BIN_PATH"; then
        rm -f "$staging_path"
        [[ -z "$backup_path" ]] || rm -f "$backup_path"
        err "[核心] 替换 $BIN_PATH 失败，已中止更新。"
        return 1
    fi

    XRAY_REPLACED_BACKUP_PATH="$backup_path"
    XRAY_REPLACED_HAD_ORIGINAL="$had_original"
}

rollback_xray_binary_replacement() {
    local backup_path="${1:-}"
    local had_original="${2:-false}"

    if [[ "$had_original" == "true" ]]; then
        if [[ -z "$backup_path" || ( ! -e "$backup_path" && ! -L "$backup_path" ) ]]; then
            err "[核心] 回滚所需的旧 Xray 二进制不存在。"
            return 1
        fi
        if ! mv -f -- "$backup_path" "$BIN_PATH"; then
            err "[核心] 恢复旧 Xray 二进制失败: $BIN_PATH（原件 $backup_path）"
            return 1
        fi
    elif ! rm -f -- "$BIN_PATH"; then
        err "[核心] 回滚时无法移除新 Xray 二进制: $BIN_PATH"
        return 1
    fi
    XRAY_REPLACED_BACKUP_PATH=""
    XRAY_REPLACED_HAD_ORIGINAL="false"
}

detect_xray_version() {
    local binary="${1:-$BIN_PATH}"
    local version_output version

    if [[ ! -x "$binary" ]]; then
        printf '%s' "未安装"
        return 1
    fi
    version_output="$(timeout 10 "$binary" version 2>/dev/null)" || return 1
    version="$(printf '%s\n' "$version_output" | sed -nE 's/^Xray[[:space:]]+([0-9][^[:space:]]*).*/\1/p; s/^v?([0-9]+(\.[0-9]+)+).*/\1/p' | head -n 1)"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

detect_xray_feature_support() {
    local version

    version="$(detect_xray_version 2>/dev/null || true)"
    if [[ -z "$version" || "$version" == "未安装" ]]; then
        diag_warn "Xray 未安装，无法判断 Reality/XHTTP/FinalMask 兼容性"
        return 0
    fi
    diag_info "Xray 当前版本: $version"
    diag_info "Reality 通常需要较新的 Xray-core；最终以 xray run -test 和客户端实测为准。"
    diag_info "XHTTP/FinalMask 属于高级兼容能力，建议保持 Xray-core 为最新版本。"
}

print_xray_version_summary() {
    echo -e "\n${YELLOW}Xray 版本信息${PLAIN}"
    echo "----------------------------------------"
    echo "Binary: $BIN_PATH"
    echo "Version: $(detect_xray_version 2>/dev/null || printf '%s' '未安装')"
    detect_xray_feature_support
}

github_mirror_urls() {
    local original="$1"
    local mirrors="${XRAY_GITHUB_MIRRORS:-}"
    local mirror
    local -a mirror_list

    printf '%s\n' "$original"
    IFS=',' read -r -a mirror_list <<<"$mirrors"
    for mirror in "${mirror_list[@]}"; do
        mirror="${mirror//[[:space:]]/}"
        [[ -n "$mirror" ]] || continue
        printf '%s%s\n' "$mirror" "$original"
    done
}

download_one_url() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
            -H "User-Agent: xray-installer" -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        timeout 120 wget -q -T 20 -O "$output" "$url"
    else
        err "[核心] 缺少 curl 或 wget，无法下载。"
        return 1
    fi
}

download_with_mirrors() {
    local original_url="$1"
    local output="$2"
    local digest="$3" url
    local -a urls=()

    mapfile -t urls < <(github_mirror_urls "$original_url")
    for url in "${urls[@]}"; do
        if download_one_url "$url" "$output" && [[ -s "$output" ]] &&
            verify_xray_asset_digest "$output" "$digest"; then
            return 0
        fi
        rm -f "$output"
        info "[核心] 当前 URL 失败，尝试下一个镜像..."
    done
    err "[核心] 无法取得通过 SHA-256 校验的 ${XRAY_ASSET}，请检查 GitHub 网络或 XRAY_GITHUB_MIRRORS。"
    return 1
}

normalize_xray_channel() {
    case "${1:-stable}" in
        stable | "") printf '%s' "stable" ;;
        prerelease | pre-release | pre) printf '%s' "prerelease" ;;
        *) return 1 ;;
    esac
}

xray_release_api_for_channel() {
    case "${1:-stable}" in
        stable) printf '%s' "$XRAY_RELEASE_API_STABLE" ;;
        prerelease) printf '%s' "$XRAY_RELEASE_API_PRERELEASE" ;;
        *) return 1 ;;
    esac
}

xray_release_metadata_url() {
    local version="${1:-latest}"
    local channel="${2:-stable}"

    channel="$(normalize_xray_channel "$channel")" || return 1
    if [[ "$version" == "latest" ]]; then
        xray_release_api_for_channel "$channel"
    else
        [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9.-]+)?$ ]] || {
            err "[核心] 版本格式有误，请使用 vX.Y.Z 格式。"
            return 1
        }
        printf '%s/%s' "$XRAY_RELEASE_API_TAG_BASE" "$version"
    fi
}

xray_release_metadata() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local api tmp release_json

    api="$(xray_release_metadata_url "$version" "$channel")" || return 1
    tmp="$(mktemp)" || return 1
    if ! download_one_url "$api" "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        if [[ "$version" == "latest" ]]; then
            err "[核心] 无法访问 Xray ${channel} release API；可使用 --xray-version 指定版本。"
        else
            err "[核心] 无法访问 Xray release ${version}；可使用 --xray-version 指定版本。"
        fi
        return 1
    fi

    if [[ "$version" == "latest" && "$channel" == "prerelease" ]]; then
        release_json="$(jq -c --arg asset "$XRAY_ASSET" 'map(select(.prerelease == true and any(.assets[]?; .name == $asset))) | .[0] // empty' "$tmp")"
        [[ -n "$release_json" && "$release_json" != "null" ]] || {
            rm -f "$tmp"
            err "[核心] prerelease 通道中未找到匹配 ${XRAY_ASSET} 的 release。"
            return 1
        }
        printf '%s' "$release_json"
    else
        cat "$tmp"
    fi
    rm -f "$tmp"
}

xray_release_asset_info() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local release_json asset_info

    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    release_json="$(xray_release_metadata "$version" "$channel")" || return 1
    asset_info="$(printf '%s' "$release_json" | jq -er --arg asset "$XRAY_ASSET" '
      select(.draft != true) as $release |
      first($release.assets[]? | select(.name == $asset)) as $matched |
      [
        $matched.browser_download_url,
        $release.tag_name,
        (($release.prerelease // false) | tostring),
        ($matched.digest // "-")
      ] | @tsv
    ' 2>/dev/null)" || return 1
    [[ -n "$asset_info" ]] || return 1
    printf '%s' "$asset_info"
}

verify_xray_asset_digest() {
    local archive="$1"
    local digest="${2:-}"
    local algorithm expected actual

    algorithm="${digest%%:*}"
    expected="${digest#*:}"
    algorithm="${algorithm,,}"
    expected="${expected,,}"
    if [[ "$algorithm" != "sha256" || ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
        err "[核心] 缺少有效的 SHA-256 资产摘要。"
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive" | awk '{print tolower($1)}')"
    elif command -v openssl >/dev/null 2>&1; then
        actual="$(openssl dgst -sha256 "$archive" 2>/dev/null | awk '{print tolower($NF)}')"
    else
        err "[核心] 缺少 sha256sum/openssl，无法校验 Xray 资产摘要。"
        return 1
    fi

    if [[ "$actual" != "$expected" ]]; then
        err "[核心] Xray 资产 SHA-256 校验失败。"
        err "[核心] expected=$expected"
        err "[核心] actual=${actual:-无法计算}"
        return 1
    fi
    info "[核心] Xray 资产 SHA-256 校验通过。"
}

verify_xray_archive() {
    local zip_path="$1"
    local extract_dir="$2"
    local expected_version="$3" xray_bin go_arch version_output

    [[ -s "$zip_path" ]] || {
        err "[核心] Xray 压缩包不存在或为空。"
        return 1
    }
    unzip -t "$zip_path" >/dev/null || {
        err "[核心] unzip -t 校验失败。"
        return 1
    }
    unzip -qo "$zip_path" xray geoip.dat geosite.dat -d "$extract_dir" || {
        err "[核心] 解压失败。"
        return 1
    }
    xray_bin="${extract_dir}/xray"
    [[ -f "$xray_bin" && ! -L "$xray_bin" ]] || {
        err "[核心] 压缩包中未找到 xray 二进制。"
        return 1
    }
    chmod +x "$xray_bin" || return 1
    case "$XRAY_ASSET" in
        Xray-linux-64.zip) go_arch=amd64 ;;
        Xray-linux-32.zip) go_arch=386 ;;
        Xray-linux-arm32-*) go_arch=arm ;;
        Xray-linux-arm64-*) go_arch=arm64 ;;
        Xray-linux-loong64.zip) go_arch=loong64 ;;
        *) go_arch="${XRAY_ASSET#Xray-linux-}"; go_arch="${go_arch%.zip}" ;;
    esac
    if ! version_output="$(timeout 10 "$xray_bin" version 2>/dev/null)" ||
        [[ "$version_output" != "Xray ${expected_version#v} "* || "$version_output" != *" linux/$go_arch)"* ]]; then
        err "[核心] 解压后的 Xray 无法运行或与发布版本、架构不符（$expected_version / $go_arch）。"
        return 1
    fi
    XRAY_EXTRACTED_BINARY="$xray_bin"
}

download_xray_core() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local tmpdir="$3"
    local asset_info url zip_path resolved_version prerelease digest

    mkdir -p "$tmpdir" || return 1
    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    XRAY_DOWNLOAD_CHANNEL="$channel"
    XRAY_DOWNLOAD_IS_PRERELEASE="false"
    XRAY_DOWNLOAD_VERSION="$version"
    XRAY_DOWNLOAD_DIGEST=""
    asset_info="$(xray_release_asset_info "$version" "$channel")" || {
        err "[核心] 无法解析 Xray 下载地址。"
        return 1
    }
    IFS=$'\t' read -r url resolved_version prerelease digest <<<"$asset_info"
    if [[ ! "$resolved_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9.-]+)?$ ||
        ( "$version" != "latest" && "$version" != "$resolved_version" ) ||
        ( "$channel" == "stable" && "$prerelease" != "false" ) ||
        ( "$version" == "latest" && "$channel" == "prerelease" && "$prerelease" != "true" ) ||
        "$url" != "https://github.com/XTLS/Xray-core/releases/download/${resolved_version}/${XRAY_ASSET}" ]]; then
        err "[核心] 官方 release 标签、通道或资产地址与请求不符。"
        return 1
    fi
    if [[ -z "$digest" || "$digest" == "-" ]]; then
        info "[核心] release API 未提供摘要，尝试读取 GitHub 官方 .dgst 文件。"
        if ! download_one_url "${url}.dgst" "$tmpdir/checksums"; then
            err "[核心] 无法从 GitHub 官方来源取得摘要，停止安装。"
            return 1
        fi
        digest="$(awk '$1 == "SHA2-256=" {print "sha256:" $2}' "$tmpdir/checksums")"
    fi
    [[ "$digest" =~ ^sha256:[[:xdigit:]]{64}$ ]] || {
        err "[核心] 无法取得可信 SHA-256，停止安装。"
        return 1
    }
    XRAY_DOWNLOAD_VERSION="$resolved_version"
    XRAY_DOWNLOAD_IS_PRERELEASE="$prerelease"
    zip_path="${tmpdir}/${XRAY_ASSET}"
    download_with_mirrors "$url" "$zip_path" "$digest" || return 1
    verify_xray_archive "$zip_path" "$tmpdir" "$resolved_version"
}

prepare_deployment_core() {
    local version="$1" channel="$2" force="$3" capability="${4:-}"
    local installed asset download_dir="$DEPLOYMENT_DIR/core"

    if [[ "$force" != "true" ]] && installed="$(detect_xray_version)"; then
        if [[ -z "$capability" ]] || "$capability" "$BIN_PATH"; then
            info "[核心] Xray 已安装: $installed"
            return 0
        fi
        info "[核心] 已安装的 Xray $installed 未通过协议能力检查，正在准备 ${channel} 核心。"
    fi

    info "[核心] 下载 Xray $version（$channel / $XRAY_ASSET）..."
    download_xray_core "$version" "$channel" "$download_dir" || return 1
    if [[ -n "$capability" ]] && ! "$capability" "$XRAY_EXTRACTED_BINARY"; then
        err "[核心] 新 Xray 未通过协议能力检查，现有部署已保留。"
        return 1
    fi
    # A custom ext: rule may need an existing data file to validate the new core.
    for asset in "$ASSET_DIR"/*; do
        [[ -e "$asset" ]] || continue
        [[ -e "$download_dir/${asset##*/}" ]] || ln -s "$asset" "$download_dir/${asset##*/}" || return 1
    done
    DEPLOYMENT_BINARY="$XRAY_EXTRACTED_BINARY"
    DEPLOYMENT_ASSETS="$download_dir"
    DEPLOYMENT_CORE_CHANGED=true
}

publish_deployment_core() {
    [[ "$DEPLOYMENT_CORE_CHANGED" == "true" ]] || return 0
    local asset
    mkdir -p "$(dirname "$BIN_PATH")" "$ASSET_DIR" || return 1
    replace_xray_binary "$DEPLOYMENT_BINARY" || return 1
    DEPLOYMENT_REPLACED_BINARY=true
    for asset in geoip.dat geosite.dat; do
        publish_deployment_file "$DEPLOYMENT_ASSETS/$asset" "$ASSET_DIR/$asset" 644 || return 1
    done
}

deploy_xray_core() {
    local version="$1" channel="$2" force="$3" restart="$4" mode="$5" capability="${6:-}"
    local config="$CONFIG_FILE"

    service_manager_ready && check_xray_service_ownership || return 1
    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
        validate_json_object "$CONFIG_FILE" || return 1
    fi
    prepare_deployment_core "$version" "$channel" "$force" "$capability" || return 1

    if [[ "$mode" == "install" ]]; then
        stage_initial_xray_files "$DEPLOYMENT_ASSETS" || return 1
        config="$DEPLOYMENT_DIR/config/config.json"
    fi
    if [[ -f "$config" || "$restart" == "always" ]]; then
        validate_config_file "$config" "$DEPLOYMENT_BINARY" "$DEPLOYMENT_ASSETS" || return 1
    fi

    publish_deployment_core || return 1
    if [[ "$mode" == "install" ]]; then
        mkdir -p "$CONFIG_DIR" || return 1
        if [[ ! -f "$CONFIG_FILE" ]]; then
            publish_deployment_file "$config" "$CONFIG_FILE" 600 || return 1
        fi
        if [[ ! -f "$STATE_FILE" ]]; then
            publish_deployment_file "$DEPLOYMENT_DIR/config/installer-state.json" "$STATE_FILE" 600 || return 1
        fi
        mkdir -p "$ASSET_DIR" || return 1
        create_deployment_service || return 1
    fi
    if [[ "$restart" == "always" ]] ||
        { [[ "$restart" == "if-active" && "$DEPLOYMENT_CORE_CHANGED" == "true" ]] && xray_service_is_active; }; then
        restart_deployment_service || return 1
    fi
    if [[ "$DEPLOYMENT_CORE_CHANGED" == "true" ]]; then
        ok "[核心] Xray $XRAY_DOWNLOAD_VERSION 安装/更新完成（$channel / prerelease: $XRAY_DOWNLOAD_IS_PRERELEASE）。"
    fi
}

preview_xray_upgrade() {
    local version="$1" channel="$2"
    download_xray_core "$version" "$channel" "$DEPLOYMENT_DIR" || return 1
    echo "[dry-run] Xray 通道: $channel / 版本: $XRAY_DOWNLOAD_VERSION / prerelease: $XRAY_DOWNLOAD_IS_PRERELEASE"
    echo "[dry-run] 已校验资产与二进制: $XRAY_ASSET"
}

upgrade_xray_core() {
    local version="${1:-latest}" channel="${2:-stable}" dry_run="${3:-false}" restart="${4:-false}"
    channel="$(normalize_xray_channel "$channel")" || return 1
    detect_arch || return 1
    if [[ "$dry_run" == "true" ]]; then
        run_deployment_transaction preview_xray_upgrade "$version" "$channel"
        return
    fi
    install_dependencies || return 1
    if [[ "$restart" == "true" ]]; then restart=always; fi
    with_xray_lock run_deployment_transaction deploy_xray_core "$version" "$channel" true "$restart" upgrade
}

apply_config() {
    local context="${1:-}"

    if ! ensure_default_safety_blocks || ! ensure_config_security; then
        err "[回滚] 配置预处理失败，正在恢复本次备份。"
        restore_config_backup || true
        return 1
    fi
    [[ -n "$context" ]] && info "[${context}] 正在校验 Xray 配置..."
    if ! validate_config_file; then
        [[ -n "$context" ]] && err "[失败] [${context}] Xray 配置校验失败。"
        err "[回滚] 已检测到配置应用失败，正在恢复本次备份。"
        if restore_config_backup; then
            info "[回滚] 正在重启服务以加载恢复后的配置..."
            if restart_service; then
                ok "[回滚] 恢复成功，服务已重新加载本次备份。"
            else
                err "[回滚] 恢复后的配置校验通过，但服务重启失败。"
            fi
        else
            err "[回滚] 恢复失败，请手动检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
        fi
        return 1
    fi

    [[ -n "$context" ]] && info "[${context}] 正在重启服务..."
    if ! restart_service; then
        [[ -n "$context" ]] && err "[失败] [${context}] 服务重启失败。"
        err "[回滚] 已检测到配置应用失败，正在恢复本次备份。"
        if restore_config_backup; then
            info "[回滚] 正在重启服务以加载恢复后的配置..."
            if restart_service; then
                ok "[回滚] 恢复成功，服务已重新加载本次备份。"
            else
                err "[回滚] 恢复后的配置校验通过，但服务重启仍失败。"
            fi
        else
            err "[回滚] 恢复失败，请手动检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
        fi
        return 1
    fi
}

install_or_update_xray() {
    local force="${1:-false}" restart="${2:-if-active}" capability="${3:-}"
    local version="${XRAY_VERSION_REQUEST:-${XRAY_VERSION:-latest}}"
    local channel="${XRAY_CHANNEL_REQUEST:-${XRAY_CHANNEL:-stable}}"

    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    install_dependencies || return 1
    with_xray_lock run_deployment_transaction deploy_xray_core "$version" "$channel" "$force" "$restart" install "$capability" || return 1
    apply_env_endpoint_if_needed
}

update_xray_core() {
    prepare_system && install_or_update_xray true always
}
