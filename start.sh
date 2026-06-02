#!/bin/bash
#===============================================================================
# AlmaLinux 10: SSH 密钥 + Google Authenticator 双因素认证配置脚本
# 用法: sudo bash script.sh -u <用户名> -p <端口>
# 示例: sudo bash script.sh -u myadmin -p 7022
#===============================================================================

set -e

# ---------- 默认值 ----------
USERNAME="ec2-user"
SSHPORT="7022"

# ---------- 解析参数 ----------
while getopts "u:p:h" opt; do
    case $opt in
        u) USERNAME="$OPTARG" ;;
        p) SSHPORT="$OPTARG" ;;
        h)
            echo "用法: $0 -u <用户名> -p <端口>"
            exit 0
            ;;
        *)
            echo "无效参数，使用 -h 查看帮助"
            exit 1
            ;;
    esac
done

# ---------- 权限检查 ----------
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户执行此脚本 (sudo ...)"
    exit 1
fi

# ---------- 创建用户 ----------
echo ">>> 创建用户 ${USERNAME} ..."
if id "${USERNAME}" &>/dev/null; then
    echo "用户 ${USERNAME} 已存在，跳过创建。"
else
    useradd -m -s /bin/bash "${USERNAME}"
    echo "请设置用户 ${USERNAME} 的密码:"
    passwd "${USERNAME}"
fi

# ---------- 安装所需软件 ----------
echo ">>> 安装 EPEL 与必要软件包 ..."
dnf install -y epel-release || echo "EPEL 安装失败，继续尝试安装剩余包"
dnf install -y google-authenticator qrencode sudo expect

# ---------- 加入 wheel 组 ----------
usermod -aG wheel "${USERNAME}"

# ---------- 交互式输入一行公钥 ----------
echo "============================================="
echo "请粘贴 ${USERNAME} 用户的 SSH 公钥（一行，例如 ssh-ed25519 AAAA...）"
echo "============================================="
read -r PUBKEY_CONTENT

SSH_DIR="/home/${USERNAME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"

if [ -n "${PUBKEY_CONTENT}" ]; then
    echo "${PUBKEY_CONTENT}" > "${AUTH_KEYS}"
    echo "公钥已保存至 ${AUTH_KEYS}"
else
    echo "警告: 未检测到输入，${AUTH_KEYS} 将保持为空。请稍后手动添加。"
fi
chmod 600 "${AUTH_KEYS}" 2>/dev/null || true
chown "${USERNAME}:${USERNAME}" "${AUTH_KEYS}" 2>/dev/null || true

# ---------- 修改 SSH 主配置文件 ----------
echo ">>> 修改 SSH 配置 /etc/ssh/sshd_config ..."
SSHD_CFG="/etc/ssh/sshd_config"
declare -A SETTINGS=(
    ["Port"]="${SSHPORT}"
    ["LoginGraceTime"]="30s"
    ["PermitRootLogin"]="no"
    ["PasswordAuthentication"]="no"
    ["PubkeyAuthentication"]="yes"
    ["ChallengeResponseAuthentication"]="yes"
    ["UsePAM"]="yes"
    ["KbdInteractiveAuthentication"]="yes"
    ["AuthenticationMethods"]="publickey,keyboard-interactive"
)

for KEY in "${!SETTINGS[@]}"; do
    VALUE="${SETTINGS[$KEY]}"
    if grep -qE "^[#]?${KEY}\b" "${SSHD_CFG}"; then
        sed -i "s|^#\?${KEY}\b.*|${KEY} ${VALUE}|" "${SSHD_CFG}"
    else
        echo "${KEY} ${VALUE}" >> "${SSHD_CFG}"
    fi
done

# ---------- 处理 drop-in 配置文件 ----------
echo ">>> 处理 /etc/ssh/sshd_config.d/50-redhat.conf ..."
REDHAT_CFG="/etc/ssh/sshd_config.d/50-redhat.conf"
if [ -f "${REDHAT_CFG}" ]; then
    if grep -qE "^[#]?ChallengeResponseAuthentication" "${REDHAT_CFG}"; then
        sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' "${REDHAT_CFG}"
    else
        echo "ChallengeResponseAuthentication yes" >> "${REDHAT_CFG}"
    fi
fi

CLOUD_CFG="/etc/ssh/sshd_config.d/50-cloud-init.conf"
if [ -f "${CLOUD_CFG}" ]; then
    echo ">>> 处理 ${CLOUD_CFG} ..."
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${CLOUD_CFG}"
fi

# ---------- 验证 SSH 配置并重启 ----------
echo ">>> 测试 SSH 配置 ..."
if ! sshd -t; then
    echo "错误: sshd 配置测试失败，请检查配置文件。"
    exit 1
fi

echo ">>> 重启 sshd 服务 ..."
systemctl restart sshd
systemctl status sshd --no-pager

# ---------- 自动配置 Google Authenticator（expect 处理交互）----------
echo "============================================="
echo "接下来将以 ${USERNAME} 身份配置 Google Authenticator"
echo "请扫描即将出现的二维码，并手动输入验证码。"
echo "之后的确认问题由脚本自动回答 (y y n y)。"
echo "============================================="

# 生成 expect 临时脚本
TMPEXP=$(mktemp /tmp/ga_expect.XXXXXX)
cat > "$TMPEXP" <<EOF
#!/usr/bin/expect
spawn su - ${USERNAME} -c "google-authenticator"
set timeout -1

# 等待出现二维码和输入验证码的提示，然后交还控制给用户手动输入
expect {
    -re "Enter code from app" {
        interact "\r" return
        send "\r"
    }
}

# 依次自动回答四个问题：y y n y
expect {
    -re "Do you want authentication tokens to be time-based" {
        send "y\r"
        exp_continue
    }
    -re "Do you want to disallow multiple uses" {
        send "y\r"
        exp_continue
    }
    -re "By default, tokens are good for 30 seconds" {
        send "n\r"
        exp_continue
    }
    -re "Do you want to enable rate-limiting" {
        send "y\r"
        exp_continue
    }
    eof
}
EOF
chmod +x "$TMPEXP"
"$TMPEXP"
rm -f "$TMPEXP"

echo ""
echo "============================================="
echo "⚠️  重要：请立即保存上面显示的 5 个紧急备用验证码！"
echo "这些备用码可在手机丢失时用于登录，务必妥善保管。"
echo "============================================="

# ---------- PAM 配置 ----------
echo ">>> 配置 PAM 模块 ..."

PAM_SSHD="/etc/pam.d/sshd"
if ! grep -q "pam_google_authenticator.so" "${PAM_SSHD}"; then
    sed -i '1i auth required pam_google_authenticator.so' "${PAM_SSHD}"
    echo "已添加 google_authenticator 到 ${PAM_SSHD}"
else
    echo "${PAM_SSHD} 已包含 google_authenticator"
fi

PAM_SYS="/etc/pam.d/system-auth"
if [ -f "${PAM_SYS}" ]; then
    cp "${PAM_SYS}" "${PAM_SYS}.bak"
    if ! grep -q "pam_google_authenticator.so" "${PAM_SYS}"; then
        sed -i '0,/^auth/s/^auth/auth required pam_google_authenticator.so\nauth/' "${PAM_SYS}"
        echo "已添加 google_authenticator 到 ${PAM_SYS}"
    else
        echo "${PAM_SYS} 已包含 google_authenticator"
    fi
fi

echo ">>> 验证 sudo PAM 配置 ..."
if grep -q system-auth /etc/pam.d/sudo; then
    echo "sudo 已包含 system-auth，sudo 时将触发 2FA。"
else
    echo "警告: sudo 未引用 system-auth，sudo 时可能不需要 2FA。请手动检查 /etc/pam.d/sudo。"
fi

echo "============================================="
echo "配置完成！请验证以下功能："
echo "1. 使用 ${USERNAME} 通过端口 ${SSHPORT} 登录: ssh ${USERNAME}@<IP> -p ${SSHPORT}"
echo "   预期: 密钥 + 2FA 验证码"
echo "2. 登录后执行 sudo whoami，应要求输入 2FA 验证码"
echo "3. 尝试 root 登录应被拒绝: ssh root@<IP> -p ${SSHPORT}"
echo "============================================="