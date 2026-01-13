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

# 解析公钥输入：支持 github:xxx / gitlab:xxx / URL / 直接公钥
resolve_pubkey() {
    local input="$1"
    local pubkey=""

    # 处理特殊格式: platform:username
    if [[ "$input" =~ ^(github|gitlab):([a-zA-Z0-9_-]+)$ ]]; then
        local platform="${BASH_REMATCH[1]}"
        local username="${BASH_REMATCH[2]}"
        local url=""

        if [ "$platform" = "github" ]; then
            url="https://github.com/$username.keys"
        else
            url="https://gitlab.com/$username.keys"
        fi

        echo "⬇️  从 $platform 下载公钥: $url"
        if pubkey=$(curl -sLf "$url" | head -1); then
            if [ -z "$pubkey" ]; then
                echo "❌ 从 $platform 获取的公钥为空，请检查用户名是否正确"
                return 1
            fi
            echo "✅ 公钥下载成功"
        else
            echo "❌ 无法从 $platform 获取公钥，请检查用户名或网络连接"
            return 1
        fi
    # 检查是否为URL
    elif [[ "$input" =~ ^https?:// ]]; then
        echo "⬇️  从URL下载公钥: $input"
        if pubkey=$(curl -sLf "$input" | head -1); then
            if [ -z "$pubkey" ]; then
                echo "❌ 从URL获取的公钥为空"
                return 1
            fi
            echo "✅ 公钥下载成功"
        else
            echo "❌ 无法从URL获取公钥，请检查URL是否正确"
            return 1
        fi
    else
        pubkey="$input"
    fi

    echo "$pubkey"
}

# 从文件读取第一行非空内容作为公钥
read_pubkey_from_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "❌ 公钥文件不存在: $file" >&2
        return 1
    fi
    local line
    line="$(grep -m 1 -E '^[[:space:]]*[^[:space:]].*$' "$file" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    if [ -z "$line" ]; then
        echo "❌ 公钥文件为空或无有效内容: $file" >&2
        return 1
    fi
    echo "$line"
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

# 解析目标用户（root/current/用户名）
resolve_target_user() {
    local raw="$1"
    local u=""
    case "$raw" in
        root) u="root" ;;
        current)
            u="$SUDO_USER"
            if [ -z "$u" ] || ! id "$u" &> /dev/null; then
                echo "⚠️  无法确定 sudo 前的用户，改用 root"
                u="root"
            fi
            ;;
        *)
            u="$raw"
            if [ -z "$u" ] || ! id "$u" &> /dev/null; then
                echo "❌ 用户 $u 不存在"
                exit 1
            fi
            ;;
    esac
    echo "$u"
}

# 交互式选择目标用户
choose_target_user_interactive() {
    echo -e "\n👤 选择要配置SSH密钥的用户"
    echo "  1) root (默认)"
    echo "  2) 当前登录用户"
    echo "  3) 其他指定用户"

    local choice="1"
    read -rp "请选择 [1]: " choice
    choice="${choice:-1}"

    local target_user="root"
    case "$choice" in
        1) target_user="root" ;;
        2) target_user="$(resolve_target_user current)" ;;
        3)
            read -rp "请输入用户名: " target_user
            target_user="$(resolve_target_user "$target_user")"
            ;;
        *)
            echo "❌ 无效选择，使用默认用户 root"
            target_user="root"
            ;;
    esac
    echo "$target_user"
}

# 菜单显示：将当前选择状态打印出来
show_menu() {
    local root_state="保持不变"
    local pass_state="保持不变"
    local key_state="不添加"

    if [ $DO_ROOT_CHANGE -eq 1 ]; then
        root_state="将设置为 $PERMIT_ROOT_VALUE"
    fi
    if [ $DO_PASS_CHANGE -eq 1 ]; then
        pass_state="将设置为 $PASSWORD_AUTH_VALUE"
    fi
    if [ $DO_ADD_PUBKEY -eq 1 ]; then
        key_state="将添加到 $TARGET_USER；${PUBKEY:0:32}..."
    fi

    echo -e "\n🧭 请选择要操作的功能（可反复选择，最后再应用）"
    echo "----------------------------------------"
    echo "当前选择："
    echo "  - root 登录策略: $root_state"
    echo "  - 密码登录策略: $pass_state"
    echo "  - 添加公钥: $key_state"
    echo ""
    echo "1) root 登录设置 (PermitRootLogin)"
    echo "2) 密码登录设置 (PasswordAuthentication)"
    echo "3) 添加公钥 (authorized_keys)"
    echo "4) 应用以上选择并重启SSH(如需要)"
    echo "5) 清空所有选择(不修改任何项)"
    echo "0) 退出"
}

# 应用选择的配置
apply_selected_changes() {
    if [ $DO_ROOT_CHANGE -eq 0 ] && [ $DO_PASS_CHANGE -eq 0 ] && [ $DO_ADD_PUBKEY -eq 0 ]; then
        echo "ℹ️  未选择任何修改，直接退出"
        exit 0
    fi

    echo -e "\n📋 即将应用的配置："
    if [ $DO_ROOT_CHANGE -eq 1 ]; then
        echo "  - PermitRootLogin = $PERMIT_ROOT_VALUE"
    fi
    if [ $DO_PASS_CHANGE -eq 1 ]; then
        echo "  - PasswordAuthentication = $PASSWORD_AUTH_VALUE"
    fi
    if [ $DO_ADD_PUBKEY -eq 1 ]; then
        echo "  - 添加公钥到用户: $TARGET_USER"
        echo "  - 公钥: ${PUBKEY:0:32}..."
    fi

    if ! ask_yn "确认应用以上配置？" "Y"; then
        echo "❌ 用户取消操作"
        exit 1
    fi

    echo -e "\n⚙️  应用SSH配置..."

    # 备份当前配置
    cp -f "$CONFIG_FILE" "$BACKUP_FILE"
    echo "✅ 已备份原始配置到: $BACKUP_FILE"

    local changed_config=0

    # 更新SSH配置（按需）
    if [ $DO_ADD_PUBKEY -eq 1 ]; then
        # 添加公钥通常也需要确保密钥认证开启
        set_conf "PubkeyAuthentication" "yes" "$CONFIG_FILE"
        set_conf "AuthorizedKeysFile" ".ssh/authorized_keys" "$CONFIG_FILE"
        changed_config=1
    fi

    if [ $DO_ROOT_CHANGE -eq 1 ]; then
        set_conf "PermitRootLogin" "$PERMIT_ROOT_VALUE" "$CONFIG_FILE"
        changed_config=1
    fi

    if [ $DO_PASS_CHANGE -eq 1 ]; then
        set_conf "PasswordAuthentication" "$PASSWORD_AUTH_VALUE" "$CONFIG_FILE"
        changed_config=1
    fi

    # 设置authorized_keys
    if [ $DO_ADD_PUBKEY -eq 1 ]; then
        local user_home
        user_home=$(get_user_home "$TARGET_USER")
        local ssh_dir="$user_home/.ssh"
        local auth_keys="$ssh_dir/authorized_keys"

        echo "🏠 目标用户家目录: $user_home"

        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$ssh_dir"

        if [ ! -f "$auth_keys" ]; then
            touch "$auth_keys"
        fi

        chmod 600 "$auth_keys"
        chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$auth_keys"

        if ! grep -qF "$PUBKEY" "$auth_keys"; then
            echo "$PUBKEY" >> "$auth_keys"
            echo "✅ 已将公钥添加到 $auth_keys"
        else
            echo "ℹ️  公钥已存在于 $auth_keys"
        fi
    fi

    if [ $changed_config -eq 1 ]; then
        echo -e "\n🔍 测试SSH配置语法..."
        if sshd -t; then
            echo "✅ SSH配置语法正确"
        else
            echo "❌ SSH配置语法错误，恢复原始配置"
            cp -f "$BACKUP_FILE" "$CONFIG_FILE"
            exit 1
        fi

        echo -e "\n🔄 重启SSH服务..."
        if command -v systemctl &> /dev/null; then
            systemctl restart "$SSH_SERVICE_NAME"
        else
            service "$SSH_SERVICE_NAME" restart
        fi

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
    fi

    echo -e "\n✅ SSH配置成功完成！"
    echo "💡 重要提示: 请保持当前会话打开，使用新终端测试SSH连接，确认无误后再关闭当前会话"
    echo "💾 备份文件位置: $BACKUP_FILE"
    echo "📝 操作日志: $LOG_FILE"
}

# 主函数
main() {
    check_prerequisites
    
    # 全局状态（菜单选择会修改这些）
    DO_ROOT_CHANGE=0
    DO_PASS_CHANGE=0
    DO_ADD_PUBKEY=0
    PERMIT_ROOT_VALUE=""
    PASSWORD_AUTH_VALUE=""
    PUBKEY=""
    TARGET_USER=""

    echo -e "\n⚠️  安全提示：在禁用密码登录前，请确保您的公钥已正确配置，否则可能被锁定在服务器外！"

    while true; do
        show_menu
        read -rp "请输入选项 [0-5]: " opt
        opt="${opt:-0}"
        case "$opt" in
            1)
                echo -e "\n1) root 登录设置 (PermitRootLogin)"
                echo "  1) 允许 root 登录 (yes)"
                echo "  2) 禁止 root 登录 (no)"
                echo "  3) 禁止 root 密码登录，但允许密钥 (prohibit-password)"
                echo "  4) 不修改此项"
                read -rp "请选择 [2]: " r
                r="${r:-2}"
                case "$r" in
                    1) DO_ROOT_CHANGE=1; PERMIT_ROOT_VALUE="yes" ;;
                    2) DO_ROOT_CHANGE=1; PERMIT_ROOT_VALUE="no" ;;
                    3) DO_ROOT_CHANGE=1; PERMIT_ROOT_VALUE="prohibit-password" ;;
                    4) DO_ROOT_CHANGE=0; PERMIT_ROOT_VALUE="" ;;
                    *) echo "❌ 无效选择" ;;
                esac
                ;;
            2)
                echo -e "\n2) 密码登录设置 (PasswordAuthentication)"
                echo "  1) 启用密码登录 (yes)"
                echo "  2) 禁用密码登录 (no)"
                echo "  3) 不修改此项"
                read -rp "请选择 [2]: " p
                p="${p:-2}"
                case "$p" in
                    1) DO_PASS_CHANGE=1; PASSWORD_AUTH_VALUE="yes" ;;
                    2) DO_PASS_CHANGE=1; PASSWORD_AUTH_VALUE="no" ;;
                    3) DO_PASS_CHANGE=0; PASSWORD_AUTH_VALUE="" ;;
                    *) echo "❌ 无效选择" ;;
                esac
                ;;
            3)
                echo -e "\n3) 添加公钥 (authorized_keys)"
                if ask_yn "是否要添加/写入公钥？" "Y"; then
                    DO_ADD_PUBKEY=1
                else
                    DO_ADD_PUBKEY=0
                    PUBKEY=""
                    TARGET_USER=""
                    continue
                fi

                # 获取公钥
                while true; do
                    echo -e "\n🔑 请选择公钥来源"
                    echo "  1) 直接粘贴公钥 / URL / github:用户名 / gitlab:用户名"
                    echo "  2) 从文件读取（读取第一行非空）"
                    read -rp "请选择 [1]: " ks
                    ks="${ks:-1}"
                    if [ "$ks" = "2" ]; then
                        read -rp "请输入公钥文件路径: " kf
                        if PUBKEY="$(read_pubkey_from_file "$kf")"; then
                            break
                        fi
                    else
                        read -rp "请输入公钥、URL 或平台:username: " ki
                        if PUBKEY="$(resolve_pubkey "$ki")"; then
                            break
                        fi
                    fi
                    echo "❌ 获取公钥失败，请重试"
                done

                if ! validate_public_key "$PUBKEY"; then
                    echo "❌ 公钥无效，已取消本次“添加公钥”选择"
                    DO_ADD_PUBKEY=0
                    PUBKEY=""
                    TARGET_USER=""
                    continue
                fi

                # 选择用户
                TARGET_USER="$(choose_target_user_interactive)"
                ;;
            4)
                apply_selected_changes
                exit 0
                ;;
            5)
                DO_ROOT_CHANGE=0
                DO_PASS_CHANGE=0
                DO_ADD_PUBKEY=0
                PERMIT_ROOT_VALUE=""
                PASSWORD_AUTH_VALUE=""
                PUBKEY=""
                TARGET_USER=""
                echo "✅ 已清空所有选择"
                ;;
            0)
                echo "👋 已退出，未做任何修改"
                exit 0
                ;;
            *)
                echo "❌ 无效选项"
                ;;
        esac
    done
}

main
EOF

# 设置脚本权限
chmod 755 "$SCRIPT_PATH"

echo "🎉 安装完成！现在可以运行命令：$SCRIPT_NAME"
echo "ℹ️  重要提示：在运行 $SCRIPT_NAME 前，确保您有其他方式访问服务器（如控制台），以防SSH配置错误导致无法连接"