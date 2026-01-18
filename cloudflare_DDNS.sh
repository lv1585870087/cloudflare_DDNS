#!/bin/bash

# ================= 配置区域 =================
# 核心参数：请手动填写
API_TOKEN=""
ROOT_DOMAIN=""      # 根域名
SUB_DOMAIN="" # 完整的解析记录域名
SLEEP_TIME=60                 # 检查频率（秒）

IP_HISTORY_FILE="./ip_history.log" 
LOG_FILE="./cf_ddns.log"
# ===========================================

FAIL_COUNT=0
MAX_FAIL_LOG=1000
MAX_LOG_LINES=5000

# 日志截断函数：保持日志文件在指定行数内
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
    # 写入文件
    echo "[$timestamp] $msg" >> "$LOG_FILE"
    # 自动维护文件大小
    rotate_log "$LOG_FILE"
}

# 提取 ID 的函数 (非贪婪)
extract_id() {
    echo "$1" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    ip=$(curl -sL --connect-timeout 8 -m 15 http://myip.ipip.net | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -n 1)
    [ -z "$ip" ] && ip=$(curl -sL --connect-timeout 8 -m 15 http://api.ipify.org)
    echo "$ip"
}

echo "------------------------------------------------"
echo "   Cloudflare DDNS 自动监控系统 启动中..."
echo "------------------------------------------------"
write_log "系统启动 - 监控域名: $SUB_DOMAIN"

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
    write_log "错误: 无法获取 ZONE_ID，回执: $ZONE_RESPONSE"
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
    write_log "错误: 无法获取 RECORD_ID，回执: $RECORD_RESPONSE"
    exit 1
fi

echo "[状态] 进入持续监测模式 (频率: ${SLEEP_TIME}s)"
write_log "初始化成功，开始循环监测。"

# 3. 循环监测
while true; do
    T_STAMP=$(date '+%H:%M:%S')
    
    # 屏幕打印
    printf "[%s] 1.探测 IP: " "$T_STAMP"
    CURRENT_IP=$(get_public_ip)
    
    if [ -n "$CURRENT_IP" ]; then
        printf "%-15s | " "$CURRENT_IP"
        
        # 获取历史记录中最后一个 IP
        if [ -f "$IP_HISTORY_FILE" ]; then
            # 这里的 awk 解析根据新格式做了调整，取最后一个字段
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
                # 记录到历史记录文件 (时间 : 域名 ---> IP)
                echo "$(date '+%Y-%m-%d %H:%M:%S') : $SUB_DOMAIN ---> $CURRENT_IP" >> "$IP_HISTORY_FILE"
                write_log "同步成功: $SUB_DOMAIN 已指向 $CURRENT_IP"
                FAIL_COUNT=0
            else
                echo "失败"
                ((FAIL_COUNT++))
                if [ "$FAIL_COUNT" -le "$MAX_FAIL_LOG" ]; then
                    write_log "同步失败 ($FAIL_COUNT/1000): $UPDATE_RESULT"
                fi
            fi
        else
            echo "IP 未变，跳过。"
            # 可选：如果你想每一轮检查都记日志，可以取消下面这一行的注释
            # write_log "检查完成: IP 无变动 ($CURRENT_IP)"
        fi
    else
        echo "获取失败"
        ((FAIL_COUNT++))
        [ "$FAIL_COUNT" -le "$MAX_FAIL_LOG" ] && write_log "错误: 无法探测公网 IP ($FAIL_COUNT/1000)"
    fi

    # 屏幕等待提示
    printf "[%s] 等待下一轮轮询... \n" "$(date '+%H:%M:%S')"
    sleep "$SLEEP_TIME"
done