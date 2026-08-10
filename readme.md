# Aliyun IPv6 DDNS (阿里云 IPv6 动态域名解析)

一个专为 Linux/Ubuntu 环境设计的阿里云 DNS IPv6 (AAAA) 动态解析一键部署脚本。能够自动智能识别网卡的有效公网 IPv6 地址（优先绑定稳定 SLAAC 后缀，自动过滤 ULA 内网地址及临时地址），并通过 Crontab 实现静默自动化更新。

---

## ✨ 特性亮点

- 🚀 **零依赖门槛**：自动检测并安装 Python3、`pip3` 以及阿里云 API SDK（`alibabacloud_alidns20150109`）。
- 🎯 **精准匹配 IPv6**：智能识别 `2xxx:` / `3xxx:` 开头的全球单播地址，优先匹配基于 MAC 地址生成的 SLAAC (`mngtmpaddr`) 固定后缀，彻底解决多 IPv6 变动抖动问题。
- 🛡️ **隔离私有地址**：自动过滤 `fd00::/7` (ULA 内网地址) 及 `fe80::` (链路本地地址)。
- 🔐 **凭据安全**：配置文件存放在 `/etc/alidns/credentials`，并自动设置 `600` 权限保护 AccessKey。
- ⏰ **交互式 Cron 部署**：支持自定义定时周期（推荐 10 分钟或每 24-96 小时）。

---

## 🚀 快速开始（一键安装）

在目标 Linux 服务器上以 `root` 权限执行以下任意一条命令即可开启交互式部署：

### 使用 `curl`（推荐）
```bash
curl -fsSL https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash

```

### 使用 `wget `方式：

```
wget -qO- https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

### 使用 `ghproxy` 加速节点

```
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

# 手动执行

### 1. 下载或新建 install.sh 并赋予执行权限

```
chmod +x install.sh
```

### 2. 运行脚本进行安装

```
sudo ./install.sh
```

架构设计说明（优势）

自包含（Self-contained）： 使用 Shell 的 cat << 'EOF' 技术把 Python 核心文件嵌入在安装脚本内部，无需额外托管文件或使用 git clone。

软件源容错： 自动探测当前系统使用的是 apt 还是 yum/dnf，并对 Python 安装 pip 时的 --break-system-packages 参数做了版本兼容处理。

防止 Cron 任务重复： 安装脚本会在新增定时任务前，清洗掉旧的 /etc/alidns/alidns-ipv6-ddns.py 定时条目，即便多次运行安装脚本也不会在系统产生垃圾 Cron 记录。

```

```
