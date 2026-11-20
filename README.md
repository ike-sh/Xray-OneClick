# Xray-OneClick

Xray-OneClick 是基于 **Xray-core** 的多协议一键部署脚本，适合在 Debian / Ubuntu（systemd）或 **Alpine Linux（OpenRC）** 上快速安装和维护个人 Xray 节点。

脚本支持 Shadowsocks 2022、VLESS Encryption、VLESS TCP REALITY、VLESS Encryption + XHTTP + FinalMask、VLESS Encryption + XHTTP、VLESS Encryption + FinalMask（sudoku）、SOCKS5、Hysteria2，以及高级协议组合与 Tunnel 中转管理。默认带基础安全屏蔽、配置备份、服务诊断、配置导出、Xray-core 升级和安全卸载能力，并提供 stable / prerelease 两条 Xray-core 通道。

当前版本：**1.1.23**（与 `VERSION` / `ike version` 一致）

默认从 XTLS/Xray-core 官方 Releases API 解析最新 Stable。2026-11-21 核对的正式版为 v26.11.9，测试同时覆盖历史基准 v26.3.27。安装时根据实际协议配置检查核心能力。普通 VLESS TCP REALITY 默认使用 `xtls-rprx-vision`，高级 REALITY 组合可通过 `--flow vision` 显式启用。[Xray-core v26.11.9](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9)

## 功能特性

- 一键安装 / 更新 Xray-core
- Shadowsocks 2022
- IPv6 + Shadowsocks 2022
- VLESS Encryption
- VLESS TCP REALITY
- VLESS Encryption + XHTTP + FinalMask
- VLESS XHTTP + REALITY
- VLESS Encryption + REALITY
- VLESS Encryption + XHTTP + REALITY + FinalMask
- SOCKS5 代理
- Tunnel 中转管理
- Endpoint 显示模式
- 中国大陆直连屏蔽
- 增强安全屏蔽
- 配置备份
- 诊断 / smoke / export
- `keep-config` / `purge` 卸载
- GitHub 下载镜像兜底
- Xray-core stable / prerelease 通道
- Xray-core 指定版本升级和失败回滚

## 系统要求

推荐环境：

- Debian 12+ / Ubuntu 22.04+（systemd）
- **Alpine Linux 3.18+（OpenRC）**
- RHEL、Rocky、AlmaLinux、Fedora（systemd，依赖须在已启用的软件源中可用）
- root 权限
- amd64 / arm64
- curl 或 wget

Alpine 直接使用官方静态 Xray Linux 包（如 `Xray-linux-64.zip`）。官方 Xray-core 的 Linux 构建是 `CGO_ENABLED=0` 的静态 Go 二进制，在 glibc 与 musl(Alpine) 上均可直接运行，官方并不单独发布 `-musl` 包；服务使用 `/etc/init.d/xray`（OpenRC）管理。

脚本按缺项安装并复核 `jq`、`unzip`、`tar`、`openssl`、CA 证书、网络工具及对应的服务管理工具。下载工具满足 `curl` 或 `wget` 之一即可。Hysteria2 安装会使用 `ss` 或 `netstat` 检查 UDP 监听。包管理器或依赖复核失败时会停止部署。

普通安装默认保留系统的拥塞控制设置。如需启用 BBR，可在安装时设置 `XRAY_ONECLICK_ENABLE_BBR=1`（在支持 BBR 的 systemd 系统上）。

安装前可先执行：

```bash
ike preflight
```

如果尚未安装 `ike`，先按下面的快速安装流程运行脚本。

## 快速安装

**一行安装（推荐，含 Alpine）：**

引导脚本使用 POSIX `sh` 编写，全新 Alpine 无需预装 bash、也不依赖 sudo——它会在需要时自动 `apk add bash`/`curl`，再用 bash 运行安装器。

Debian / Ubuntu / RHEL 系（有 sudo）：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/scripts/bootstrap.sh | sudo sh
```

Alpine 或已是 root：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/scripts/bootstrap.sh | sh
```

> 说明：Alpine 默认没有 bash 与 sudo。请直接以 root 运行 `| sh`（不要加 sudo）；如系统有 `wget` 没 `curl`，也可用 `wget -qO- <url> | sh`。

或传统方式：

```bash
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

管道直装 `install.sh` 亦可：`curl -fsSL .../install.sh | sudo bash`

仅下载 `install.sh` 单文件时，脚本会在首次运行期间从 GitHub 自动拉取缺失的 `lib/*.sh` 模块（需 `curl` 或 `wget`）。完整 Git 克隆则自带全部模块，适合离线或开发调试。

安装时会将 `install.sh` 与 `lib/` 同步到 `/usr/local/share/ike/`，并创建 `ike` 快捷命令。

安装完成后可直接运行：

```bash
ike
```

也可以使用直接命令进行维护：

```bash
ike help
ike version
ike preflight
ike view
ike doctor all
```

## 国内网络安装

如果 GitHub 访问不稳定，可设置镜像兜底。脚本仍会优先尝试原始 GitHub 地址，然后再按顺序尝试环境变量里的镜像。

```bash
export XRAY_GITHUB_MIRRORS="https://gh.llkk.cc/,https://gh.ddlc.top/,https://gh-proxy.com/,https://ghproxy.net/"
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

指定 Xray-core 版本：

```bash
ike xray upgrade --version v26.3.27
```

升级到最新版本：

```bash
ike xray upgrade
```

升级后默认不重启服务，如需重启：

```bash
ike xray upgrade --restart
```

## Xray 通道

stable 适合生产，prerelease 适合测试最新 XHTTP / REALITY / FinalMask 特性，但可能存在客户端兼容风险。

```bash
ike xray upgrade --xray-channel stable
ike xray upgrade --xray-channel prerelease
XRAY_VERSION=v26.3.27 XRAY_CHANNEL=stable ike xray upgrade
```

## 主菜单

```text
1. 安装/更新 Xray 核心
2. 安装 Shadowsocks 2022
3. 安装 IPv6 + Shadowsocks 2022
4. 安装 VLESS Encryption
5. 安装 VLESS TCP REALITY
6. 安装 VLESS Encryption + XHTTP
7. 安装 VLESS Encryption + XHTTP + FinalMask
8. 安装 VLESS Encryption + FinalMask（sudoku，TCP）
9. 安装 VLESS XHTTP + REALITY（高级）
10. 安装 VLESS Encryption + REALITY（高级）
11. 安装 VLESS Encryption + XHTTP + REALITY + FinalMask（FullStack）
12. 安装 SOCKS5 代理
13. 安装 Hysteria2
14. 查看当前配置链接
15. 设置链接显示模式 (IPv4/IPv6/双栈)
16. 重置密钥/密码（端口不变，覆盖全部 VLESS / REALITY 系列）
17. 卸载/清理
18. 开启/关闭中国大陆直连屏蔽
19. 开启/关闭增强安全屏蔽
20. 导出当前配置备份
21. Tunnel 中转管理
22. 退出
```

## 常用命令

```bash
ike view
ike config test
ike doctor all
ike view reality
ike view xhttp
ike view xhttp-reality
ike view enc-reality
ike view fullstack
ike doctor proxy
ike doctor reality
ike doctor reality-key
ike doctor xhttp
ike doctor xhttp-reality
ike doctor enc-reality
ike doctor fullstack
ike smoke reality
ike smoke xhttp
ike smoke xhttp-reality
ike smoke enc-reality
ike smoke fullstack
ike smoke all
ike export clients --output /root/xray-clients.txt
ike export report --output /root/xray-report.txt
```

`doctor` 用于检查环境、配置和状态。`smoke` 用于服务侧快速排障，可通过 `--restart` 重启服务。客户端凭据通过 `ike view` 或 `ike export clients` 查看。

```bash
ike smoke reality --restart
ike smoke xhttp --restart
ike smoke fullstack --restart
```

`smoke` 面向真实安装后的服务器环境；如果只是想验证脚本生成的 Xray JSON 是否符合协议组合预期，可以运行离线配置生成测试。它不会写 `/usr/local/etc/xray`、不会启动 systemd、不会下载 Xray，也不要求 root：

```bash
bash tests/test_config_generation.sh
```

配置测试覆盖 SS2022、IPv6 SS2022、VLESS Encryption、REALITY、XHTTP、FinalMask、高级组合、SOCKS5、Tunnel 和 Hysteria2。设置 `XRAY_BIN` 或将 `xray` 加入 PATH 后，测试会用真实核心执行 `xray run -test -c <config>`。

推荐通过项目自带的 Docker 测试镜像执行完整检查：

```bash
docker build --no-cache -f Dockerfile.test -t xray-oneclick-test .
docker run --rm xray-oneclick-test
```

镜像执行模块及版本检查、语法检查、warning 级 ShellCheck、依赖故障注入和部署回滚测试。CI 分别使用动态解析的 Stable 和固定的 v26.3.27 校验配置。可用 `--build-arg XRAY_VERSION=v26.3.27` 构建历史基准镜像。

OpenRC 集成测试在独立 Alpine 容器中执行全新安装、TLS 固定校验和真实连接，并验证状态写入失败后的恢复。

```bash
docker build --target deployment -f Dockerfile.test -t xray-oneclick-deployment .
docker run --rm xray-oneclick-deployment
```

`ike view` 和 `ike export clients` 会输出客户端连接信息，不要公开分享完整输出。

## Hysteria2

从菜单第 13 项或 CLI 安装。首装使用 UDP 443，已有节点默认沿用原 UDP 端口。Hysteria2 可与已有的纯 TCP 监听使用同一数字端口。普通重复安装保留现有认证、Salamander 密码和证书。

```bash
ike hysteria2 install --port 8443 --sni vpn.example.org
ike hysteria2 install --dry-run
ike hysteria2 show
ike hysteria2 rotate-cert --sni vpn.example.org --yes
ike hysteria2 rotate-credentials --yes
```

新证书默认使用 `localhost`，也可以给自己的域名或 IPv4 签发带 SAN 的自签证书。SNI 是客户端使用的证书名称，填入第三方站点域名也不会获得该站点的证书信任。兼容分享链接继续包含 `insecure=1`，该选项跳过证书校验。

要验证服务器身份，可以在 Xray 中配置由受信 CA 签发且与 SNI 匹配的证书，再从客户端链接移除 `insecure=1`。自签部署可在支持固定验证的客户端通过可信渠道分发 `ike hysteria2 show` 中的证书指纹。Hysteria2 客户端使用 `pinSHA256`，Xray v26.11.9 客户端使用 TLS 字段 `pinnedPeerCertSha256`，该版本已移除 `allowInsecure`。轮换证书后要更新客户端固定指纹，轮换凭据后要更新客户端链接。[Hysteria2 URI 规范](https://v2.hysteria.network/docs/developers/URI-Scheme/)，[Xray TLS 配置](https://github.com/XTLS/Xray-core/blob/v26.11.9/infra/conf/transport_security.go)

## Shadowsocks 2022

通过菜单安装：

```text
2. 安装 Shadowsocks 2022
```

脚本支持：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

菜单第 2 项安装普通 SS2022，默认按 IPv4 入站监听；菜单第 3 项安装 IPv6 + SS2022，需要服务器存在可用的全局 IPv6 地址。脚本只会在协议实际监听 IPv6/双栈，并且系统检测到全局 IPv6 地址时输出 IPv6 链接。普通 IPv4-only 入站不会因为服务器有 IPv6 地址而强行输出 IPv6 链接。

如果 `sysctl` 显示 `disable_ipv6=1`，但脚本通过网卡检测到了全局 IPv6 地址，会给出 warning 并按实际地址继续；如果没有全局 IPv6 地址，则 IPv6 + SS2022 会拒绝安装。

## VLESS Encryption

通过菜单安装：

```text
4. 安装 VLESS Encryption
```

或使用：

```bash
ike view
```

脚本会调用 `xray vlessenc` 生成服务端 `decryption` 和客户端 `encryption`，并将客户端需要的字段写入 `installer-state.json`。服务端 `decryption` 属于敏感字段，默认导出报告会脱敏。

## VLESS TCP REALITY

主力推荐优先级：`1`。如果你只想部署一个相对稳妥的 VLESS 节点，建议优先选择本模式。

通过菜单安装：

```text
5. 安装 VLESS TCP REALITY
```

直接命令：

```bash
ike reality install
ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
ike reality show
ike reality remove
```

默认行为：

- 主入口端口随机范围：`20000-50000`
- defender 本地端口随机范围：`39000-49999`
- 主 inbound：`vless+tcp+reality`
- defender inbound：`reality-defender`
- defender 监听：`127.0.0.1`
- Reality target：`127.0.0.1:<defender_port>`
- defender 目标：`SNI:443`
- Flow：`xtls-rprx-vision`
- Fingerprint：`chrome`
- 默认生成 8 个 shortId

Reality 使用 `xray x25519` 生成密钥。新版 Xray 可能输出 `PrivateKey`、`Password`、`Password (PublicKey)`、`Hash32` 等字段；脚本会将 `PrivateKey` 写入服务端配置，将 `PublicKey` / `Password` / `Password (PublicKey)` 作为客户端 `pbk`。

`privateKey` 是服务端敏感字段，不需要填到客户端；客户端需要的是 `publicKey/pbk`。

### 443 vs 随机高端口

- 443：更自然，但容易和 Nginx/Caddy/面板冲突。
- 随机高端口：部署更方便，但新版 Xray 可能会提示非 443 warning。
- 如果你手动指定 443，请先确认 443 没被其他服务占用。

如果你手动开启了中国大陆直连屏蔽，并且 Reality 类协议连接异常，请先执行 `ike cnblock off` 排查。

## Vision flow 说明

普通 VLESS TCP REALITY 默认使用 `xtls-rprx-vision`，这是主力 Reality 的推荐配置。脚本会同时把 flow 写入服务端 `clients[0].flow`、客户端分享链接和 state，避免出现链接与服务端配置不一致。

脚本生成的所有 REALITY 入站都会显式写入 `"minClientVer": "0.0.0"`，避免新版 Xray-core 的默认最低客户端版本限制拒绝旧客户端。Xray-core 会对放宽该限制输出风险警告；这是兼容性优先的项目默认值。

高级 Reality 组合默认不启用 Vision flow：

- VLESS XHTTP + REALITY
- VLESS Encryption + REALITY
- VLESS Encryption + XHTTP + REALITY + FinalMask

原因是 XHTTP、VLESS Encryption、FinalMask 与 Vision flow 叠加后对客户端核心要求更高。高级用户可以按需开启：

```bash
ike xhttp-reality install --flow vision
ike enc-reality install --flow vision
ike fullstack install --flow vision
```

如果启用后客户端连接失败，请改回：

```bash
ike xhttp-reality install --flow none
ike enc-reality install --flow none
ike fullstack install --flow none
```

`ike xhttp install` 和普通 VLESS Encryption 使用 `security=none`，不使用 Vision flow。

排障命令：

```bash
ike doctor reality
ike doctor reality-key
ike smoke reality
```

## VLESS Encryption + XHTTP + FinalMask

主力推荐优先级：`3`。它属于高级备用方案，服务端可一键写入，但客户端兼容性仍取决于客户端核心。

通过菜单安装：

```text
6. 安装 VLESS Encryption + XHTTP + FinalMask
```

直接命令：

```bash
ike xhttp install
ike xhttp install --port 30005 --path /api/demo --finalmask off
ike xhttp install --port 30005 --path /api/demo --finalmask on
ike xhttp install --finalmask on --finalmask-preset balanced
ike xhttp install --finalmask on --fm-packets tlshello --fm-length 80-160 --fm-delay 10-30 --fm-max-split 4-8
ike xhttp show
ike xhttp remove
```

说明：

- 默认 `security=none`
- 传输层使用 `xhttp`
- 继续复用 VLESS Encryption 的 `encryption` / `decryption` 生成逻辑
- 用户指定 path 必须以 `/` 开头
- path 不允许空格、`?`、`#` 或反斜杠
- FinalMask 可通过 `--finalmask on/off` 控制
- FinalMask 默认关闭；开启后默认使用 `balanced` 模板，也可以选择预设、自定义参数或粘贴完整 JSON

FinalMask 属于高级兼容功能。开启后分享链接会包含 URL 编码后的 `fm=` 参数，链接可能较长；部分客户端可能需要手动填写 path、encryption、finalmask 参数。如果服务端配置应用失败或客户端导入异常，请优先使用：

```bash
ike xhttp install --finalmask off
```

排障命令：

```bash
ike doctor xhttp
ike smoke xhttp
```

## FinalMask 参数

FinalMask 是高级兼容功能，脚本默认不会自动开启；客户端支持情况取决于客户端核心。参数越激进不一定越好；如果连接变慢、不稳定或客户端无法导入，优先切换到 `conservative`，或者直接使用 `--finalmask off`。

开启后默认模板是 `balanced`：

| 预设 | 定位 | length | delay | maxSplit |
| --- | --- | --- | --- | --- |
| `conservative` | 保守，更稳，分片较轻 | `120-240` | `5-10` | `2-4` |
| `balanced` | 均衡，默认推荐 | `100-200` | `10-20` | `3-6` |
| `aggressive` | 激进，混淆更强，可能影响速度和兼容性 | `80-160` | `10-30` | `4-8` |

参数含义：

- `packets`：目标包类型，目前建议保持 `tlshello`
- `length`：分片长度范围
- `delay`：分片间延迟，单位 ms
- `maxSplit`：最大拆分片数范围

常用命令：

```bash
ike xhttp install --finalmask on --finalmask-preset balanced
ike xhttp install --finalmask on --finalmask-preset conservative
ike xhttp install --finalmask on --finalmask-preset aggressive
ike xhttp install --finalmask on --fm-packets tlshello --fm-length 80-160 --fm-delay 10-30 --fm-max-split 4-8
ike fullstack install --finalmask on --finalmask-preset balanced
ike fullstack install --finalmask off
```

高级用户可以直接传入完整 JSON：

```bash
ike xhttp install --finalmask on --finalmask-json '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","length":"100-200","delay":"10-20","maxSplit":"3-6"}}]}'
```

`--finalmask-json` 优先级最高；如果同时使用 `--finalmask-preset` 和 `--fm-*` 自定义参数，脚本会拒绝执行，避免写入含糊配置。

## 高级协议组合

高级协议组合已直接放在主菜单第 9、10、11 项：

```text
9. 安装 VLESS XHTTP + REALITY（高级）
10. 安装 VLESS Encryption + REALITY（高级）
11. 安装 VLESS Encryption + XHTTP + REALITY + FinalMask（FullStack）
```

高级组合适合已经确认普通节点可用、并且需要更前沿组合的用户。普通用户建议优先使用普通 Reality。高级组合不使用 TLS 证书，默认都是 `security=reality`，不是 `security=tls`。这些组合会把 `realitySettings.target` 直接写成 `<sni>:443`，未通过 REALITY 认证的流量会被转发到 target；如果想更保守，可以加 `--fallback-limit conservative`，脚本会写入随机化的 `limitFallbackUpload` / `limitFallbackDownload`。

推荐顺序：

1. 主力推荐：VLESS TCP REALITY
2. 高级备用：VLESS XHTTP + REALITY
3. 高级备用：VLESS Encryption + XHTTP + FinalMask
4. 谨慎使用：VLESS Encryption + REALITY
5. 谨慎使用：VLESS Encryption + XHTTP + REALITY + FinalMask
6. 兼容兜底：VLESS Encryption
7. 兼容兜底：SS2022
8. 兼容兜底：SOCKS5

FullStack 不作为普通用户默认推荐。如果 FullStack 不兼容，建议按下面顺序降级：

1. `ike fullstack install --finalmask off`
2. `ike xhttp-reality install`
3. `ike enc-reality install`
4. `ike reality install`
5. `ike xhttp install --finalmask off`
6. 菜单第 4 项安装 VLESS Encryption
7. SS2022 / SOCKS5

### VLESS XHTTP + REALITY

推荐定位：高级备用。它比 FullStack 更轻，适合先确认 XHTTP 与 REALITY 组合的可用性。

```bash
ike xhttp-reality install
ike xhttp-reality install --port 30006 --path /api/test --sni www.abmindustriesgroup.com
ike xhttp-reality install --flow vision
ike xhttp-reality install --flow vision --fallback-limit conservative
ike xhttp-reality show
ike doctor xhttp-reality
ike smoke xhttp-reality --restart
ike xhttp-reality remove
```

说明：

- Transport = XHTTP
- Security = REALITY
- REALITY target = `SNI:443`
- 默认不写 Vision flow，减少 XHTTP + REALITY 的兼容风险；需要时可加 `--flow vision`
- 适合需要使用 XHTTP 与 Reality 组合的用户

如果你手动开启了中国大陆直连屏蔽，并且 Reality 类协议连接异常，请先执行 `ike cnblock off` 排查。

### VLESS Encryption + REALITY

推荐定位：谨慎使用组合。它叠加 VLESS Encryption 与 REALITY，客户端兼容性要求较高。

```bash
ike enc-reality install
ike enc-reality install --port 30007 --sni www.abmindustriesgroup.com
ike enc-reality install --flow vision
ike enc-reality install --flow vision --fallback-limit conservative
ike enc-reality show
ike doctor enc-reality
ike smoke enc-reality --restart
ike enc-reality remove
```

说明：

- Transport = TCP
- Security = REALITY
- 复用 `xray vlessenc` 生成 VLESS Encryption
- 默认不写 Vision flow；需要时可加 `--flow vision`
- 客户端需要同时支持 VLESS Encryption 与 REALITY
- 不建议把它作为唯一节点，建议保留普通 Reality 作为备用

如果你手动开启了中国大陆直连屏蔽，并且 Reality 类协议连接异常，请先执行 `ike cnblock off` 排查。

### VLESS Encryption + XHTTP + REALITY + FinalMask

推荐定位：最高级组合，不作为普通用户默认推荐。

```bash
ike fullstack install
ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask on
ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask on --finalmask-preset balanced
ike fullstack install --flow vision --finalmask off
ike fullstack install --flow vision --fallback-limit conservative --finalmask off
ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask off
ike fullstack show
ike doctor fullstack
ike smoke fullstack --restart
ike fullstack remove
```

说明：

- Transport = XHTTP
- Security = REALITY
- 复用 VLESS Encryption
- 可选 FinalMask
- 不使用 TLS 证书
- 默认不写 Vision flow；需要时可加 `--flow vision`
- 兼容性最挑客户端

如果你手动开启了中国大陆直连屏蔽，并且 Reality 类协议连接异常，请先执行 `ike cnblock off` 排查。

如果 FullStack 导入或连接失败，先尝试：

```bash
ike fullstack install --finalmask off
```

仍不兼容时，请按上面的降级路径切换到 XHTTP + REALITY、Encryption + REALITY、普通 Reality、XHTTP FinalMask off、VLESS Encryption 或 SS2022 / SOCKS5。

高级组合同样遵守敏感字段策略：`privateKey` 是服务端字段，不要泄露；客户端需要的是 `publicKey/pbk`。服务端 `decryption` 默认不会在脱敏报告中输出，客户端 `encryption` 会在客户端导出里显示。

## SOCKS5

通过菜单安装：

```text
12. 安装 SOCKS5 代理
```

SOCKS5 适合临时代理或内网调试。安装后可通过 `ike view` 查看连接参数。脚本只会在 SOCKS5 入站实际监听 IPv6/双栈时输出 IPv6 链接；默认 IPv4-only 监听不会输出不可用的 IPv6 链接。

## Tunnel 中转管理

通过菜单进入：

```text
21. Tunnel 中转管理
```

常用命令：

```bash
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
ike tunnel ports
ike tunnel export
ike tunnel import /path/to/tunnels.json --yes
```

兼容旧命令：

```bash
ike forward list
ike forward add
```

新用户建议使用 `ike tunnel ...`。

## Endpoint 与显示模式

Endpoint 用于控制分享链接里的地址，适合 NAT、DDNS、小鸡端口映射和多公网 IP 场景。

未设置自定义 Endpoint 时，分享链接会自动探测公网地址。探测会绕过代理环境并过滤私网、回环、链路本地、文档保留地址；没有可验证的公网地址时不会使用 `hostname -I` 的内网地址兜底，请通过 `ike endpoint set` 明确设置公网 IP、DDNS 域名或 NAT 映射入口。只有本机存在全局公网 IPv6 时才会执行 IPv6 外网探测。

```bash
ike endpoint show
ike endpoint set
ike endpoint clear
ike endpoint detect
```

显示模式可在菜单第 15 项切换，也可通过：

```bash
ike view ipv4
ike view ipv6
ike view dual
```

## 安全屏蔽

脚本默认开启基础安全屏蔽，用于阻断 BT/PT、私网地址、危险端口、SMTP、SMB/NetBIOS 等高风险目标。

默认开启：
- 私网地址屏蔽
- 危险端口屏蔽
- BT 屏蔽
- SMTP/SMB 风险端口屏蔽

默认关闭：
- 中国大陆直连屏蔽

原因是 Reality / XHTTP + Reality / FullStack 需要服务端直连 SNI target。中国大陆直连屏蔽属于可选策略，默认关闭，避免误伤 Reality 类协议。
安装/更新 Xray 和安装任意协议时都不会自动开启 cnblock，只能由 `ike cnblock ...` 手动切换。

中国大陆直连屏蔽：

```bash
ike cnblock
ike cnblock basic
ike cnblock enhanced
ike cnblock off
```

增强安全屏蔽：

```bash
ike safety enhanced on
ike safety enhanced off
```

增强安全屏蔽会额外限制部分常见高风险端口。开启前请确认不会影响你的业务场景。

## 诊断与导出

诊断：

```bash
ike preflight
ike config test
ike doctor all
ike doctor proxy
ike doctor reality
ike doctor reality-key
ike doctor xhttp
ike doctor xhttp-reality
ike doctor enc-reality
ike doctor fullstack
```

服务侧检查：

```bash
ike smoke reality
ike smoke xhttp
ike smoke xhttp-reality
ike smoke enc-reality
ike smoke fullstack
ike smoke all
```

导出客户端配置：

```bash
ike export clients --output /root/xray-clients.txt
```

导出脱敏诊断报告：

```bash
ike export report --output /root/xray-report.txt
```

导出文件会尝试设置为 `600` 权限。`export report` 不输出客户端链接，并会脱敏 `privateKey`、`decryption`、password、token、secret、UUID、auth、shortIds 等认证字段；`export clients` 才会输出客户端需要的链接和参数。

## Xray-core 管理

查看版本：

```bash
ike xray version
```

升级到最新版本：

```bash
ike xray upgrade
```

指定版本：

```bash
ike xray upgrade --version v26.3.27
```

预发布通道：

```bash
ike xray upgrade --xray-channel prerelease
XRAY_CHANNEL=prerelease ike xray upgrade
```

升级成功后默认不重启服务。需要重启时：

```bash
ike xray upgrade --restart
```

升级前校验官方资产名称、架构、版本、SHA-256 和现有配置。API 缺少摘要时会从官方 GitHub Release 读取同名 `.dgst` 的 SHA-256。镜像下载也必须匹配该摘要，无法取得可信摘要时会停止。升级失败时会尝试恢复原核心、资源和服务。自动操作遇到外部 Xray 服务或自定义 systemd 覆盖配置会停止。

## 服务管理（systemd / OpenRC）

```bash
ike service install
ike service status
ike service restart
ike service logs
ike service repair
```

服务文件路径：

| 初始化系统 | 路径 |
| --- | --- |
| systemd | `/etc/systemd/system/xray.service` |
| OpenRC（Alpine） | `/etc/init.d/xray` |

OpenRC 日志默认写入 `/var/log/xray/access.log` 与 `error.log`（`ike logs` 可读）。

`service repair` 会重新写入本项目的 service 文件，不会删除协议配置或 state。

## 配置路径

| 用途 | 路径 |
| --- | --- |
| 配置目录 | `/etc/xray` |
| 配置文件 | `/etc/xray/config.json` |
| 安装器状态 | `/etc/xray/installer-state.json` |
| Xray 二进制 | `/usr/local/bin/xray` |
| Xray 资源目录 | `/usr/local/share/xray` |
| 安装器副本 | `/usr/local/share/ike/install.sh` |
| 安装器模块目录 | `/usr/local/share/ike/lib/` |
| systemd 服务 | `/etc/systemd/system/xray.service` |
| OpenRC 服务 | `/etc/init.d/xray` |
| 主快捷命令 | `/usr/local/bin/ike` |

`installer-state.json` 保存客户端链接所需字段和最近变更信息，应像配置文件一样保护。

## 代码结构（开发者）

自 v1.1.8 起，安装器由 **薄入口 `install.sh`（约 210 行）** + **34 个 `lib/` 模块** 组成。`ike` 命令会加载 `/usr/local/share/ike/lib/`（或仓库内同目录下的 `lib/`），按 `lib/00-bootstrap.sh` 中的依赖顺序 `source` 各模块。

| 模块 | 职责 |
| --- | --- |
| `00-bootstrap` | 按序加载全部模块 |
| `01-constants` / `02-output` | 全局常量、终端输出、`env_truthy` |
| `03-installer` | `ike` 快捷命令与 `lib/` 自部署 |
| `03-system` | 依赖安装、BBR、预检、`ask_port`、UUID/端口工具 |
| `20-paths` / `21-config-base` / `22-state` | root/OS/架构检测、配置读写、`installer-state.json` |
| `30-xray-core` / `31-service` | Xray 下载升级、systemd/openrc |
| `40-network` / `41-safety` | Endpoint CLI/探测、链接生成、安全屏蔽 |
| `50-*`–`55-*` | 协议安装（VLESS、Reality、XHTTP、SS2022、SOCKS5） |
| `56-tunnel` | Tunnel/Forward 管理与 bootstrap |
| `60-doctor`–`63-diag` / `62-export` | 诊断、smoke、导出 |
| `70-view` / `71-cli-view` / `80-menu` | 链接展示与交互菜单 |
| `72-cli-*` / `73-cli-migrate` / `74-cli-protocols` | 管理类 CLI、迁移卸载、协议 CLI |
| `81-help` / `90-test-harness` | 帮助版本、离线测试 harness |

**入口流程**：`install.sh` 设置 `IKE_INSTALLER_DIR` → 确保 `lib/` 存在（缺失则从 raw 下载）→ `source 00-bootstrap.sh` → `main()` 路由到各 CLI 处理器。

离线配置生成测试（不写入 `/etc/xray`、不要求 root）：

```bash
bash tests/test_config_generation.sh
```

## 备份与迁移

导出当前配置备份：

```bash
ike backup
```

迁移旧配置：

```bash
ike migrate --dry-run
ike migrate
```

同协议重复部署会覆盖同 tag 配置，不同协议互不影响。写入配置前脚本会自动备份，配置应用失败时会尝试回滚。

## 卸载与清理

主菜单第 17 项进入卸载/清理菜单：

```text
 1) 删除 SS2022 配置
 2) 删除 VLESS Encryption 配置
 3) 删除 VLESS TCP REALITY 配置
 4) 删除 VLESS Encryption + XHTTP + FinalMask 配置
 5) 删除 VLESS Encryption + XHTTP 配置
 6) 删除 VLESS Encryption + FinalMask (sudoku) 配置
 7) 删除 VLESS XHTTP + REALITY 配置
 8) 删除 VLESS Encryption + REALITY 配置
 9) 删除 VLESS Encryption + XHTTP + REALITY + FinalMask 配置
10) 删除 SOCKS5 配置
11) 删除 Hysteria2 配置
12) 卸载全部 Xray
13) 返回主菜单
```

保留配置卸载：

```bash
ike uninstall --keep-config
```

仅预览将删除的内容：

```bash
ike uninstall --dry-run
```

彻底清理：

```bash
ike uninstall --purge --yes
```

区别：

- `--keep-config`：删除二进制、快捷命令和 service，保留 `/etc/xray/config.json` 与 `installer-state.json`
- `--purge`：先创建最终备份包，再删除配置、state、日志、service、二进制和快捷命令

卸载后如果当前 shell 仍缓存旧命令路径，可执行：

```bash
hash -r
```

## 常见问题

**Reality 的 SNI 可以写 `https://domain/path` 吗？**
不可以，只写域名，例如 `www.example.com`，不要带协议、路径、端口或空格。

**Reality 的 privateKey 要填到客户端吗？**
不要。`privateKey` 是服务端字段，客户端填写 `publicKey/pbk`。

**FinalMask 导入失败怎么办？**
先关闭 FinalMask：

```bash
ike xhttp install --finalmask off
```

然后重新查看 `ike xhttp show` 输出。FinalMask 的客户端兼容性取决于客户端内核版本。

**国内 GitHub 下载失败怎么办？**
设置 `XRAY_GITHUB_MIRRORS`，或使用 `ike xray upgrade --version vX.Y.Z` 指定版本。

**重复安装会怎样？**
同协议 tag 会被覆盖，不同协议互不影响，写入前自动备份。

## 安全声明

本项目仅供学习、研究和合法网络用途。请遵守所在地法律法规、服务商条款和网络使用规范。使用本脚本产生的任何后果由使用者自行承担。
