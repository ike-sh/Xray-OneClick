#!/usr/bin/env bash
# Xray-OneClick systemd/openrc service management.

openrc_init_path() {
    printf '/etc/init.d/%s' "$SERVICE_NAME"
}

service_file_path() {
    if [[ "${INIT_SYSTEM:-}" == "openrc" ]]; then
        printf '%s' "${XRAY_SERVICE_FILE:-$(openrc_init_path)}"
        return 0
    fi
    printf '%s' "${XRAY_SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
}

log_dir_path() {
    printf '%s' "${XRAY_LOG_DIR:-/var/log/xray}"
}

tail_xray_service_logs() {
    local lines="${1:-80}"
    local log_dir access_log error_log shown="false"

    log_dir="$(log_dir_path)"
    access_log="${log_dir}/access.log"
    error_log="${log_dir}/error.log"
    if [[ -f "$error_log" ]]; then
        tail -n "$lines" "$error_log" 2>/dev/null | redact_sensitive_stream || true
        shown="true"
    fi
    if [[ -f "$access_log" ]]; then
        tail -n "$lines" "$access_log" 2>/dev/null | redact_sensitive_stream || true
        shown="true"
    fi
    [[ "$shown" == "true" ]]
}

validate_service_file() {
    local service_file="${1:-$(service_file_path)}"

    [[ -f "$service_file" ]] || return 1
    grep -Fxq "ExecStart=$BIN_PATH run -c $CONFIG_FILE" "$service_file"
}

service_manager_ready() {
    case "$INIT_SYSTEM" in
        systemd)
            if [[ ( -d "${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}" ||
                "${XRAY_ONECLICK_ALLOW_FAKE_SYSTEMD:-false}" == "true" ) ]] &&
                systemctl show --property=Version >/dev/null 2>&1; then
                return 0
            fi
            ;;
        openrc)
            command -v rc-service >/dev/null && command -v rc-update >/dev/null &&
                [[ -d "$(dirname "$(service_file_path)")" ]] && return 0
            ;;
    esac
    err "[服务] $INIT_SYSTEM 当前不可用。请在运行 systemd 或 OpenRC 的系统中部署。"
    return 1
}

check_xray_service_ownership() {
    local unit fragment="" overrides=""
    unit="$(service_file_path)"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        fragment="$(systemctl show --property=FragmentPath --value "$SERVICE_NAME" 2>/dev/null)" || return 1
        overrides="$(systemctl show --property=DropInPaths --value "$SERVICE_NAME" 2>/dev/null)" || return 1
    fi
    if [[ -n "$overrides" || ( -n "$fragment" && "$fragment" != "$unit" ) ]] ||
        { [[ -e "$unit" || -L "$unit" ]] && { [[ -L "$unit" ]] || ! grep -Fxq '# Managed by Xray-OneClick' "$unit"; }; } ||
        { [[ ! -f "$unit" ]] && xray_service_is_active; }; then
        err "[服务] 检测到外部 Xray 服务或覆盖配置，自动部署已停止。请检查现有服务后再运行 ike service repair --yes。"
        return 1
    fi
    if [[ -f "$unit" ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            validate_service_file "$unit"
        else
            grep -Fxq "command=\"$BIN_PATH\"" "$unit" &&
                grep -Fxq "command_args=\"run -c $CONFIG_FILE\"" "$unit"
        fi || {
            err "[服务] Xray 服务使用不同的核心或配置路径: $unit"
            return 1
        }
    fi
}

write_xray_service() {
    local service_file="${1:-$(service_file_path)}"
    local assume_yes="${2:-false}"
    local backup_path tmp_service

    mkdir -p "$(dirname "$service_file")" "$ASSET_DIR" "$(log_dir_path)" || return 1
    if [[ -f "$service_file" ]]; then
        backup_path="$(mktemp "${service_file}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")" || return 1
        cp -a "$service_file" "$backup_path" || {
            rm -f "$backup_path"
            err "[服务] 备份旧 service 失败: $backup_path"
            return 1
        }
        if ! grep -q "Managed by Xray-OneClick" "$service_file"; then
            info "[服务] 检测到非本项目生成的 service，已备份到: $backup_path"
            if [[ "$assume_yes" != "true" ]] && ! env_truthy "${XRAY_ONECLICK_YES:-}"; then
                err "[服务] 非交互模式未确认覆盖 service；如需覆盖请添加 --yes 或设置 XRAY_ONECLICK_YES=1。"
                return 1
            fi
        fi
    fi

    tmp_service="$(mktemp "${service_file}.tmp.XXXXXX")" || return 1
    if ! cat >"$tmp_service" <<EOF
# Managed by Xray-OneClick
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ASSET_DIR
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$CONFIG_DIR $(log_dir_path)

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f "$tmp_service"
        return 1
    fi
    validate_service_file "$tmp_service" || {
        rm -f "$tmp_service"
        err "[服务] service 文件校验失败: $service_file"
        return 1
    }
    chmod 644 "$tmp_service" || {
        rm -f "$tmp_service"
        return 1
    }
    mv "$tmp_service" "$service_file" || {
        rm -f "$tmp_service"
        return 1
    }
}

enable_xray_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        err "[服务] systemctl 不存在，无法启用服务。"
        return 1
    fi
    systemctl daemon-reload || {
        err "[服务] systemctl daemon-reload 失败。"
        return 1
    }
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || {
        err "[服务] systemctl enable ${SERVICE_NAME} 失败。"
        return 1
    }
}

ensure_xray_service() {
    local assume_yes="${1:-false}"

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if [[ ! -d "${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}" && "${XRAY_ONECLICK_ALLOW_FAKE_SYSTEMD:-false}" != "true" ]]; then
            err "[服务] 未检测到 systemd 运行目录，已跳过写入不可用 service。"
            return 1
        fi
        write_xray_service "$(service_file_path)" "$assume_yes" || return 1
        enable_xray_service || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        local init_file backup_path tmp_init
        init_file="$(service_file_path)"
        mkdir -p "$(dirname "$init_file")" "$ASSET_DIR" "$(log_dir_path)" || return 1
        if [[ -f "$init_file" ]]; then
            backup_path="$(mktemp "${init_file}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")" || return 1
            cp -a "$init_file" "$backup_path" || {
                rm -f "$backup_path"
                err "[服务] 备份旧 OpenRC 脚本失败: $init_file"
                return 1
            }
            if ! grep -q "Managed by Xray-OneClick" "$init_file" && [[ "$assume_yes" != "true" ]] && ! env_truthy "${XRAY_ONECLICK_YES:-}"; then
                err "[服务] 非交互模式未确认覆盖 OpenRC 脚本；如需覆盖请添加 --yes 或设置 XRAY_ONECLICK_YES=1。"
                return 1
            fi
        fi
        tmp_init="$(mktemp "${init_file}.tmp.XXXXXX")" || return 1
        if ! cat >"$tmp_init" <<EOF
#!/sbin/openrc-run
# Managed by Xray-OneClick

name="xray"
description="Xray Service"

command="$BIN_PATH"
command_args="run -c $CONFIG_FILE"
command_background=true
command_user="root"
directory="$ASSET_DIR"
export XRAY_LOCATION_ASSET="$ASSET_DIR"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="$(log_dir_path)/access.log"
error_log="$(log_dir_path)/error.log"

depend() {
    use net
    after net firewall
}

start_pre() {
    checkpath -d -m 0755 "$(log_dir_path)"
}
EOF
        then
            rm -f "$tmp_init"
            return 1
        fi
        chmod 755 "$tmp_init" || {
            rm -f "$tmp_init"
            return 1
        }
        mv "$tmp_init" "$init_file" || {
            rm -f "$tmp_init"
            return 1
        }
        if ! rc-update add "$SERVICE_NAME" default >/dev/null 2>&1; then
            err "[服务] OpenRC 服务启用失败: $SERVICE_NAME"
            return 1
        fi
    else
        err "[服务] 未检测到 systemd/openrc，已跳过服务文件写入。"
        return 1
    fi
}

create_service() {
    check_xray_service_ownership || return 1
    [[ -f "$(service_file_path)" ]] || ensure_xray_service false
}

create_deployment_service() {
    local unit
    unit="$(service_file_path)"
    [[ ! -f "$unit" ]] || return 0
    snapshot_deployment_file "$unit" || return 1
    DEPLOYMENT_CREATED_SERVICE=true
    create_service
}

restart_deployment_service() {
    if xray_service_is_active; then
        DEPLOYMENT_WAS_ACTIVE=true
    fi
    DEPLOYMENT_RESTARTED=true
    restart_service
}

xray_service_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$SERVICE_NAME"
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" status >/dev/null 2>&1
    else
        return 1
    fi
}

xray_service_pid() {
    local pid
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        pid="$(systemctl show --property=MainPID --value "$SERVICE_NAME" 2>/dev/null)" || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" && -r "/run/${SERVICE_NAME}.pid" ]]; then
        read -r pid <"/run/${SERVICE_NAME}.pid" || return 1
    fi
    [[ "${pid:-}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$pid"
}

disable_new_xray_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        [[ ! -f "$(service_file_path)" ]] || systemctl disable "$SERVICE_NAME"
    else
        local enabled
        enabled="$(rc-update show default)" || return 1
        if awk -v name="$SERVICE_NAME" '$1 == name { found=1 } END {exit !found}' <<<"$enabled"; then
            rc-update del "$SERVICE_NAME" default || return 1
        fi
    fi
}

restart_xray_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload || {
            err "[服务] systemctl daemon-reload 失败。"
            return 1
        }
        systemctl restart "$SERVICE_NAME" || {
            err "[服务] xray restart 失败，最近日志如下:"
            if command -v journalctl >/dev/null 2>&1; then
                journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 | redact_sensitive_stream || true
            fi
            return 1
        }
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$SERVICE_NAME" restart || {
            err "[服务] xray restart 失败，最近日志如下:"
            tail_xray_service_logs 80 || true
            return 1
        }
    else
        err "[服务] 无法自动重启，请手动运行: $BIN_PATH run -c $CONFIG_FILE"
        return 1
    fi
    # systemd Type=simple and OpenRC can report success before Xray binds.
    sleep 1
    if ! xray_service_is_active; then
        err "[服务] Xray 启动后未保持运行，请检查 ike logs。"
        return 1
    fi
}

restart_service() {
    check_xray_service_ownership && restart_xray_service
}

status_xray_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl status "$SERVICE_NAME" --no-pager 2>&1 | redact_sensitive_stream
        return "${PIPESTATUS[0]}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" status
    else
        err "[服务] 未检测到 systemd/openrc，无法读取服务状态。"
        return 1
    fi
}

xray_service_status() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            printf '%s' "运行中"
        else
            printf '%s' "未运行"
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        if xray_service_is_active; then
            printf '%s' "运行中"
        else
            printf '%s' "未运行"
        fi
    else
        printf '%s' "未检测到 systemd/openrc"
    fi
}

stop_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if xray_service_is_active && ! systemctl stop "$SERVICE_NAME" >/dev/null 2>&1; then
            err "[服务] 停止 ${SERVICE_NAME}.service 失败。"
            return 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if xray_service_is_active && ! rc-service "$SERVICE_NAME" stop >/dev/null 2>&1; then
            err "[服务] 停止 OpenRC 服务 ${SERVICE_NAME} 失败。"
            return 1
        fi
    fi
}
