#!/bin/bash

# ============================================================
#  TUIC v5 一键安装脚本
#  https://github.com/ccj241/tuic
#
#  支持系统: Ubuntu / Debian / CentOS (x86_64 / aarch64)
#  用法:
#    交互式安装:     bash tuic-installer.sh
#    无人值守安装:   bash tuic-installer.sh --auto
#    安装后管理:     tuic
# ============================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/root/tuic"
SERVICE_FILE="/etc/systemd/system/tuic.service"
CONFIG_FILE="$INSTALL_DIR/config.json"
TUIC_CMD="/usr/local/bin/tuic"

# -------------------- 工具函数 --------------------

info()    { echo -e "${GREEN}[信息]${NC} $1"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
error()   { echo -e "${RED}[错误]${NC} $1"; exit 1; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行此脚本，或使用: sudo bash $0"
    fi
}

# -------------------- 快捷命令 --------------------

install_command() {
    cat > "$TUIC_CMD" <<'CMDEOF'
#!/bin/bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccj241/tuic/main/tuic-installer.sh) "$@"
CMDEOF
    chmod 755 "$TUIC_CMD"
}

remove_command() {
    rm -f "$TUIC_CMD"
}

# -------------------- 依赖安装 --------------------

install_dependencies() {
    info "正在安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl jq openssl uuid-runtime >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl jq openssl util-linux >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl jq openssl util-linux >/dev/null 2>&1
    else
        error "不支持的包管理器，请手动安装: curl jq openssl uuid-runtime"
    fi
    info "依赖安装完成"
}

# -------------------- 架构检测 --------------------

detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  echo "x86_64-unknown-linux-gnu" ;;
        i686)    echo "i686-unknown-linux-gnu" ;;
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
        armv7l)  echo "armv7-unknown-linux-gnueabi" ;;
        *)       error "不支持的系统架构: $arch" ;;
    esac
}

# -------------------- 下载 --------------------

download_tuic() {
    local server_arch="$1"

    info "正在获取最新版本..."
    local latest=""

    # 优先从自己的镜像仓库获取
    latest=$(curl -sL "https://api.github.com/repos/ccj241/tuic/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null) || true

    # 备用: 上游仓库
    if [ -z "$latest" ]; then
        latest=$(curl -sL "https://api.github.com/repos/EAimTY/tuic/releases" \
            | jq -r '[.[] | select(.tag_name | startswith("tuic-server"))][0].tag_name // empty' 2>/dev/null) || true
    fi

    # 兜底: 硬编码版本
    if [ -z "$latest" ]; then
        warn "无法从 API 获取版本号，使用默认版本"
        latest="tuic-server-1.0.0"
    fi
    info "最新版本: $latest"

    info "正在下载 tuic-server..."
    mkdir -p "$INSTALL_DIR"

    # 按优先级尝试多个下载源
    local downloaded=false
    local urls=(
        "https://github.com/ccj241/tuic/releases/download/$latest/$latest-$server_arch"
        "https://github.com/EAimTY/tuic/releases/download/$latest/$latest-$server_arch"
        "https://github.com/tuic-protocol/tuic/releases/download/$latest/$latest-$server_arch"
    )

    for url in "${urls[@]}"; do
        if curl -sL -o "$INSTALL_DIR/tuic-server" --fail "$url" 2>/dev/null; then
            downloaded=true
            break
        fi
    done

    if [ "$downloaded" = false ]; then
        error "下载 tuic-server 失败，已尝试所有下载源"
    fi
    chmod 755 "$INSTALL_DIR/tuic-server"
    info "下载完成"
}

# -------------------- 证书生成 --------------------

generate_certs() {
    info "正在生成自签名证书..."
    openssl ecparam -genkey -name prime256v1 -out "$INSTALL_DIR/ca.key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$INSTALL_DIR/ca.key" \
        -out "$INSTALL_DIR/ca.crt" -subj "/CN=bing.com" 2>/dev/null
    info "证书生成完成"
}

# -------------------- 配置文件 --------------------

generate_config() {
    local port="$1"
    local password="$2"
    local uuid="$3"

    cat > "$CONFIG_FILE" <<EOF
{
  "server": "[::]:$port",
  "users": {
    "$uuid": "$password"
  },
  "certificate": "$INSTALL_DIR/ca.crt",
  "private_key": "$INSTALL_DIR/ca.key",
  "congestion_control": "bbr",
  "alpn": ["h3", "spdy/3.1"],
  "udp_relay_ipv6": true,
  "zero_rtt_handshake": false,
  "dual_stack": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "10s",
  "max_external_packet_size": 1500,
  "gc_interval": "3s",
  "gc_lifetime": "15s",
  "log_level": "warn"
}
EOF
    info "配置已保存到 $CONFIG_FILE"
}

# -------------------- 系统服务 --------------------

setup_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=TUIC v5 Server
Documentation=https://github.com/ccj241/tuic
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$INSTALL_DIR/tuic-server -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tuic >/dev/null 2>&1
    systemctl start tuic
    info "系统服务已创建并启动"
}

# -------------------- 显示连接信息 --------------------

show_result() {
    local port="$1"
    local password="$2"
    local uuid="$3"

    local public_ip
    public_ip=$(curl -sL --connect-timeout 5 https://api.ipify.org 2>/dev/null) || \
    public_ip=$(curl -sL --connect-timeout 5 https://ifconfig.me 2>/dev/null) || \
    public_ip="<你的服务器IP>"

    sleep 2
    if systemctl is-active --quiet tuic; then
        echo ""
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}    TUIC v5 安装完成!                 ${NC}"
        echo -e "${GREEN}======================================${NC}"
        echo -e "  服务器:   ${CYAN}$public_ip${NC}"
        echo -e "  端口:     ${CYAN}$port${NC}"
        echo -e "  UUID:     ${CYAN}$uuid${NC}"
        echo -e "  密码:     ${CYAN}$password${NC}"
        echo -e "  拥塞控制: ${CYAN}bbr${NC}"
        echo -e "  ALPN:     ${CYAN}h3,spdy/3.1${NC}"
        echo -e "${GREEN}======================================${NC}"
        echo ""
        echo -e "${YELLOW}客户端导入链接 (NekoBox / v2rayN / Clash Meta):${NC}"
        echo -e "${CYAN}tuic://$uuid:$password@$public_ip:$port/?congestion_control=bbr&alpn=h3,spdy/3.1&udp_relay_mode=native&allow_insecure=1${NC}"
        echo ""
        echo -e "${GREEN}提示: 下次管理 TUIC 只需输入 ${CYAN}tuic${GREEN} 即可${NC}"
        echo ""
    else
        warn "TUIC 服务未能启动，请检查: systemctl status tuic"
    fi
}

# -------------------- 卸载 --------------------

uninstall_tuic() {
    warn "正在卸载 TUIC..."
    systemctl stop tuic 2>/dev/null || true
    systemctl disable tuic 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f "$SERVICE_FILE"
    remove_command
    systemctl daemon-reload
    info "TUIC 已完全卸载"
}

# -------------------- 修改配置 --------------------

modify_tuic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "未找到配置文件，TUIC 可能未安装"
    fi

    local current_port
    current_port=$(jq -r '.server' "$CONFIG_FILE" | sed 's/\[::\]://')

    local current_uuid
    current_uuid=$(jq -r '.users | keys[0]' "$CONFIG_FILE")
    local current_password
    current_password=$(jq -r ".users.\"$current_uuid\"" "$CONFIG_FILE")

    echo ""
    read -rp "新端口 (当前: $current_port, 回车保持不变): " new_port
    [ -z "$new_port" ] && new_port="$current_port"

    read -rp "新密码 (当前: $current_password, 回车保持不变): " new_password
    [ -z "$new_password" ] && new_password="$current_password"

    jq ".server = \"[::]:$new_port\"" "$CONFIG_FILE" > /tmp/tuic_tmp.json && mv /tmp/tuic_tmp.json "$CONFIG_FILE"
    jq ".users = {\"$current_uuid\": \"$new_password\"}" "$CONFIG_FILE" > /tmp/tuic_tmp.json && mv /tmp/tuic_tmp.json "$CONFIG_FILE"

    systemctl restart tuic
    show_result "$new_port" "$new_password" "$current_uuid"
}

# -------------------- 查看状态 --------------------

show_status() {
    echo ""
    if systemctl is-active --quiet tuic; then
        echo -e "  服务状态: ${GREEN}运行中${NC}"
    else
        echo -e "  服务状态: ${RED}已停止${NC}"
    fi
    echo ""
    systemctl status tuic --no-pager 2>/dev/null || true
    echo ""
}

# -------------------- 主函数 --------------------

main() {
    check_root

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    TUIC v5 一键安装管理脚本          ║${NC}"
    echo -e "${CYAN}║    github.com/ccj241                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    # 已安装则显示管理菜单
    if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/tuic-server" ]; then
        echo -e "${GREEN}TUIC 已安装，请选择操作:${NC}"
        echo ""
        echo "  1) 重新安装"
        echo "  2) 修改配置 (端口/密码)"
        echo "  3) 卸载"
        echo "  4) 查看连接信息"
        echo "  5) 查看运行状态"
        echo "  6) 重启服务"
        echo "  0) 退出"
        echo ""
        read -rp "请输入选项 [0-6]: " choice
        case $choice in
            1) uninstall_tuic ;;
            2) modify_tuic; exit 0 ;;
            3) uninstall_tuic; exit 0 ;;
            4)
                local port uuid password
                port=$(jq -r '.server' "$CONFIG_FILE" | sed 's/\[::\]://')
                uuid=$(jq -r '.users | keys[0]' "$CONFIG_FILE")
                password=$(jq -r ".users.\"$uuid\"" "$CONFIG_FILE")
                show_result "$port" "$password" "$uuid"
                exit 0
                ;;
            5) show_status; exit 0 ;;
            6)
                systemctl restart tuic
                info "TUIC 服务已重启"
                exit 0
                ;;
            0) exit 0 ;;
            *)
                warn "无效选项"
                exit 1
                ;;
        esac
    fi

    # 全新安装
    local auto_mode=false
    if [ "$1" = "--auto" ] || [ "$1" = "-a" ]; then
        auto_mode=true
    fi

    install_dependencies

    local server_arch
    server_arch=$(detect_arch)
    info "检测到系统架构: $server_arch"

    download_tuic "$server_arch"
    generate_certs

    # 端口和密码
    local port password uuid

    if [ "$auto_mode" = true ]; then
        port=$((RANDOM % 55001 + 10000))
        password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 12 | head -n 1)
    else
        echo ""
        read -rp "请输入端口号 (回车随机生成): " port
        [ -z "$port" ] && port=$((RANDOM % 55001 + 10000))
        read -rp "请输入密码 (回车随机生成): " password
        [ -z "$password" ] && password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 12 | head -n 1)
    fi

    uuid=$(uuidgen)
    if [ -z "$uuid" ]; then
        error "UUID 生成失败"
    fi

    generate_config "$port" "$password" "$uuid"
    setup_service
    install_command
    show_result "$port" "$password" "$uuid"
}

main "$@"
