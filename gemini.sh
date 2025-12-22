#!/bin/bash

# ==========================================
# 1. 全局配置
# ==========================================

API_KEY="key"
if [ ! -z "$1" ]; then
    API_KEY="$1"
fi

USE_PROXY=false
PROXY_HOST="127.0.0.1"
PROXY_PORT=7890

MODEL="gemini-3-flash-preview" # 或者是 gemini-1.5-flash / gemini-1.5-pro
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}"

# 【修改点 1】将历史文件指向 /tmp 下的固定文件
HISTORY_FILE="/tmp/gemini_chat_history.json"
RESPONSE_FILE=$(mktemp /tmp/gemini_response.XXXXXX)

# 【修改点 2】只有当文件不存在时才初始化，否则保留原有记录
if [ ! -f "$HISTORY_FILE" ]; then
    echo '[]' > "$HISTORY_FILE"
fi

# 颜色定义
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
GRAY='\033[0;90m'
YELLOW='\033[0;33m'
NC='\033[0m' 

# ==========================================
# 2. 核心逻辑
# ==========================================

cleanup() {
    # 【修改点 3】只删除临时的响应缓存文件，保留 HISTORY_FILE
    rm -f "$RESPONSE_FILE"
    printf "\n${GRAY}[System] Session ended. History saved in ${HISTORY_FILE}${NC}\n"
    exit
}
trap cleanup SIGINT SIGTERM

add_to_history() {
    local role=$1
    local text=$2
    # 使用 jq 追加内容
    jq -n --slurpfile history "$HISTORY_FILE" --arg r "$role" --arg t "$text" \
        '$history[0] + [{"role": $r, "parts": [{"text": $t}]}]' > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

call_gemini() {
    printf "${GRAY}Gemini is thinking...${NC}\r"

    local payload_file=$(mktemp)
    jq -n --slurpfile history "$HISTORY_FILE" '{"contents": $history[0]}' > "$payload_file"
    
    local proxy_opts=""
    if [ "$USE_PROXY" = true ]; then
        proxy_opts="-x http://$PROXY_HOST:$PROXY_PORT"
    fi

    curl -s -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -d @"$payload_file" \
        $proxy_opts \
        -o "$RESPONSE_FILE"

    rm -f "$payload_file"

    local error_msg=$(jq -r '.error.message // empty' "$RESPONSE_FILE")
    if [ ! -z "$error_msg" ]; then
        printf "${RED}API Error: %s${NC}\n" "$error_msg"
        return
    fi

    # 提取回复内容
    local model_text=$(jq -j '.candidates[0].content.parts[] | select(.text) | .text' "$RESPONSE_FILE" 2>/dev/null)
    local thinking=$(jq -j '.candidates[0].content.parts[] | select(.thought) | .thought' "$RESPONSE_FILE" 2>/dev/null)
    
    # 清除 "Thinking..." 提示
    printf "\r\033[K" 

    if [ ! -z "$thinking" ]; then
        printf "${YELLOW}Thought:${NC}\n${GRAY}%s${NC}\n\n" "$thinking"
    fi

    if [ ! -z "$model_text" ]; then
        printf "${GREEN}Gemini:${NC} %s\n\n" "$model_text"
        add_to_history "model" "$model_text"
    else
        # 有时候可能因为只有 thought 没有 text，或者解析失败
        if [ -z "$thinking" ]; then
            printf "${RED}[Error] Could not parse response.${NC}\n"
            head -c 100 "$RESPONSE_FILE"
        fi
    fi
}

# ==========================================
# 3. 主界面
# ==========================================

printf "${GREEN}=== Gemini Terminal (Persistent History in /tmp) ===${NC}\n"
printf "${GRAY}Commands: /clear, /upload <path>, /exit${NC}\n"

# 显示当前已加载的历史记录条数
MSG_COUNT=$(jq 'length' "$HISTORY_FILE" 2>/dev/null)
if [ "$MSG_COUNT" -gt 0 ]; then
    printf "${YELLOW}[System] Loaded $MSG_COUNT messages from history.${NC}\n"
fi
printf "\n"

while true; do
    printf "${BLUE}You: ${NC}"
    read -r USER_INPUT

    if [ -z "$USER_INPUT" ]; then continue; fi
    if [[ "$USER_INPUT" == "/exit" ]]; then break; fi
    
    # 清空指令：重置文件为 []
    if [[ "$USER_INPUT" == "/clear" ]]; then
        echo '[]' > "$HISTORY_FILE"
        printf "${GRAY}[System] History cleared.${NC}\n"
        continue
    fi

    # 文件上传逻辑
    if [[ "$USER_INPUT" == /upload* ]]; then
        FILE_PATH=$(echo "$USER_INPUT" | cut -d' ' -f2-)
        if [ -f "$FILE_PATH" ]; then
            FILE_CONTENT=$(cat "$FILE_PATH")
            # 添加到上下文但不立即发送，或者添加并触发总结，这里选择直接发送
            add_to_history "user" "File: $(basename $FILE_PATH)\nContent:\n$FILE_CONTENT"
            call_gemini
        else
            printf "${RED}File not found: %s${NC}\n" "$FILE_PATH"
        fi
        continue
    fi

    add_to_history "user" "$USER_INPUT"
    call_gemini
done

cleanup
