
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

MODEL="gemini-3-flash-preview"
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}"

HISTORY_FILE=$(mktemp)
RESPONSE_FILE=$(mktemp)
echo '[]' > "$HISTORY_FILE"

# 颜色定义 (printf 使用 \033 效果很好)
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
    rm -f "$HISTORY_FILE" "$RESPONSE_FILE"
    printf "\n${GRAY}[System] Session ended.${NC}\n"
    exit
}
trap cleanup SIGINT SIGTERM

add_to_history() {
    local role=$1
    local text=$2
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

    local model_text=$(jq -j '.candidates[0].content.parts[] | select(.text) | .text' "$RESPONSE_FILE" 2>/dev/null)
    local thinking=$(jq -j '.candidates[0].content.parts[] | select(.thought) | .thought' "$RESPONSE_FILE" 2>/dev/null)
    
    # 先清除 "Thinking..." 那一行
    printf "\r\033[K" 

    if [ ! -z "$thinking" ]; then
        printf "${YELLOW}Thought:${NC}\n${GRAY}%s${NC}\n\n" "$thinking"
    fi

    if [ ! -z "$model_text" ]; then
        printf "${GREEN}Gemini:${NC} %s\n\n" "$model_text"
        add_to_history "model" "$model_text"
    else
        printf "${RED}[Error] Could not parse response.${NC}\n"
        head -c 100 "$RESPONSE_FILE"
    fi
}

# ==========================================
# 3. 主界面
# ==========================================

printf "${GREEN}=== Gemini 2.0 Terminal (Fixed for macOS) ===${NC}\n"
printf "${GRAY}Commands: /clear, /upload <path>, /exit${NC}\n\n"

while true; do
    printf "${BLUE}You: ${NC}"
    read -r USER_INPUT

    if [ -z "$USER_INPUT" ]; then continue; fi
    if [[ "$USER_INPUT" == "/exit" ]]; then break; fi
    if [[ "$USER_INPUT" == "/clear" ]]; then
        echo '[]' > "$HISTORY_FILE"
        printf "${GRAY}[System] Cleared.${NC}\n"
        continue
    fi

    if [[ "$USER_INPUT" == /upload* ]]; then
        FILE_PATH=$(echo "$USER_INPUT" | cut -d' ' -f2-)
        if [ -f "$FILE_PATH" ]; then
            FILE_CONTENT=$(cat "$FILE_PATH")
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
