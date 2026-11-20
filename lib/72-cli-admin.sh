#!/usr/bin/env bash
# Admin CLI: cnblock, safety, endpoint, config, service, logs.

run_cnblock_command() {
    local mode="${1:-}"

    [[ $# -le 1 ]] || {
        err "[失败] cnblock 参数过多。"
        return 1
    }

    case "$mode" in
        "" | status)
            echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
            case "$(china_direct_block_rule_mode)" in
                basic) echo -e "规则模式: ${YELLOW}基础模式${PLAIN}" ;;
                enhanced) echo -e "规则模式: ${YELLOW}增强模式${PLAIN}" ;;
            esac
            echo "可选: basic / enhanced / off"
            echo "用法: ike cnblock basic|enhanced|off"
            ;;
        basic | enhanced | off)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法修改中国大陆直连屏蔽。"
                return 1
            }
            set_china_direct_block "$mode"
            ;;
        *)
            err "[失败] 未知 cnblock 参数: $mode"
            echo "用法: ike cnblock [basic|enhanced|off]"
            return 1
            ;;
    esac
}

run_safety_command() {
    local scope="${1:-}"
    local action="${2:-}"

    [[ $# -le 2 ]] || {
        err "[失败] safety 参数过多。"
        return 1
    }

    if [[ "$scope" != "enhanced" ]]; then
        err "[失败] 未知 safety 参数: ${scope:-空}"
        echo "用法: ike safety enhanced on|off"
        return 1
    fi

    case "$action" in
        on)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法开启增强安全屏蔽。"
                return 1
            }
            set_enhanced_safety_block "true"
            ;;
        off)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法关闭增强安全屏蔽。"
                return 1
            }
            set_enhanced_safety_block "false"
            ;;
        "" | status)
            echo -e "增强安全屏蔽: ${YELLOW}$(enhanced_safety_block_status)${PLAIN}"
            echo "用法: ike safety enhanced on|off"
            ;;
        *)
            err "[失败] 未知 safety enhanced 参数: $action"
            echo "用法: ike safety enhanced on|off"
            return 1
            ;;
    esac
}

run_endpoint_command() {
    local action="${1:-show}"

    [[ $# -le 1 ]] || {
        err "[失败] endpoint 参数过多。"
        return 1
    }

    case "$action" in
        show | "")
            endpoint_show_command
            ;;
        set)
            endpoint_set_command
            ;;
        clear)
            endpoint_clear_command
            ;;
        detect)
            endpoint_detect_command
            ;;
        *)
            err "[失败] 未知 endpoint 参数: $action"
            echo "用法: ike endpoint show|set|clear|detect"
            return 1
            ;;
    esac
}

run_config_command() {
    local action="${1:-path}"
    local editor_cmd restart_answer

    [[ $# -le 1 ]] || {
        err "[失败] config 参数过多。"
        return 1
    }

    case "$action" in
        path | "")
            echo "$CONFIG_FILE"
            ;;
        test)
            validate_config_file
            ;;
        edit)
            editor_cmd="${EDITOR:-}"
            if [[ -z "$editor_cmd" ]]; then
                editor_cmd="$(command -v nano || command -v vi || true)"
            fi
            [[ -n "$editor_cmd" ]] || {
                err "[失败] 未找到可用编辑器，请设置 EDITOR 或安装 nano/vi。"
                return 1
            }
            backup_config || {
                err "[失败] 配置备份失败，已中止编辑。"
                return 1
            }
            "$editor_cmd" "$CONFIG_FILE" || return 1
            validate_config_file || {
                err "[失败] 配置校验未通过，正在恢复编辑前备份。"
                restore_config_backup >/dev/null 2>&1 || err "[回滚] 恢复编辑前配置失败。"
                return 1
            }
            read -r -p "配置校验通过，是否重启 Xray? [y/N]: " restart_answer
            if [[ "$restart_answer" =~ ^[yY]$ ]]; then
                apply_config "配置编辑"
            else
                info "[配置] 已跳过重启。"
            fi
            ;;
        *)
            err "[失败] 未知 config 参数: $action"
            echo "用法: ike config path|test|edit"
            return 1
            ;;
    esac
}

run_service_command() {
    local action="${1:-status}"
    local assume_yes="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes | -y)
                assume_yes="true"
                ;;
            *)
                err "[失败] 未知 service 参数: $1"
                echo "用法: ike service install|status|restart|logs|repair [--yes]"
                return 1
                ;;
        esac
        shift
    done

    case "$action" in
        install)
            ensure_xray_service "$assume_yes"
            ;;
        status | "")
            status_xray_service
            ;;
        restart)
            restart_xray_service
            ;;
        logs)
            run_logs_command
            ;;
        repair)
            ensure_xray_service "$assume_yes" || return 1
            validate_config_file
            ;;
        *)
            err "[失败] 未知 service 参数: $action"
            echo "用法: ike service install|status|restart|logs|repair"
            return 1
            ;;
    esac
}

run_logs_command() {
    [[ $# -eq 0 ]] || {
        err "[失败] logs 不接受额外参数。"
        return 1
    }
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 | redact_sensitive_stream
        return "${PIPESTATUS[0]}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if tail_xray_service_logs 200; then
            return 0
        fi
        err "[日志] 未找到 $(log_dir_path) 下日志；请先 ike service install && ike service restart"
        return 1
    else
        err "[日志] 未检测到 systemd/openrc，无法自动读取 Xray 日志。"
        return 1
    fi
}
