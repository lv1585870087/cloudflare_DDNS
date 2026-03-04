#!/bin/bash

# ================= 配置区域 =================
# 核心参数：请手动填写
API_TOKEN=""
ROOT_DOMAIN=""      # 根域名
SUB_DOMAIN=""   # 完整的解析记录域名
SLEEP_TIME=60               # 检查频率（秒）
WAN_INTERFACE="pppoe-wan"   # PPPoE 接口名称

IP_HISTORY_FILE="/root/DDNS/ip_history.log" 
LOG_FILE="/root/DDNS/cf_ddns.log"
# ===========================================

FAIL_COUNT=0
MAX_FAIL_LOG=1000
MAX_LOG_LINES=5000

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

# 日志截断函数
rotate_log() {
    local file=$1
    if [ -f "$file" ]; then
        local lines=$(wc -l < "$file")
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            local temp=$(tail -n "$MAX_LOG_LINES" "$file")
            echo "$temp" > "$file"
        fi
    fi
}

# 统一日志记录函数
write_log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" >> "$LOG_FILE"
    rotate_log "$LOG_FILE"
}

# 提取 ID 的函数
extract_id() {
    echo "$1" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4
}

# --- 修改部分：获取本地 PPPoE IP ---
get_public_ip() {
    local ip=""
    # 尝试使用 ifconfig 获取 pppoe-wan 的 inet 地址
    # 兼容 "inet addr:1.2.3.4" 和 "inet 1.2.3.4" 两种常见格式
    ip=$(ifconfig $WAN_INTERFACE 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d: -f2)
    
    # 如果 ifconfig 没拿到，尝试使用 ip addr (现代 Linux 标准)
    if [ -z "$ip" ]; then
        ip=$(ip addr show $WAN_INTERFACE 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    fi
    
    echo "$ip"
}
# -------------------------------

echo "------------------------------------------------"
echo "   Cloudflare DDNS 自动监控系统 (本地模式) 启动中..."
echo "------------------------------------------------"
write_log "系统启动 - 监控接口: $WAN_INTERFACE -> $SUB_DOMAIN"

# 1. 获取 ID 阶段
printf "[初始化] 正在获取 ZONE_ID... "
ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json")
ZONE_ID=$(extract_id "$ZONE_RESPONSE")

if [ -n "$ZONE_ID" ]; then
    echo "成功: $ZONE_ID"
else
    echo "失败"
    write_log "错误: 无法获取 ZONE_ID，请检查 API_TOKEN 或域名配置"
    exit 1
fi

printf "[初始化] 正在获取 RECORD_ID... "
RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$SUB_DOMAIN" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json")
DNS_RECORD_ID=$(extract_id "$RECORD_RESPONSE")

if [ -n "$DNS_RECORD_ID" ]; then
    echo "成功: $DNS_RECORD_ID"
else
    echo "失败"
    write_log "错误: 无法获取 RECORD_ID，请确保 Cloudflare 上已手动创建该 A 记录"
    exit 1
fi

echo "[状态] 进入持续监测模式 (频率: ${SLEEP_TIME}s)"

# 3. 循环监测
while true; do
    T_STAMP=$(date '+%H:%M:%S')
    
    printf "[%s] 1.探测本地 IP: " "$T_STAMP"
    CURRENT_IP=$(get_public_ip)
    
    if [ -n "$CURRENT_IP" ]; then
        printf "%-15s | " "$CURRENT_IP"
        
        # 获取历史记录中最后一个 IP
        if [ -f "$IP_HISTORY_FILE" ]; then
            LAST_IP=$(tail -n 1 "$IP_HISTORY_FILE" | awk -F '---> ' '{print $2}' | tr -d ' ')
        else
            LAST_IP="First_Run"
        fi

        if [ "$CURRENT_IP" != "$LAST_IP" ]; then
            echo "检测到变更 ($LAST_IP)"
            write_log "检测到 IP 变动: $LAST_IP -> $CURRENT_IP"
            
            printf "[%s] 2.同步 Cloudflare... " "$T_STAMP"
            UPDATE_RESULT=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"A\",\"name\":\"$SUB_DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")

            if echo "$UPDATE_RESULT" | grep -q '"success":true'; then
                echo "成功"
                echo "$(date '+%Y-%m-%d %H:%M:%S') : $SUB_DOMAIN ---> $CURRENT_IP" >> "$IP_HISTORY_FILE"
                write_log "同步成功: $SUB_DOMAIN 已指向 $CURRENT_IP"
                FAIL_COUNT=0
            else
                echo "失败"
                ((FAIL_COUNT++))
                [ "$FAIL_COUNT" -le "$MAX_FAIL_LOG" ] && write_log "同步失败: $UPDATE_RESULT"
            fi
        else
            echo "IP 未变，跳过。"
        fi
    else
        echo "获取失败 (请检查拨号状态)"
        ((FAIL_COUNT++))
        [ "$FAIL_COUNT" -le "$MAX_FAIL_LOG" ] && write_log "错误: 无法从接口 $WAN_INTERFACE 提取 IP"
    fi

    sleep "$SLEEP_TIME"
done