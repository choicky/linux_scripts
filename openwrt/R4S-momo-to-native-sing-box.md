# R4S：OpenWrt-Momo core_only 迁移至原生 sing-box（procd）

> 适用：本次 ImmortalWrt R4S 实机迁移记录（2026-10-19），不是通用的一键安装脚本。
> 迁移使用设备现有的 `/usr/bin/sing-box` 及 `/etc/init.d/sing-box`，不改动 Debian VPS 的 systemd 脚本。
> 所有涉及配置、Tailscale 状态和缓存的文件都只在设备本地保存，**不要提交到 Git**。

## 1. 已确认的设备布局

| 项目 | 本次路径或值 |
| --- | --- |
| 路由器 | R4S / ImmortalWrt，LAN `192.168.10.1` |
| sing-box | `/usr/bin/sing-box`（实机 1.14.3） |
| 原服务 | `momo`，此前以 `core_only` 管理 sing-box |
| 原工作目录 | `/etc/momo/run`（旧进程使用 `-D /etc/momo/run`） |
| 原生服务 | `/etc/init.d/sing-box`（procd，`START=99`） |
| 原生配置 | `/etc/sing-box/config.json` |
| 原生工作目录 | `/usr/share/sing-box` |
| TUN | `singtun`，`172.19.0.1/30` |
| Tailscale | sing-box 内置 endpoint，接口 `tailscale0` |

**工作目录由 procd/UCI 的 `sing-box.main.workdir` 设置**，并非必须写进 JSON。配置中的相对路径（例如 `cache-realip.db`、`tailscale/`、`sb-ui`、`clash-ui`）会受工作目录影响。不要仅复制 JSON 而忽略这些数据。

本次 Momo 旧状态文件在 `/etc/momo/run/tailscale/tailscaled.state`；另有 `/etc/momo/tailscale/tailscaled.state`，两者 SHA256 不同。不能仅凭文件时间推断状态是否有效；本次尝试恢复的是前者。

## 2. 迁移前：备份与检查

保持 SSH 会话可用，尽可能从 LAN 操作；切换 TUN/防火墙时连接可能短暂中断。先在设备本地备份配置和 Tailscale 状态；**不要把备份上传公开仓库**。

```sh
mkdir -p /root/sing-box-migration-backup
chmod 700 /root/sing-box-migration-backup

cp -p /etc/config/momo /root/sing-box-migration-backup/momo.uci
cp -p /etc/config/sing-box /root/sing-box-migration-backup/sing-box.uci
[ ! -f /etc/sing-box/config.json ] || cp -p /etc/sing-box/config.json /root/sing-box-migration-backup/config.json
[ ! -f /etc/momo/run/tailscale/tailscaled.state ] || cp -p /etc/momo/run/tailscale/tailscaled.state /root/sing-box-migration-backup/tailscaled.state

service momo status
service sing-box status
uci show momo
uci show sing-box
```

确认 `/etc/init.d/sing-box` 确实是设备已有的原生 procd 服务，支持 `conffile`、`workdir`、`enabled`；不要将 Debian 的 systemd 操作套用到 OpenWrt。

## 3. 准备原生配置与工作目录

本次沿用已验证的 R4S sing-box 配置主体；它包含私密代理节点与凭据，**不在仓库保存模板副本**。把自己的配置放在：

```text
/etc/sing-box/config.json
```

把需要保留的工作目录内容复制到：

```text
/usr/share/sing-box/
  cache-realip.db       # 如需保留缓存
  tailscale/            # 保留旧 Tailscale 身份
  sb-ui/                # 如配置引用此相对路径
  clash-ui/             # 如配置引用此相对路径
```

只复制确实使用的数据；不要覆盖不确定的新状态或盲目复制整个运行目录。Tailscale 状态文件权限保持 `0600`，工作目录应位于持久存储上。旧目录保留作为回滚来源。

**重要顺序**：最好在原生 sing-box *首次启动前* 放好旧 `tailscaled.state`。本次首次启动时新目录出现了不同的状态文件并要求认证，随后通过停止服务、恢复旧状态文件、重启的方式处理（见第 6 节）。

## 4. 停用 Momo，启用原生 procd 服务

在配置和数据准备好之后，避免两个管理器同时运行 sing-box：

```sh
service momo stop
uci set momo.config.enabled='0'
uci commit momo
service momo disable

uci set sing-box.main.enabled='1'
uci set sing-box.main.user='root'
uci set sing-box.main.conffile='/etc/sing-box/config.json'
uci set sing-box.main.workdir='/usr/share/sing-box'
uci commit sing-box
```

本次原生服务以 `root` 运行，是因为它负责 TUN、路由、Tailscale 等网络操作；这**不是** Debian VPS `www-data` 服务方案。

先检查配置，再启动：

```sh
sing-box check -c /etc/sing-box/config.json -D /usr/share/sing-box
service sing-box start
service sing-box status
ps w | grep '[s]ing-box'
```

仅在检查成功且启动正常后启用开机启动：

```sh
service sing-box enable
ls -l /etc/rc.d/*sing-box* /etc/rc.d/*momo* 2>/dev/null
uci show sing-box
```

本次实际结果：`/etc/rc.d/S99sing-box -> ../init.d/sing-box` 存在，Momo 开机启动链接不存在；`service sing-box status` 返回 `running`，进程命令为：

```text
/usr/bin/sing-box run -c /etc/sing-box/config.json -D /usr/share/sing-box
```

注意：`service ... enable` 只配置开机启动，**不会替代当前的 `start`**；`sing-box.main.enabled='1'` 与 rc.d 启动链接两者都需要确认。

## 5. 验收

```sh
service sing-box status
ps w | grep '[s]ing-box'
ip -br addr show singtun
ip -br addr show tailscale0
nslookup www.google.com 127.0.0.1
wget -q -O /dev/null -T 10 https://www.baidu.com && echo 'Baidu OK'
logread -e sing-box | tail -50
```

本次已观察到：
- `singtun` 创建成功，LAN 客户端 5700X、minis 的连接进入 TUN 并按规则转发；
- `nslookup www.google.com 127.0.0.1` 返回 A/AAAA 记录；
- Baidu HTTPS 请求成功；
- `tailscale0` 接口已创建，但**接口存在不等于 Tailscale 已成功登录或可从外部访问**。

`logread` 中的 `daemon.err` 有时只是 stderr 的系统日志优先级，需看消息正文的 `INFO` / `WARN` / `ERROR`。本次旧进程停止时出现重复关闭资源的错误（`use of closed network connection` / `file already closed`），新进程仍正常运行；不要据此断言所有运行时功能均失败。

**Tailscale 最终验收**：从另一台同 Tailnet 的设备访问 R4S 原有 Tailscale IP，并验证所需 LAN 子网访问；本次会话尚未提供该外部连通性测试的成功证据，因此此项仍为待验证。

## 6. Tailscale 状态恢复（仅在需要时）

本次首次原生启动日志出现：

```text
endpoint/tailscale[tailscale]: Waiting for authentication
```

检查发现 `/usr/share/sing-box/tailscale/tailscaled.state` 与 `/etc/momo/run/tailscale/tailscaled.state` 不同。为尽量保留原设备身份，采取以下恢复步骤，**不要先点击新设备登录链接**：

```sh
service sing-box stop

# 仅在新状态文件存在时备份它
[ ! -f /usr/share/sing-box/tailscale/tailscaled.state ] || \
  cp -p /usr/share/sing-box/tailscale/tailscaled.state \
    /usr/share/sing-box/tailscale/tailscaled.state.bak

cp -p /etc/momo/run/tailscale/tailscaled.state \
  /usr/share/sing-box/tailscale/tailscaled.state
chmod 600 /usr/share/sing-box/tailscale/tailscaled.state

service sing-box start
service sing-box status
logread -e sing-box | grep -iE 'tailscale|authentication|login|control' | tail -30
```

本次恢复后新进程（PID 7825）已尝试连接 `controlplane.tailscale.com`，截取日志未再次出现 `Waiting for authentication`；**这不等于已经证实上线**。查看日志时区分旧进程和新进程，不要把旧认证提示误判为新启动失败。

## 7. 回滚

如果原生服务导致断网、DNS 异常或 Tailscale 无法恢复，优先从本地控制台或仍可用的 LAN SSH 执行。**不要让两个服务同时接管 TUN/防火墙**。

```sh
service sing-box stop
service sing-box disable
uci set sing-box.main.enabled='0'
uci commit sing-box

# 仅当决定恢复 Momo 时执行：
uci set momo.config.enabled='1'
uci commit momo
service momo enable
service momo start
```

回滚前应确认旧 Momo 配置、工作目录及其状态文件仍在；必要时从第 2 节的本地备份恢复。Momo 是否重新正确接管 DNS/fw4/nftables，需要在设备上验证，**不能仅以 `service momo status` 判定成功**。若 SSH 因路由切换中断，使用 LAN/控制台恢复，不要远程反复执行不确定的启动命令。

## 8. 安全与维护

- **不要**把 `/etc/sing-box/config.json`、`tailscaled.state`、代理密码、UUID、PSK、API secret、缓存数据库提交到本仓库。
- 本次配置的 API/Dashboard 监听包含 `0.0.0.0`；应限制管理端口只允许可信 LAN/VPN 访问，禁止从 WAN 直接暴露。Clash API 若未配置 secret，尤其需要隔离。
- 旧 Momo 目录暂时保留，稳定运行并完成 Tailscale 外部连通性验证后再考虑清理。
- 这里记录的是 **R4S 上已观察到的操作和结果**；没有声称已完成重启后的实机复验，也没有自动修改 firewall、dnsmasq、ZeroTier 或 Docker。
