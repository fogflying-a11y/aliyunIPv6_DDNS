**在任意新 Linux 服务器上（Ubuntu、Debian、CentOS 等），只需执行以下三步即可：**

使用 curl 方式：

```
curl -fsSL https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

使用 wget 方式：

```
wget -qO- https://raw.githubusercontent.com/fogflying-a11y/aliyunIPv6_DDNS/main/install.sh | sudo bash
```

使用 ghproxy 加速节点

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
