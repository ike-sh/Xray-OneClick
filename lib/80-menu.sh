#!/usr/bin/env bash
# Interactive main menu.

render_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}   Xray 多协议一键安装脚本 (ike)             ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "系统: ${YELLOW}$OS_TYPE${PLAIN} | 初始化: ${YELLOW}$INIT_SYSTEM${PLAIN} | 架构: ${YELLOW}$ARCH${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装/更新 Xray 核心"
    echo -e "${GREEN}2.${PLAIN} 安装 Shadowsocks 2022"
    echo -e "${GREEN}3.${PLAIN} 安装 IPv6 + Shadowsocks 2022"
    echo -e "${GREEN}4.${PLAIN} 安装 VLESS Encryption"
    echo -e "${GREEN}5.${PLAIN} 安装 VLESS TCP REALITY"
    echo -e "${GREEN}6.${PLAIN} 安装 VLESS Encryption + XHTTP"
    echo -e "${GREEN}7.${PLAIN} 安装 VLESS Encryption + XHTTP + FinalMask"
    echo -e "${GREEN}8.${PLAIN} 安装 VLESS Encryption + FinalMask（sudoku，TCP）"
    echo -e "${GREEN}9.${PLAIN} 安装 VLESS XHTTP + REALITY（高级）"
    echo -e "${GREEN}10.${PLAIN} 安装 VLESS Encryption + REALITY（高级）"
    echo -e "${GREEN}11.${PLAIN} 安装 VLESS Encryption + XHTTP + REALITY + FinalMask（FullStack）"
    echo -e "${GREEN}12.${PLAIN} 安装 SOCKS5 代理"
    echo -e "${GREEN}13.${PLAIN} 安装 Hysteria2"
    echo -e "${GREEN}14.${PLAIN} 查看当前配置链接"
    echo -e "${GREEN}15.${PLAIN} 设置链接显示模式 (IPv4/IPv6/双栈)"
    echo -e "${GREEN}16.${PLAIN} 重置密钥/密码（端口不变）"
    echo -e "${RED}17.${PLAIN} 卸载/清理"
    echo -e "${GREEN}18.${PLAIN} 开启/关闭中国大陆直连屏蔽"
    echo -e "${GREEN}19.${PLAIN} 开启/关闭增强安全屏蔽"
    echo -e "${GREEN}20.${PLAIN} 导出当前配置备份"
    echo -e "${GREEN}21.${PLAIN} Tunnel 中转管理"
    echo -e "${GREEN}22.${PLAIN} 退出"
    echo -e "----------------------------------------------"
}

show_menu() {
    local choice
    while true; do
        render_menu
        read -r -p "请输入选项 [1-22]: " choice || return 0
        case "$choice" in
            22) return 0 ;;
            14 | 15) run_menu_choice "$choice" ;;
            *) with_xray_lock run_menu_choice "$choice" ;;
        esac
        pause_return_menu
    done
}

run_menu_choice() {
    case "$1" in
        1)
            update_xray_core || err "[失败] Xray 核心安装/更新未完成，请查看上方错误信息。"
            ;;
        2)
            if ! { prepare_system && configure_ss2022 "ipv4" && install_ss2022; }; then
                err "[失败] Shadowsocks 2022 安装未完成，请查看上方错误信息。"
            fi
            ;;
        3)
            if ! prepare_system; then
                err "[失败] IPv6 + Shadowsocks 2022 安装未完成，请查看上方错误信息。"
            else
                if check_ipv6_status; then
                    if ! { configure_ss2022 "ipv6" && install_ss2022; }; then
                        err "[失败] IPv6 + Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                    fi
                else
                    info "[IPv6] 未检测到可用全局 IPv6 地址，请先在服务器开通 IPv6 后重试。"
                    err "[失败] IPv6 + Shadowsocks 2022 安装未完成。"
                fi
            fi
            ;;
        4)
            if ! { prepare_system && configure_vless_encryption && install_vless_encryption; }; then
                err "[失败] VLESS Encryption 安装未完成，请查看上方错误信息。"
            fi
            ;;
        5)
            if ! { prepare_system && configure_reality "interactive" && install_reality; }; then
                err "[失败] VLESS TCP REALITY 安装未完成，请查看上方错误信息。"
            fi
            ;;
        6)
            if ! { prepare_system && configure_vless_enc_xhttp "interactive" && install_vless_enc_xhttp; }; then
                err "[失败] VLESS Encryption + XHTTP 安装未完成，请查看上方错误信息。"
            fi
            ;;
        7)
            if ! { prepare_system && configure_vless_xhttp_finalmask "interactive" && install_vless_xhttp_finalmask; }; then
                err "[失败] VLESS Encryption + XHTTP + FinalMask 安装未完成，请查看上方错误信息。"
            fi
            ;;
        8)
            if ! { prepare_system && configure_vless_enc_finalmask "interactive" && install_vless_enc_finalmask; }; then
                err "[失败] VLESS Encryption + FinalMask 安装未完成，请查看上方错误信息。"
            fi
            ;;
        9)
            if ! { prepare_system && configure_advanced_profile "xhttp-reality" "interactive" && install_advanced_profile "xhttp-reality"; }; then
                err "[失败] VLESS XHTTP + REALITY 安装未完成，请查看上方错误信息。"
            fi
            ;;
        10)
            if ! { prepare_system && configure_advanced_profile "enc-reality" "interactive" && install_advanced_profile "enc-reality"; }; then
                err "[失败] VLESS Encryption + REALITY 安装未完成，请查看上方错误信息。"
            fi
            ;;
        11)
            if ! { prepare_system && configure_advanced_profile "fullstack" "interactive" && install_advanced_profile "fullstack"; }; then
                err "[失败] VLESS Encryption + XHTTP + REALITY + FinalMask 安装未完成，请查看上方错误信息。"
            fi
            ;;
        12)
            if ! { prepare_system && install_socks5; }; then
                err "[失败] SOCKS5 安装未完成，请查看上方错误信息。"
            fi
            ;;
        13)
            if ! { install_hysteria2 interactive; }; then
                err "[失败] Hysteria2 安装未完成，请查看上方错误信息。"
            fi
            ;;
        14)
            view_config || err "[失败] 查看当前配置链接失败，请查看上方错误信息。"
            ;;
        15)
            set_link_view_mode || err "[失败] 设置链接显示模式失败，请查看上方错误信息。"
            ;;
        16)
            if ! { prepare_system && reset_secrets; }; then
                err "[失败] 重置密钥/密码未完成，请查看上方错误信息。"
            fi
            ;;
        17)
            uninstall || err "[失败] 卸载/清理未完成，请查看上方错误信息。"
            ;;
        18)
            configure_china_direct_block || err "[失败] 中国大陆直连屏蔽设置未完成，请查看上方错误信息。"
            ;;
        19)
            configure_enhanced_safety_block || err "[失败] 增强安全屏蔽设置未完成，请查看上方错误信息。"
            ;;
        20)
            export_current_config_backup || err "[失败] 导出当前配置备份未完成，请查看上方错误信息。"
            ;;
        21)
            configure_forward_menu || err "[失败] Tunnel 中转管理未完成，请查看上方错误信息。"
            ;;
        *) err "错误选项。" ;;
    esac
}
