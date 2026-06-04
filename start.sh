#!/bin/bash
#===============================================================================
# AlmaLinux 10: SSH 密钥(ed25519) + Google Authenticator 双因素认证配置脚本
# 用法: sudo bash script.sh -u <用户名> -p <端口>
# 示例: sudo bash script.sh -u myadmin -p 7022
# 脚本将自动生成 ed25519 密钥对，私钥存放于用户家目录 .ssh/id_ed25519，
# 请务必在配置完成后将私钥安全下载到本地，并删除服务器上的私钥（如不愿保留）。
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
    while true; do
        if [ ! -r /dev/tty ]; then
            echo "错误：无法读取终端输入。请直接运行脚本而不是通过 stdin 管道。"
            exit 1
        fi

        read -s -p "New password: " PASSWORD1 </dev/tty
        echo
        read -s -p "Retype new password: " PASSWORD2 </dev/tty
        echo

        if [ "${PASSWORD1}" != "${PASSWORD2}" ]; then
            echo "两次输入的密码不一致，请重新输入。"
            continue
        fi

        if [ -z "${PASSWORD1}" ]; then
            echo "密码不能为空，请重新输入。"
            continue
        fi

        if command -v chpasswd >/dev/null 2>&1; then
            echo "${USERNAME}:${PASSWORD1}" | chpasswd
        else
            echo "${PASSWORD1}" | passwd --stdin "${USERNAME}"
        fi

        if [ $? -eq 0 ]; then
            break
        fi

        echo "设置密码失败，请重新输入。"
    done
fi

# ---------- 安装所需软件 ----------
echo ">>> 安装 EPEL 与必要软件包 ..."
dnf install -y epel-release || echo "EPEL 安装失败，继续尝试安装剩余包"
dnf install -y google-authenticator qrencode sudo expect

# ---------- 加入 wheel 组 ----------
usermod -aG wheel "${USERNAME}"

# ---------- 本地生成 ed25519 密钥对并部署公钥 ----------
echo ">>> 在本地生成 ed25519 密钥对 ..."
SSH_DIR="/home/${USERNAME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# 在 /tmp 下生成临时密钥（缓存）
TMP_KEY="/tmp/tmp_ssh_key_${USERNAME}"
ssh-keygen -t ed25519 -f "${TMP_KEY}" -N "" -C "${USERNAME}@$(hostname)" >/dev/null 2>&1

# 将公钥写入 authorized_keys（覆盖以保证只允许该密钥）
cat "${TMP_KEY}.pub" > "${AUTH_KEYS}"
echo "公钥已写入 ${AUTH_KEYS}"

# 将私钥移动到用户 .ssh 目录
mv "${TMP_KEY}" "${SSH_DIR}/id_ed25519"
chmod 600 "${SSH_DIR}/id_ed25519"
chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"
echo "私钥已保存至 ${SSH_DIR}/id_ed25519"

# 清理 /tmp 下的临时公钥文件（私钥已移走）
rm -f "${TMP_KEY}.pub"

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

# ---------- 自动配置 Google Authenticator（命令行参数方式）----------
echo "============================================="
echo "接下来将以 ${USERNAME} 身份配置 Google Authenticator"
echo "============================================="

su - "${USERNAME}" -c "google-authenticator -f -d -w 3 -r 3 -R 30 -t" 2>&1 | tee /tmp/ga_output_${USERNAME}.txt

echo ""
echo "============================================="
echo "⚠️  重要：请立即保存上面显示的 5 个紧急备用验证码！"
echo "这些备用码可在手机丢失时用于登录，务必妥善保管。"
echo "QR 码/密钥已保存，请用 Google Authenticator 应用扫描二维码或手动输入密钥。"
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
echo "1. 私钥路径: ${SSH_DIR}/id_ed25519"
echo "   请立即将该私钥下载到本地 (例如用 scp 或复制内容)"
echo "   并在本地执行 chmod 600 <私钥文件>"
echo "   登录: ssh -i <私钥文件> ${USERNAME}@<服务器IP> -p ${SSHPORT}"
echo "   预期: 密钥 + 2FA 验证码"
echo "2. 登录后执行 sudo whoami，应要求输入 2FA 验证码"
echo "3. 尝试 root 登录应被拒绝: ssh root@<IP> -p ${SSHPORT}"
echo "4. 若不再需要服务器保留私钥，建议删除: rm ${SSH_DIR}/id_ed25519"
echo "============================================="