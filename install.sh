#!/usr/bin/env bash

# ==========================================
# 阿里云 / Cloudflare IPv6 DDNS 一键部署安装脚本
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

echo -e "${GREEN}================================================${PLAIN}"
echo -e "${GREEN}  开始部署 阿里云 / Cloudflare IPv6 DDNS 服务   ${PLAIN}"
echo -e "${GREEN}================================================${PLAIN}"

# ------------------------------------------
# 步骤 1：检查并安装系统与 Python 依赖
# ------------------------------------------
echo -e "\n${YELLOW}[1/6] 正在检查依赖软件...${PLAIN}"

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

if ! command -v python3 &>/dev/null || ! command -v pip3 &>/dev/null; then
    echo -e "正在补全基础环境 (python3, pip3, cron)..."
    $PM update -y
    $PM install -y python3 python3-pip cron || $PM install -y python3 python3-pip crontabs
fi

echo -e "${GREEN}✓ 基础依赖检查完成！${PLAIN}"

# ------------------------------------------
# 步骤 2：检查网卡环境与交互选择 (修复未检测到时的退路)
# ------------------------------------------
echo -e "\n${YELLOW}[2/6] 正在扫描具备公网 IPv6 的网卡...${PLAIN}"

mapfile -t IF_LIST < <(ip -6 addr show scope global | grep -E "inet6 (2|3)" | awk '{print $NF}' | sort -u)

SELECTED_IF=""

if [ ${#IF_LIST[@]} -eq 0 ]; then
    echo -e "${RED}警告：系统未自动匹配到 2xxx/3xxx 开头的公网 IPv6 地址！${PLAIN}"
    echo -e "可能当前网卡尚未获取到公网 IPv6，或使用非标准前缀。"
    echo -e "以下为系统检测到的所有本地物理网卡："
    
    # 获取系统所有非 loopback 网卡
    mapfile -t ALL_IFS < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")
    for i in "${!ALL_IFS[@]}"; do
        echo -e "  $((i+1))) ${ALL_IFS[$i]}"
    done

    while [ -z "$SELECTED_IF" ]; do
        read -rp "请选择序号或直接输入网卡名称 (如 ens32/eth0): " INPUT_IF < /dev/tty
        if [[ "$INPUT_IF" =~ ^[0-9]+$ ]] && [ "$INPUT_IF" -ge 1 ] && [ "$INPUT_IF" -le "${#ALL_IFS[@]}" ]; then
            SELECTED_IF="${ALL_IFS[$((INPUT_IF-1))]}"
        elif [ -n "$INPUT_IF" ]; then
            SELECTED_IF="$INPUT_IF"
        else
            echo -e "${RED}错误：网卡名称不能为空，请重新输入！${PLAIN}"
        fi
    done
elif [ ${#IF_LIST[@]} -eq 1 ]; then
    SELECTED_IF="${IF_LIST[0]}"
    echo -e "自动绑定唯一可用公网 IPv6 网卡: ${GREEN}${SELECTED_IF}${PLAIN}"
else
    echo -e "检测到多张具备公网 IPv6 的网卡："
    for i in "${!IF_LIST[@]}"; do
        echo -e "  $((i+1))) ${IF_LIST[$i]}"
    done
    while true; do
        read -rp "请选择绑定的网卡编号 [1-${#IF_LIST[@]}]: " CHOICE < /dev/tty
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
# 步骤 3：交互设置 DNS 服务商与凭证配置
# ------------------------------------------
echo -e "\n${YELLOW}[3/6] 配置 DNS 服务商与域名参数...${PLAIN}"
echo "请选择要启用的 DNS 动态解析服务："
echo "  1) 阿里云 DNS"
echo "  2) Cloudflare DNS"
echo "  3) 同时启用 (阿里云 + Cloudflare 双解析)"

DNS_PROVIDER=""
while true; do
    read -rp "请选择 [1-3] (默认 3): " DNS_PROVIDER < /dev/tty
    DNS_PROVIDER=${DNS_PROVIDER:-3}
    if [[ "$DNS_PROVIDER" =~ ^[1-3]$ ]]; then
        break
    fi
    echo -e "${RED}输入无效，请输入 1、2 或 3！${PLAIN}"
done

ENABLE_ALIDNS="false"
ENABLE_CLOUDFLARE="false"

case $DNS_PROVIDER in
    1) ENABLE_ALIDNS="true" ;;
    2) ENABLE_CLOUDFLARE="true" ;;
    3) ENABLE_ALIDNS="true"; ENABLE_CLOUDFLARE="true" ;;
esac

# 阿里云配置
AK_ID=""
AK_SECRET=""
ALI_DOMAIN=""
ALI_RR="@"

if [ "$ENABLE_ALIDNS" = "true" ]; then
    echo -e "\n${YELLOW}--- [配置 阿里云 DNS] ---${PLAIN}"
    if ! python3 -c "import alibabacloud_alidns20150109, alibabacloud_tea_openapi" &>/dev/null; then
        echo -e "正在安装阿里云 SDK 依赖库..."
        pip3 install alibabacloud_alidns20150109 alibabacloud_tea_openapi --break-system-packages &>/dev/null \
        || pip3 install alibabacloud_alidns20150109 alibabacloud_tea_openapi
    fi
    while [ -z "$AK_ID" ]; do
        read -rp "请输入 阿里云 AccessKey ID: " AK_ID < /dev/tty
        [ -z "$AK_ID" ] && echo -e "${RED}AccessKey ID 不能为空！${PLAIN}"
    done

    while [ -z "$AK_SECRET" ]; do
        read -rp "请输入 阿里云 AccessKey Secret: " AK_SECRET < /dev/tty
        [ -z "$AK_SECRET" ] && echo -e "${RED}AccessKey Secret 不能为空！${PLAIN}"
    done

    while [ -z "$ALI_DOMAIN" ]; do
        read -rp "请输入 阿里云 主域名 (例如 example.com): " ALI_DOMAIN < /dev/tty
        [ -z "$ALI_DOMAIN" ] && echo -e "${RED}主域名不能为空！${PLAIN}"
    done

    read -rp "请输入 阿里云 主机记录 RR (例如 @ 或 www, 默认 @): " ALI_RR < /dev/tty
    ALI_RR=${ALI_RR:-@}
fi

# Cloudflare 配置
CF_TOKEN=""
CF_DOMAIN=""
CF_RR="@"
CF_PROXIED="false"

if [ "$ENABLE_CLOUDFLARE" = "true" ]; then
    echo -e "\n${YELLOW}--- [配置 Cloudflare DNS] ---${PLAIN}"
    echo -e "提示：请使用具备 [Zone - DNS - Edit] 权限的 API Token（安全推荐）"
    while [ -z "$CF_TOKEN" ]; do
        read -rp "请输入 Cloudflare API Token: " CF_TOKEN < /dev/tty
        [ -z "$CF_TOKEN" ] && echo -e "${RED}API Token 不能为空！${PLAIN}"
    done

    while [ -z "$CF_DOMAIN" ]; do
        read -rp "请输入 Cloudflare 主域名 (Zone名称，如 example.com): " CF_DOMAIN < /dev/tty
        [ -z "$CF_DOMAIN" ] && echo -e "${RED}主域名不能为空！${PLAIN}"
    done

    read -rp "请输入 Cloudflare 主机记录 RR (例如 @ 或 www, 默认 @): " CF_RR < /dev/tty
    CF_RR=${CF_RR:-@}

    read -rp "是否开启 Cloudflare CDN 代理(小黄云 Proxy)? [y/N] (默认 N 关闭以保证直连): " CF_PROXY_INPUT < /dev/tty
    if [[ "$CF_PROXY_INPUT" =~ ^[Yy]$ ]]; then
        CF_PROXIED="true"
        echo -e "Cloudflare 代理状态: ${GREEN}已开启 (Proxied)${PLAIN}"
    else
        CF_PROXIED="false"
        echo -e "Cloudflare 代理状态: ${YELLOW}已关闭 (DNS Only 直连)${PLAIN}"
    fi
fi

mkdir -p /etc/alidns

cat <<EOF > /etc/alidns/credentials
ENABLE_ALIDNS=${ENABLE_ALIDNS}
ALIBABA_CLOUD_AK_ID=${AK_ID}
ALIBABA_CLOUD_AK_SECRET=${AK_SECRET}
DOMAIN=${ALI_DOMAIN}
RR=${ALI_RR}

ENABLE_CLOUDFLARE=${ENABLE_CLOUDFLARE}
CF_API_TOKEN=${CF_TOKEN}
CF_DOMAIN=${CF_DOMAIN}
CF_RR=${CF_RR}
CF_PROXIED=${CF_PROXIED}

INTERFACE=${SELECTED_IF}
EOF

chmod 600 /etc/alidns/credentials
echo -e "${GREEN}✓ 配置文件已保存至 /etc/alidns/credentials (安全权限: 600)${PLAIN}"

# ------------------------------------------
# 步骤 4：部署 Python DDNS 核心代码
# ------------------------------------------
echo -e "\n${YELLOW}[4/6] 正在落地核心脚本 /etc/alidns/alidns-ipv6-ddns.py ...${PLAIN}"

cat << 'EOF' > /etc/alidns/alidns-ipv6-ddns.py
#!/usr/bin/env python3
"""
alidns-ipv6-ddns.py
阿里云 / Cloudflare IPv6 (AAAA) 动态解析更新脚本 (支持双解析)
"""
import json
import logging
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

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

# ==========================================
# 阿里云 DNS 更新模块
# ==========================================
def sync_aliyun(ak_id, ak_secret, domain, rr, current_ipv6):
    try:
        from alibabacloud_alidns20150109.client import Client as DnsClient
        from alibabacloud_alidns20150109 import models as dns_models
        from alibabacloud_tea_openapi import models as open_api_models
    except ImportError:
        log.error("[Aliyun] 缺少阿里云 SDK，请安装: pip3 install alibabacloud_alidns20150109 alibabacloud_tea_openapi")
        return False

    sub_domain = f"{rr}.{domain}" if rr != "@" else domain
    log.info(f"[Aliyun] 正在检查解析记录: {sub_domain} (AAAA)")

    try:
        config = open_api_models.Config(
            access_key_id=ak_id,
            access_key_secret=ak_secret,
            endpoint="alidns.aliyuncs.com",
        )
        client = DnsClient(config)
        request = dns_models.DescribeSubDomainRecordsRequest(sub_domain=sub_domain, type="AAAA")
        resp = client.describe_sub_domain_records(request)
        records = resp.body.domain_records.record if resp.body.domain_records else []
    except Exception as e:
        log.error(f"[Aliyun] 查询 DNS 解析失败: {e}")
        return False

    if records:
        record = records[0]
        if record.value == current_ipv6:
            log.info(f"[Aliyun] DNS 记录未发生改变 [{sub_domain} AAAA {current_ipv6}]，跳过更新")
            return True
        log.info(f"[Aliyun] 更新解析: {sub_domain} AAAA {record.value} -> {current_ipv6}")
        try:
            update_req = dns_models.UpdateDomainRecordRequest(
                record_id=record.record_id, rr=rr, type="AAAA", value=current_ipv6, ttl=TTL
            )
            client.update_domain_record(update_req)
            log.info("[Aliyun] DNS 更新成功 ✓")
            return True
        except Exception as e:
            log.error(f"[Aliyun] 更新失败: {e}")
            return False
    else:
        log.info(f"[Aliyun] 创建解析: {sub_domain} AAAA {current_ipv6}")
        try:
            add_req = dns_models.AddDomainRecordRequest(
                domain_name=domain, rr=rr, type="AAAA", value=current_ipv6, ttl=TTL
            )
            resp = client.add_domain_record(add_req)
            log.info(f"[Aliyun] DNS 创建成功 ✓ RecordId: {resp.body.record_id}")
            return True
        except Exception as e:
            log.error(f"[Aliyun] 创建失败: {e}")
            return False

# ==========================================
# Cloudflare DNS 更新模块 (内置 REST API)
# ==========================================
def cf_api_request(method, endpoint, token, data=None):
    url = f"https://api.cloudflare.com/client/v4{endpoint}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "User-Agent": "alidns-cf-ipv6-ddns/1.0"
    }
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"HTTP {e.code}: {err_msg}")
    except Exception as e:
        raise RuntimeError(str(e))

def get_cf_zone_id(token, zone_name):
    query = urllib.parse.urlencode({"name": zone_name, "status": "active"})
    res = cf_api_request("GET", f"/zones?{query}", token)
    if not res.get("success") or not res.get("result"):
        raise RuntimeError(f"未找到域名 {zone_name} 对应的 Zone ID，请确认 Token 权限或域名是否正确")
    return res["result"][0]["id"]

def sync_cloudflare(token, zone_name, rr, current_ipv6, proxied=False):
    full_domain = zone_name if rr in ("@", "") else f"{rr}.{zone_name}"
    log.info(f"[Cloudflare] 正在检查解析记录: {full_domain} (AAAA)")

    try:
        zone_id = get_cf_zone_id(token, zone_name)
    except Exception as e:
        log.error(f"[Cloudflare] 获取 Zone ID 失败: {e}")
        return False

    try:
        query = urllib.parse.urlencode({"type": "AAAA", "name": full_domain})
        res = cf_api_request("GET", f"/zones/{zone_id}/dns_records?{query}", token)
        records = res.get("result", []) if res.get("success") else []
    except Exception as e:
        log.error(f"[Cloudflare] 查询 DNS 解析记录失败: {e}")
        return False

    if records:
        record = records[0]
        rec_id = record["id"]
        old_ip = record.get("content", "")
        old_proxied = record.get("proxied", False)

        if old_ip == current_ipv6 and old_proxied == proxied:
            log.info(f"[Cloudflare] DNS 记录未发生改变 [{full_domain} AAAA {current_ipv6} proxied={proxied}]，跳过更新")
            return True

        log.info(f"[Cloudflare] 更新解析: {full_domain} AAAA {old_ip} -> {current_ipv6} (proxied={proxied})")
        payload = {
            "type": "AAAA",
            "name": full_domain,
            "content": current_ipv6,
            "ttl": 1 if proxied else TTL,
            "proxied": proxied
        }
        try:
            cf_api_request("PUT", f"/zones/{zone_id}/dns_records/{rec_id}", token, payload)
            log.info("[Cloudflare] DNS 更新成功 ✓")
            return True
        except Exception as e:
            log.error(f"[Cloudflare] 更新失败: {e}")
            return False
    else:
        log.info(f"[Cloudflare] 创建解析: {full_domain} AAAA {current_ipv6} (proxied={proxied})")
        payload = {
            "type": "AAAA",
            "name": full_domain,
            "content": current_ipv6,
            "ttl": 1 if proxied else TTL,
            "proxied": proxied
        }
        try:
            cf_api_request("POST", f"/zones/{zone_id}/dns_records", token, payload)
            log.info("[Cloudflare] DNS 创建成功 ✓")
            return True
        except Exception as e:
            log.error(f"[Cloudflare] 创建失败: {e}")
            return False

def main():
    cfg = load_config()
    interface = cfg.get("INTERFACE", DEFAULT_INTERFACE)

    # 阿里云配置
    enable_ali = cfg.get("ENABLE_ALIDNS", "false").lower() == "true"
    ak_id = cfg.get("ALIBABA_CLOUD_AK_ID", "")
    ak_secret = cfg.get("ALIBABA_CLOUD_AK_SECRET", "")
    ali_domain = cfg.get("DOMAIN", "")
    ali_rr = cfg.get("RR", "@")

    # Cloudflare 配置
    enable_cf = cfg.get("ENABLE_CLOUDFLARE", "false").lower() == "true"
    cf_token = cfg.get("CF_API_TOKEN", "")
    cf_domain = cfg.get("CF_DOMAIN", "")
    cf_rr = cfg.get("CF_RR", "@")
    cf_proxied = cfg.get("CF_PROXIED", "false").lower() == "true"

    # 兼容历史无 ENABLE_* 标志但有旧配置的情况
    if not enable_ali and not enable_cf and ak_id and ak_secret and ali_domain:
        enable_ali = True

    if not enable_ali and not enable_cf:
        log.error("未启用任何 DNS 服务商，请检查 /etc/alidns/credentials 配置！")
        sys.exit(1)

    current_ipv6 = get_ipv6(interface=interface)
    if not current_ipv6:
        log.error(f"无法在网卡 [{interface}] 或公网 API 获取有效 IPv6 地址")
        sys.exit(1)

    log.info(f"获取公网 IPv6 地址成功: {current_ipv6} (网卡: {interface})")

    success_all = True
    if enable_ali:
        if not ak_id or not ak_secret or not ali_domain:
            log.error("[Aliyun] 启用但缺少必要配置参数！")
            success_all = False
        else:
            if not sync_aliyun(ak_id, ak_secret, ali_domain, ali_rr, current_ipv6):
                success_all = False

    if enable_cf:
        if not cf_token or not cf_domain:
            log.error("[Cloudflare] 启用但缺少必要配置参数！")
            success_all = False
        else:
            if not sync_cloudflare(cf_token, cf_domain, cf_rr, current_ipv6, proxied=cf_proxied):
                success_all = False

    if not success_all:
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF

chmod +x /etc/alidns/alidns-ipv6-ddns.py
echo -e "${GREEN}✓ 脚本部署完成：/etc/alidns/alidns-ipv6-ddns.py${PLAIN}"

# ------------------------------------------
# 步骤 5：配置 IPv6 变动实时监听服务 (systemd)
# ------------------------------------------
echo -e "\n${YELLOW}[5/6] 配置 IPv6 变动实时监听服务 (systemd 守护进程)...${PLAIN}"
echo -e "开启后将利用内核 Netlink 事件实时监听 IPv6 变动，一旦发生改变将在数秒内立刻触发 DNS 更新。"

ENABLE_SYSTEMD=""
read -rp "是否开启 systemd 实时监听服务? [Y/n] (默认 Y): " ENABLE_SYSTEMD < /dev/tty
ENABLE_SYSTEMD=${ENABLE_SYSTEMD:-Y}

if [[ "$ENABLE_SYSTEMD" =~ ^[Yy]$ ]]; then
    if ! command -v systemctl &>/dev/null; then
        echo -e "${YELLOW}提示：当前环境未检测到 systemctl 命令，跳过 systemd 守护进程配置。${PLAIN}"
    else
        cat << 'EOF' > /etc/alidns/alidns-monitor.sh
#!/usr/bin/env bash

TARGET_SCRIPT="/etc/alidns/alidns-ipv6-ddns.py"
PYTHON_BIN="$(command -v python3 || echo /usr/bin/python3)"
CRED_FILE="/etc/alidns/credentials"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 IPv6 变动内核事件监听服务..."

INTERFACE=""
if [ -f "$CRED_FILE" ]; then
    INTERFACE=$(grep "^INTERFACE=" "$CRED_FILE" | cut -d'=' -f2 | tr -d ' "\r')
fi

MONITOR_CMD=(ip -6 monitor address)
if [ -n "$INTERFACE" ]; then
    MONITOR_CMD+=(dev "$INTERFACE")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 监听网卡: $INTERFACE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 监听所有网卡"
fi

"${MONITOR_CMD[@]}" | while read -r line; do
    # 只要包含全球单播前缀 (2xxx 或 3xxx)，说明公网 IPv6 发生增删变动
    if echo "$line" | grep -qE "inet6 (2|3)"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到 IPv6 地址变动: $line"

        # 防抖：等待 3 秒等待网络配置稳定，合并瞬时多次事件
        sleep 3
        # 丢弃缓冲队列中因同一次重拨产生的多余通知
        while read -t 1 -r _; do :; done

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 触发 DDNS 记录更新..."
        $PYTHON_BIN "$TARGET_SCRIPT"
    fi
done
EOF
        chmod +x /etc/alidns/alidns-monitor.sh

        cat << 'EOF' > /etc/systemd/system/alidns-monitor.service
[Unit]
Description=Aliyun IPv6 DDNS Realtime Monitor Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/alidns/alidns-monitor.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now alidns-monitor.service
        echo -e "${GREEN}✓ systemd 实时监听服务已启动并设为开机自启 (alidns-monitor.service)${PLAIN}"
    fi
fi

# ------------------------------------------
# 步骤 6：设定 Cron 定时任务
# ------------------------------------------
echo -e "\n${YELLOW}[6/6] 设置 Cron 定时任务执行频率 (用于周期性保底检查)...${PLAIN}"
echo "1) 每 10 分钟自动执行 (推荐：防止漏触发)"
echo "2) 每 24 小时自动执行"
echo "3) 每 48 小时自动执行"
echo "4) 每 72 小时自动执行"
echo "5) 每 96 小时自动执行"
echo "6) 不配置 Cron 任务"

CRON_CHOICE=""
read -rp "请选择定时选项 [1-6] (默认 1): " CRON_CHOICE < /dev/tty
CRON_CHOICE=${CRON_CHOICE:-1}

CRON_EXPR=""
case $CRON_CHOICE in
    1) CRON_EXPR="*/10 * * * *" ;;
    2) CRON_EXPR="0 0 * * *" ;;
    3) CRON_EXPR="0 0 */2 * *" ;;
    4) CRON_EXPR="0 0 */3 * *" ;;
    5) CRON_EXPR="0 0 */4 * *" ;;
    6) CRON_EXPR="" ;;
    *) CRON_EXPR="*/10 * * * *" ;;
esac

PYTHON_BIN="$(command -v python3 || echo /usr/bin/python3)"

# 清洗旧的定时条目，防止重复
(crontab -l 2>/dev/null | grep -v "/etc/alidns/alidns-ipv6-ddns.py") | crontab -

if [ -n "$CRON_EXPR" ]; then
    (crontab -l 2>/dev/null; echo "${CRON_EXPR} ${PYTHON_BIN} /etc/alidns/alidns-ipv6-ddns.py >/dev/null 2>&1") | crontab -
    echo -e "${GREEN}✓ Cron 定时任务添加成功，表达式: [ ${CRON_EXPR} ]${PLAIN}"
else
    echo -e "${YELLOW}已跳过 Cron 定时任务设置。${PLAIN}"
fi

# ------------------------------------------
# 部署完成并尝试首次运行测试
# ------------------------------------------
echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}      部署全部完成！正在执行首次测试...     ${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}\n"

$PYTHON_BIN /etc/alidns/alidns-ipv6-ddns.py

echo -e "\n如需手动执行，可运行: ${YELLOW}${PYTHON_BIN} /etc/alidns/alidns-ipv6-ddns.py${PLAIN}"
echo -e "日志查看路径: ${YELLOW}/var/log/alidns-ipv6-ddns.log${PLAIN}"
if command -v systemctl &>/dev/null && systemctl is-active --quiet alidns-monitor.service 2>/dev/null; then
    echo -e "实时监听状态: ${GREEN}运行中 (可通过 journalctl -u alidns-monitor -f 查看实时变动)${PLAIN}"
fi