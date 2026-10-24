# Aliyun & Cloudflare IPv6 DDNS (双解析动态域名服务)

一个专为 Linux 环境设计的阿里云 / Cloudflare DNS IPv6 (AAAA) 动态解析一键部署脚本。能够自动智能识别网卡的有效公网 IPv6 地址（优先绑定稳定 SLAAC 后缀，自动过滤 ULA 内网地址及临时地址），支持**阿里云、Cloudflare 单独或同时双解析**，并通过实时内核事件监听与 Crontab 保底实现自动化秒级刷新。

---

## ✨ 特性亮点

- 🚀 **多服务商与双解析**：支持 **阿里云 DNS**、**Cloudflare DNS** 或 **两者同时双解析**，一次获取 IPv6，多平台同步更新。
- ⚡ **原生轻量**：Cloudflare API 基于 Python 内置 HTTP 客户端开发，无需额外安装第三方包；Proxy 小黄云代理默认关闭（DNS Only 直连），保证 IPv6 直连连通性。
- 🎯 **精准匹配 IPv6**：智能识别 `2xxx:` / `3xxx:` 开头的全球单播地址，优先匹配基于 MAC 地址生成的 SLAAC (`mngtmpaddr`) 固定后缀，彻底解决多 IPv6 变动抖动问题。
- 🛡️ **隔离私有地址**：自动过滤 `fd00::/7` (ULA 内网地址) 及 `fe80::` (链路本地地址)。
- 🔐 **凭据安全**：配置文件存放在 `/etc/alidns/credentials`，并自动设置 `600` 权限保护 AccessKey 与 API Token。
- ⚡ **实时变动感知**：支持可选的 `systemd` + 内核 Netlink (`ip monitor`) 守护进程，IPv6 地址一旦变更秒级触发 DNS 刷新，彻底摆脱轮询延迟。
- ⏰ **灵活定时任务**：支持交互式配置 Crontab 周期（推荐 10 分钟或自定义周期）作为保底防漏策略。

---

## 🚀 快速开始（一键安装）

在目标 Linux 服务器上以 `root` 权限执行以下任意一条命令即可开启交互式部署：

### 使用 `curl`（推荐）
```bash
curl -fsSL https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

### 使用 `wget` 方式：
```bash
wget -qO- https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

### 使用 `ghproxy` 加速节点
```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

---

## 🛠️ 手动执行

### 1. 下载或新建 install.sh 并赋予执行权限
```bash
chmod +x install.sh
```

### 2. 运行脚本进行安装
```bash
sudo ./install.sh
```

---

## 💡 架构设计与优势

- **自包含（Self-contained）**：使用 Shell 的 `cat << 'EOF'` 技术把 Python 核心文件嵌入在安装脚本内部，无需额外托管文件或使用 git clone。
- **实时内核监听 + 智能防抖**：采用 `ip -6 monitor address` 零资源监听内核 Netlink 事件，配合 3 秒智能防抖，彻底消除家宽路由器重新拨号时的解析延迟。
- **软件源容错**：自动探测当前系统包管理器（apt/yum/dnf），并对 Python 安装 pip 时的 `--break-system-packages` 参数做了版本兼容处理。
- **常用管理命令**：
  - 查看实时监听状态：`systemctl status alidns-monitor`
  - 查看实时触发日志：`journalctl -u alidns-monitor -f`
  - 查看解析更新日志：`cat /var/log/alidns-ipv6-ddns.log`

