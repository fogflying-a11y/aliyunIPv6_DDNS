#!/usr/bin/env bash

# ==========================================
# 阿里云 IPv6 DDNS 一键部署安装脚本
# ==========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}    开始部署 阿里云 IPv6 DDNS 自动化服务    ${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"

# ------------------------------------------
# 步骤 1：检查并安装系统与 Python 依赖
# ------------------------------------------
echo -e "\n${YELLOW}[1/5] 正在检查依赖软件...${PLAIN}"

# 识别包管理器
if command -v apt-get &>/dev/null; then
    PM="apt-get"
elif command -v dnf &>/dev/null; then
    PM="dnf"
elif command -v yum &>/dev/null; then
    PM="yum"
else
    echo -e "${RED}未识别的包管理器，请手动安装 python3 和 pip3！${PLAIN}"
    exit 1
fi

# 检查基础软件
if ! command -v python3 &>/dev/null || ! command -v pip3 &>/dev/null; then
    echo -e "正在补全基础环境 (python3, pip3, cron)..."
    $PM update -y
    $PM install -y python3 python3-pip cron || $PM install -y python3 python3-pip crontabs
fi

# 检查 Python 阿里云 SDK 模块
if ! python3 -c "import alibabacloud_alidns20150109, alibabacloud_tea_openapi" &>/dev/null; then
    echo -e "正在安装阿里云 SDK 依赖库..."
    pip3 install alibabacloud_alidns20150109 alibabacloud_tea_openapi --break-system-packages &>/dev/null \
    || pip3 install alibabacloud_alidns20150109 alibabacloud_tea_openapi
fi

echo -e "${GREEN}✓ 基础依赖检查完成！${PLAIN}"

# ------------------------------------------
# 步骤 2：检查网卡环境与交互选择
# ------------------------------------------
echo -e "\n${YELLOW}[2/5] 正在扫描具备公网 IPv6 的网卡...${PLAIN}"

# 提取有公网 IPv6 地址 (2xxx/3xxx 开头) 的网卡列表
mapfile -t IF_LIST < <(ip -6 addr show scope global | grep -E "inet6 (2|3)" | awk '{print $NF}' | sort -u)

SELECTED_IF=""

if [ ${#IF_LIST[@]} -eq 0 ]; then
    echo -e "${RED}警告：系统未自动匹配到 2xxx/3xxx 开头的公网 IPv6 地址！${PLAIN}"
    read -rp "请手动输入需要绑定的网卡名称 (例如 ens32 或 eth0): " SELECTED_IF
elif [ ${#IF_LIST[@]} -eq 1 ]; then
    SELECTED_IF="${IF_LIST[0]}"
    echo -e "自动绑定唯一可用公网 IPv6 网卡: ${GREEN}${SELECTED_IF}${PLAIN}"
else
    echo -e "检测到多张具备公网 IPv6 的网卡："
    for i in "${!IF_LIST[@]}"; do
        echo -e "  $((i+1))) ${IF_LIST[$i]}"
    done
    while true; do
        read -rp "请选择绑定的网卡编号 [1-${#IF_LIST[@]}]: " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#IF_LIST[@]}" ]; then
            SELECTED_IF="${IF_LIST[$((CHOICE-1))]}"
            break
        else
            echo -e "${RED}输入无效，请输入对应数字编号！${PLAIN}"
        fi
    done
fi

echo -e "最终选择绑定网卡: ${GREEN}${SELECTED_IF}${PLAIN}"

# ------------------------------------------
# 步骤 3：交互设置阿里云 DNS 配置并保存
# ------------------------------------------
echo -e "\n${YELLOW}[3/5] 配置阿里云 API 信息与域名参数...${PLAIN}"

read -rp "请输入 AccessKey ID: " AK_ID
read -rp "请输入 AccessKey Secret: " AK_SECRET
read -rp "请输入主域名 (例如 example.com): " DOMAIN
read -rp "请输入主机记录 RR (例如 @ 或 www, 默认 @): " RR
RR=${RR:-@}

mkdir -p /etc/alidns

cat <<EOF > /etc/alidns/credentials
ALIBABA_CLOUD_AK_ID=${AK_ID}
ALIBABA_CLOUD_AK_SECRET=${AK_SECRET}
DOMAIN=${DOMAIN}
RR=${RR}
INTERFACE=${SELECTED_IF}
EOF

chmod 600 /etc/alidns/credentials
echo -e "${GREEN}✓ 配置文件已保存至 /etc/alidns/credentials (安全权限: 600)${PLAIN}"

# ------------------------------------------
# 步骤 4：部署 Python DDNS 核心代码
# ------------------------------------------
echo -e "\n${YELLOW}[4/5] 正在落地核心脚本 /etc/alidns/alidns-ipv6-ddns.py ...${PLAIN}"

cat << 'EOF' > /etc/alidns/alidns-ipv6-ddns.py
#!/usr/bin/env python3
"""
alidns-ipv6-ddns.py
阿里云 DNS IPv6 (AAAA) 动态解析更新脚本
"""
import logging
import os
import subprocess
import sys
import urllib.request

from alibabacloud_alidns20150109.client import Client as DnsClient
from alibabacloud_alidns20150109 import models as dns_models
from alibabacloud_tea_openapi import models as open_api_models

CREDENTIALS_FILE = "/etc/alidns/credentials"
TTL = 600
LOG_FILE = "/var/log/alidns-ipv6-ddns.log"
DEFAULT_INTERFACE = "ens32"

def setup_logger():
    handlers = [logging.StreamHandler(sys.stdout)]
    try:
        handlers.append(logging.FileHandler(LOG_FILE))
    except (PermissionError, FileNotFoundError):
        pass
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=handlers,
    )
    return logging.getLogger(__name__)

log = setup_logger()

def load_config():
    config = {}
    try:
        with open(CREDENTIALS_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    config[key.strip()] = value.strip()
    except FileNotFoundError:
        log.error(f"凭据文件不存在: {CREDENTIALS_FILE}")
        sys.exit(1)
    return config

def get_ipv6(interface=DEFAULT_INTERFACE):
    try:
        cmd = ["ip", "-6", "addr", "show"]
        if interface:
            cmd.extend(["dev", interface])
        cmd.extend(["scope", "global"])

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        candidates = []
        for line in result.stdout.splitlines():
            if "inet6" in line and "temporary" not in line and "deprecated" not in line:
                parts = line.strip().split()
                if len(parts) >= 2:
                    ip = parts[1].split("/")[0]
                    if ip.startswith("2") or ip.startswith("3"):
                        if "mngtmpaddr" in line:
                            return ip
                        candidates.append(ip)
        if candidates:
            return candidates[0]
    except Exception as e:
        log.warning(f"本地网卡提取失败: {e}")

    urls = ["https://api6.ipify.org", "https://ifconfig.co", "https://ipv6.icanhazip.com"]
    for url in urls:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                ip = resp.read().decode("utf-8").strip()
                if ip and (ip.startswith("2") or ip.startswith("3")):
                    return ip
        except Exception:
            continue
    return ""

def create_client(ak_id, ak_secret):
    config = open_api_models.Config(
        access_key_id=ak_id,
        access_key_secret=ak_secret,
        endpoint="alidns.aliyuncs.com",
    )
    return DnsClient(config)

def main():
    cfg = load_config()
    ak_id = cfg.get("ALIBABA_CLOUD_AK_ID", "")
    ak_secret = cfg.get("ALIBABA_CLOUD_AK_SECRET", "")
    domain = cfg.get("DOMAIN", "")
    rr = cfg.get("RR", "@")
    interface = cfg.get("INTERFACE", DEFAULT_INTERFACE)

    if not ak_id or not ak_secret or not domain:
        log.error("缺少必要配置参数！")
        sys.exit(1)

    current_ipv6 = get_ipv6(interface=interface)
    if not current_ipv6:
        log.error(f"无法获取有效公网 IPv6 地址")
        sys.exit(1)

    log.info(f"获取公网 IPv6 地址成功: {current_ipv6} (网卡: {interface})")
    client = create_client(ak_id, ak_secret)
    sub_domain = f"{rr}.{domain}" if rr != "@" else domain

    try:
        request = dns_models.DescribeSubDomainRecordsRequest(sub_domain=sub_domain, type="AAAA")
        resp = client.describe_sub_domain_records(request)
        records = resp.body.domain_records.record if resp.body.domain_records else []
    except Exception as e:
        log.error(f"查询 DNS 解析失败: {e}")
        sys.exit(1)

    if records:
        record = records[0]
        if record.value == current_ipv6:
            log.info(f"DNS 记录未发生改变 [{sub_domain} AAAA {current_ipv6}]，跳过更新")
            return
        log.info(f"更新解析: {sub_domain} AAAA {record.value} -> {current_ipv6}")
        try:
            update_req = dns_models.UpdateDomainRecordRequest(
                record_id=record.record_id, rr=rr, type="AAAA", value=current_ipv6, ttl=TTL
            )
            client.update_domain_record(update_req)
            log.info("DNS 更新成功 ✓")
        except Exception as e:
            log.error(f"更新失败: {e}")
            sys.exit(1)
    else:
        log.info(f"创建解析: {sub_domain} AAAA {current_ipv6}")
        try:
            add_req = dns_models.AddDomainRecordRequest(
                domain_name=domain, rr=rr, type="AAAA", value=current_ipv6, ttl=TTL
            )
            resp = client.add_domain_record(add_req)
            log.info(f"DNS 创建成功 ✓ RecordId: {resp.body.record_id}")
        except Exception as e:
            log.error(f"创建失败: {e}")
            sys.exit(1)

if __name__ == "__main__":
    main()
EOF

chmod +x /etc/alidns/alidns-ipv6-ddns.py
echo -e "${GREEN}✓ 脚本部署完成：/etc/alidns/alidns-ipv6-ddns.py${PLAIN}"

# ------------------------------------------
# 步骤 5：设定 Cron 定时任务
# ------------------------------------------
echo -e "\n${YELLOW}[5/5] 设置定时任务执行频率...${PLAIN}"
echo "1) 每 24 小时自动执行"
echo "2) 每 48 小时自动执行"
echo "3) 每 72 小时自动执行"
echo "4) 每 96 小时自动执行"
echo "5) 每 10 分钟自动执行 (推荐：防止家宽 IPv6 变动导致较长断网)"

read -rp "请选择定时选项 [1-5]: " CRON_CHOICE

case $CRON_CHOICE in
    1) CRON_EXPR="0 0 * * *" ;;
    2) CRON_EXPR="0 0 */2 * * *" ;;
    3) CRON_EXPR="0 0 */3 * * *" ;;
    4) CRON_EXPR="0 0 */4 * * *" ;;
    5) CRON_EXPR="*/10 * * * *" ;;
    *) CRON_EXPR="0 0 * * *" ;;
esac

# 移出已存在的同类型 cron 任务，避免重复写入
(crontab -l 2>/dev/null | grep -v "/etc/alidns/alidns-ipv6-ddns.py") | crontab -

# 写入新的 cron 表达式
(crontab -l 2>/dev/null; echo "${CRON_EXPR} /usr/bin/python3 /etc/alidns/alidns-ipv6-ddns.py >/dev/null 2>&1") | crontab -

echo -e "${GREEN}✓ Cron 定时任务添加成功，表达式: [ ${CRON_EXPR} ]${PLAIN}"

# ------------------------------------------
# 部署完成并尝试首次运行测试
# ------------------------------------------
echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}      部署全部完成！正在执行首次测试...     ${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}\n"

python3 /etc/alidns/alidns-ipv6-ddns.py

echo -e "\n如需手动执行，可运行: ${YELLOW}python3 /etc/alidns/alidns-ipv6-ddns.py${PLAIN}"
echo -e "日志查看路径: ${YELLOW}/var/log/alidns-ipv6-ddns.log${PLAIN}"