#!/bin/bash
# ==========================================
# SSH 配置交互式安装脚本 - 优化版
# 安装后可以直接运行 `ssh-config` 命令
# ==========================================

set -e

# 检查是否为root用户
[ "$(id -u)" -eq 0 ] || { echo "❌ 必须以root权限运行此安装脚本"; exit 1; }

SCRIPT_NAME="ssh-config"
INSTALL_DIR="/usr/local/bin"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"

# 检查安装目录是否存在，不存在则创建
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" || { echo "❌ 无法创建安装目录 $INSTALL_DIR"; exit 1; }
fi

# 检查是否可写
if [ ! -w "$INSTALL_DIR" ]; then
    echo "❌ 无权限写入 $INSTALL_DIR，请检查权限"
    exit 1
fi

# ---------- 写入可执行脚本 ----------
cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash
set -e

# 检查是否为root用户
[ "$(id -u)" -eq 0 ] || { echo "❌ 必须以root权限运行此脚本"; exit 1; }

CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_DIR="/etc/ssh/backups"
SSH_SERVICE_NAME=""
LOG_FILE="/var/log/ssh-config.log"

# 初始化日志
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date)] SSH 配置脚本开始执行"

# 检测SSH服务名称
if command -v systemctl &>/dev/null; then
    if systemctl list-unit-files 2>/dev/null | grep -q "sshd.service"; then
        SSH_SERVICE_NAME="sshd"
    elif systemctl list-unit-files 2>/dev/null | grep -q "ssh.service"; then
        SSH_SERVICE_NAME="ssh"
    fi
else
    # 检查传统的init系统
    if [ -f /etc/init.d/sshd ]; then
        SSH_SERVICE_NAME="sshd"
    elif [ -f /etc/init.d/ssh ]; then
        SSH_SERVICE_NAME="ssh"
    fi
fi

if [ -z "$SSH_SERVICE_NAME" ]; then
    echo "❌ 未找到SSH服务，请确认SSH服务器已安装"
    exit 1
fi

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 备份配置文件，使用时间戳
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/$(basename "$CONFIG_FILE").$TIMESTAMP.bak"

# 错误处理函数
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "❌ 脚本执行出错 (退出码: $exit_code)"
        echo "ℹ️  详细日志已保存至 $LOG_FILE"
        if [ -f "$BACKUP_FILE" ] && [ ! -f "${CONFIG_FILE}.broken" ]; then
            echo "🔄 尝试恢复原始配置文件..."
            cp -f "$BACKUP_FILE" "$CONFIG_FILE" >/dev/null 2>&1
            echo "✅ 配置已恢复到修改前状态"
        fi
    fi
}
trap cleanup EXIT

# 安全检查
check_prerequisites() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ SSH 配置文件 $CONFIG_FILE 不存在"
        exit 1
    fi
    
    # 检查sshd命令是否存在
    if ! command -v sshd &> /dev/null; then
        echo "❌ sshd 命令不存在，请确认SSH服务器已安装"
        exit 1
    fi
}

# 设置配置项
set_conf() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    # 如果配置项已存在（包含注释的），则替换
    if grep -qE "^[[:space:]]*#?[[:space:]]*$key[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*($key)[[:space:]]+.*|\1 $value|" "$file"
        echo "🔄 已更新配置: $key = $value"
    else
        echo "$key $value" >> "$file"
        echo "➕ 已添加新配置: $key = $value"
    fi
}

# 询问是/否问题
ask_yn() {
    local prompt="$1"
    local default="$2"
    local answer
    
    while true; do
        read -rp "$prompt [$default]: " answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "请输入 Y 或 N";;
        esac
    done
}

# 验证公钥格式
validate_public_key() {
    local key="$1"
    
    # 基本验证：检查是否包含 ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp256 等前缀
    if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-dss)[[:space:]]+[A-Za-z0-9+/]+[=]* ]]; then
        return 0
    else
        echo "⚠️  公钥格式可能不正确。标准格式应为: <type> <key> [comment]"
        if ask_yn "仍然使用此公钥吗？" "N"; then
            return 0
        else
            return 1
        fi
    fi
}

# 获取用户主目录
get_user_home() {
    local user="$1"
    local homedir
    
    if [ "$user" = "root" ]; then
        homedir="/root"
    else
        homedir=$(getent passwd "$user" | cut -d: -f6)
        if [ -z "$homedir" ] || [ ! -d "$homedir" ]; then
            echo "❌ 未找到用户 $user 的家目录"
            exit 1
        fi
    fi
    echo "$homedir"
}

# 主函数
main() {
    check_prerequisites
    
    echo -e "\n🔐 SSH 配置向导"
    echo "----------------------------------------"
    
    # 备份当前配置
    cp -f "$CONFIG_FILE" "$BACKUP_FILE"
    echo "✅ 已备份原始配置到: $BACKUP_FILE"
    
    # 询问配置选项
    local allow_root=0
    local disable_password=0
    
    echo -e "\n⚠️  安全提示：在禁用密码登录前，请确保您的公钥已正确配置，否则可能被锁定在服务器外！"
    
    if ask_yn "是否允许 root 登录？(建议: 生产环境选择 N)" "N"; then
        allow_root=1
    fi
    
    if ask_yn "是否禁用密码登录，仅使用密钥认证？(建议: Y，但请先确认密钥可用)" "Y"; then
        disable_password=1
    fi
    
    # 获取公钥
    local pubkey=""
    while true; do
        echo -e "\n🔑 请提供用于登录的 SSH 公钥"
        echo "  格式示例: ssh-rsa AAAAB3NzaC1yc2E... user@host"
        echo "  或提供 GitHub/GitLab 用户名 (例如: github:username)"
        
        read -rp "请输入公钥、URL 或平台:username 格式: " input
        
        # 处理特殊格式: platform:username
        if [[ "$input" =~ ^(github|gitlab):([a-zA-Z0-9_-]+)$ ]]; then
            platform="${BASH_REMATCH[1]}"
            username="${BASH_REMATCH[2]}"
            
            if [ "$platform" = "github" ]; then
                url="https://github.com/$username.keys"
            elif [ "$platform" = "gitlab" ]; then
                url="https://gitlab.com/$username.keys"
            fi
            
            echo "⬇️  从 $platform 下载公钥: $url"
            if pubkey=$(curl -sLf "$url" | head -1); then
                if [ -z "$pubkey" ]; then
                    echo "❌ 从 $platform 获取的公钥为空，请检查用户名是否正确"
                    continue
                fi
                echo "✅ 公钥下载成功"
            else
                echo "❌ 无法从 $platform 获取公钥，请检查用户名或网络连接"
                continue
            fi
        # 检查是否为URL
        elif [[ "$input" =~ ^https?:// ]]; then
            echo "⬇️  从URL下载公钥: $input"
            if pubkey=$(curl -sLf "$input" | head -1); then
                if [ -z "$pubkey" ]; then
                    echo "❌ 从URL获取的公钥为空"
                    continue
                fi
                echo "✅ 公钥下载成功"
            else
                echo "❌ 无法从URL获取公钥，请检查URL是否正确"
                continue
            fi
        else
            pubkey="$input"
        fi
        
        # 验证公钥
        if validate_public_key "$pubkey"; then
            break
        else
            echo "❌ 无效的公钥，请重新输入"
        fi
    done
    
    # 选择用户
    echo -e "\n👤 选择要配置SSH密钥的用户"
    echo "  1) root (默认)"
    echo "  2) 当前登录用户"
    echo "  3) 其他指定用户"
    
    local choice="1"
    read -rp "请选择 [1]: " choice
    choice="${choice:-1}"
    
    local target_user="root"
    case "$choice" in
        1) target_user="root";;
        2) 
            target_user="$SUDO_USER"
            if [ -z "$target_user" ] || ! id "$target_user" &> /dev/null; then
                echo "⚠️  无法确定当前登录用户，使用 root 作为默认用户"
                target_user="root"
            fi
            ;;
        3) 
            read -rp "请输入用户名: " target_user
            if ! id "$target_user" &> /dev/null; then
                echo "❌ 用户 $target_user 不存在"
                exit 1
            fi
            ;;
        *) 
            echo "❌ 无效选择，使用默认用户 root"
            target_user="root"
            ;;
    esac
    
    # 显示摘要
    echo -e "\n📋 配置摘要:"
    echo "  - 允许 root 登录: $( [ $allow_root -eq 1 ] && echo "是" || echo "否" )"
    echo "  - 禁用密码登录: $( [ $disable_password -eq 1 ] && echo "是" || echo "否" )"
    echo "  - 目标用户: $target_user"
    echo "  - 公钥: ${pubkey:0:32}..."
    
    if ! ask_yn "确认应用以上配置？" "Y"; then
        echo "❌ 用户取消操作"
        exit 1
    fi
    
    echo -e "\n⚙️  应用SSH配置..."
    
    # 更新SSH配置
    set_conf "PubkeyAuthentication" "yes" "$CONFIG_FILE"
    set_conf "AuthorizedKeysFile" ".ssh/authorized_keys" "$CONFIG_FILE"
    set_conf "PermitRootLogin" "$( [ $allow_root -eq 1 ] && echo "yes" || echo "no" )" "$CONFIG_FILE"
    set_conf "PasswordAuthentication" "$( [ $disable_password -eq 1 ] && echo "no" || echo "yes" )" "$CONFIG_FILE"
    
    # 设置authorized_keys
    local user_home=$(get_user_home "$target_user")
    local ssh_dir="$user_home/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    
    echo "🏠 目标用户家目录: $user_home"
    
    # 创建.ssh目录
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$target_user":"$(id -gn "$target_user")" "$ssh_dir"
    
    # 创建或更新authorized_keys
    if [ ! -f "$auth_keys" ]; then
        touch "$auth_keys"
    fi
    
    chmod 600 "$auth_keys"
    chown "$target_user":"$(id -gn "$target_user")" "$auth_keys"
    
    # 添加公钥（如果不存在）
    if ! grep -qF "$pubkey" "$auth_keys"; then
        echo "$pubkey" >> "$auth_keys"
        echo "✅ 已将公钥添加到 $auth_keys"
    else
        echo "ℹ️  公钥已存在于 $auth_keys"
    fi
    
    # 测试配置
    echo -e "\n🔍 测试SSH配置语法..."
    if sshd -t; then
        echo "✅ SSH配置语法正确"
    else
        echo "❌ SSH配置语法错误，恢复原始配置"
        cp -f "$BACKUP_FILE" "$CONFIG_FILE"
        exit 1
    fi
    
    # 重启SSH服务
    echo -e "\n🔄 重启SSH服务..."
    if command -v systemctl &> /dev/null; then
        systemctl restart "$SSH_SERVICE_NAME"
    else
        service "$SSH_SERVICE_NAME" restart
    fi
    
    # 验证服务状态
    sleep 2
    local service_status=0
    
    if command -v systemctl &> /dev/null; then
        if ! systemctl is-active --quiet "$SSH_SERVICE_NAME"; then
            service_status=1
        fi
    else
        if ! service "$SSH_SERVICE_NAME" status 2>&1 | grep -qE "(running|active)"; then
            service_status=1
        fi
    fi
    
    if [ $service_status -ne 0 ]; then
        echo "❌ SSH服务重启失败，恢复原始配置"
        cp -f "$BACKUP_FILE" "$CONFIG_FILE"
        if command -v systemctl &> /dev/null; then
            systemctl restart "$SSH_SERVICE_NAME"
        else
            service "$SSH_SERVICE_NAME" restart
        fi
        exit 1
    fi
    
    echo -e "\n✅ SSH配置成功完成！"
    echo "💡 重要提示: 请保持当前会话打开，使用新终端测试SSH连接，确认无误后再关闭当前会话"
    echo "💾 备份文件位置: $BACKUP_FILE"
    echo "📝 操作日志: $LOG_FILE"
    echo ""
    echo "配置详情:"
    echo "  - 用户: $target_user"
    echo "  - 密钥登录: 启用"
    echo "  - 密码登录: $( [ $disable_password -eq 1 ] && echo "禁用" || echo "启用" )"
    echo "  - root登录: $( [ $allow_root -eq 1 ] && echo "允许" || echo "禁止" )"
    echo ""
    echo "🔐 安全提示: 请妥善保管您的私钥，不要分享给他人"
}

main
EOF

# 设置脚本权限
chmod 755 "$SCRIPT_PATH"

echo "🎉 安装完成！现在可以运行命令：$SCRIPT_NAME"
echo "ℹ️  重要提示：在运行 $SCRIPT_NAME 前，确保您有其他方式访问服务器（如控制台），以防SSH配置错误导致无法连接"