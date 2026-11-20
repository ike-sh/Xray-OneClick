#!/usr/bin/env bash
# Help text and version output.

show_help() {
    cat <<'EOF'
Xray-OneClick 命令帮助

常用命令:
  ike
  ike preflight
  ike view
  ike view doctor
  ike xray version
  ike xray upgrade --dry-run
  ike xray upgrade --version vX.Y.Z --restart
  ike xray upgrade --xray-channel prerelease --restart
  env: XRAY_VERSION=vX.Y.Z / XRAY_CHANNEL=stable|prerelease
  ike doctor all
  ike doctor preflight
  ike doctor proxy
  ike doctor reality-key
  ike doctor reality
  ike doctor xhttp
  ike doctor xhttp-reality
  ike doctor enc-reality
  ike doctor fullstack
  ike smoke reality
  ike smoke xhttp --restart
  ike smoke xhttp-reality
  ike smoke enc-reality --restart
  ike smoke fullstack --restart
  ike smoke all
  ike export report --output /root/xray-report.txt
  ike export clients --output /root/xray-clients.txt
  ike update
  ike backup
  ike endpoint show
  ike endpoint set
  ike endpoint clear
  ike endpoint detect
  ike config path
  ike config test
  ike config edit
  ike service status
  ike service install
  ike service restart
  ike service logs
  ike service repair
  ike logs
  ike migrate --dry-run
  ike migrate
  ike uninstall --dry-run
  ike uninstall --keep-config
  ike uninstall --purge --yes
  ike cnblock
  ike cnblock basic
  ike cnblock enhanced
  ike cnblock off
  说明：中国大陆直连屏蔽默认关闭，只在手动启用后生效。
  ike safety enhanced on
  ike safety enhanced off
  ike reality install
  ike reality install --dry-run
  ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
  ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com --dry-run
  ike reality show
  ike reality remove
  ike xhttp install
  ike xhttp install --dry-run
  ike xhttp install --port 30005 --path /api/demo --finalmask on
  ike xhttp install --finalmask on --finalmask-preset balanced
  ike xhttp install --finalmask on --fm-packets tlshello --fm-length 80-160 --fm-delay 10-30 --fm-max-split 4-8
  ike xhttp install --port 30005 --path /api/demo --finalmask off
  ike xhttp install --port 30005 --path /api/demo --finalmask on --dry-run
  ike xhttp show
  ike xhttp remove
  ike enc-finalmask install
  ike enc-finalmask install --dry-run
  ike enc-finalmask install --port 8444 --auth x25519
  ike enc-finalmask show
  ike enc-finalmask remove
  ike enc-xhttp install
  ike enc-xhttp install --dry-run
  ike enc-xhttp install --port 30005 --path /api/demo --auth x25519
  ike enc-xhttp show
  ike enc-xhttp remove
  ike hysteria2 install
  ike hysteria2 install --dry-run
  ike hysteria2 install --port 443 --sni vpn.example.org
  ike hysteria2 show
  ike hysteria2 rotate-cert --sni vpn.example.org --yes
  ike hysteria2 rotate-credentials --yes
  ike hysteria2 remove
  ike view reality
  ike view xhttp
  ike xhttp-reality install
  ike xhttp-reality install --dry-run
  ike xhttp-reality install --port 30006 --path /api/test --sni www.abmindustriesgroup.com
  ike xhttp-reality install --flow vision
  ike xhttp-reality show
  ike xhttp-reality remove
  ike enc-reality install
  ike enc-reality install --dry-run
  ike enc-reality install --port 30007 --sni www.abmindustriesgroup.com
  ike enc-reality install --flow vision
  ike enc-reality show
  ike enc-reality remove
  ike fullstack install
  ike fullstack install --dry-run
  ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask on
  ike fullstack install --finalmask on --finalmask-preset balanced
  ike fullstack install --flow vision --finalmask off
  ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask off
  ike fullstack show
  ike fullstack remove
  ike view xhttp-reality
  ike view enc-reality
  ike view fullstack
  ike tunnel list
  ike tunnel add
  ike tunnel add safe
  ike tunnel add relay
  ike tunnel add map
  ike tunnel edit
  ike tunnel enable
  ike tunnel disable
  ike tunnel del
  ike tunnel doctor
  ike tunnel group list
  ike tunnel group doctor
  ike tunnel template
  ike tunnel ports
  ike tunnel export
  ike tunnel import
  ike tunnel import /path/to/tunnels.json --yes
  ike tunnel bundle export
  ike tunnel bundle import /path/to/tunnels.json --yes
  ike tunnel generate-script
  ike tunnel generate-relay-script
  ike tunnel generate-client-script
  ike bootstrap
  ike forward list
  ike forward add
  ike forward add safe
  ike forward add relay
  ike forward edit
  ike forward enable
  ike forward disable
  ike forward del
  ike forward doctor
  ike forward template
  ike forward ports
  ike forward export
  ike forward import
  ike version

说明：ike forward ... 是兼容别名，新用户建议使用 ike tunnel ...
EOF
}

show_version() {
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "Repository: ${REPO_URL}"
    if [[ -x "$BIN_PATH" ]]; then
        echo
        echo "Xray: $(detect_xray_version 2>/dev/null || printf '%s' '版本信息读取失败')"
    else
        echo "Xray: 未安装 (${BIN_PATH})"
    fi
}
