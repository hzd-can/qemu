#!/bin/bash
#
# 为 Windows OpenSSH 服务器配置免密登录
# 适用于 Windows 的 Administrator 账户（使用 administrators_authorized_keys）
#
# 用法：
#   ./setup-windows-ssh-key.sh [WINDOWS_IP] [PORT] [USERNAME]
#   默认：IP=192.168.0.217, PORT=2222, USERNAME=Administrator
#
# 需要输入 Windows 账户密码（脚本会提示）
#

set -e

# 参数
WIN_IP="${1:-192.168.0.217}"
WIN_PORT="${2:-2222}"
WIN_USER="${3:-Administrator}"

# 生成的密钥路径
KEY_NAME="miuwin_key"
KEY_DIR="$HOME/.ssh"
KEY_FILE="$KEY_DIR/$KEY_NAME"
PUBKEY_FILE="$KEY_FILE.pub"

# SSH 选项
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查依赖
if ! command -v expect &> /dev/null; then
    log_error "需要安装 expect"
    echo "Ubuntu/Debian: sudo apt install expect"
    exit 1
fi

if ! command -v ssh-keygen &> /dev/null; then
    log_error "需要安装 openssh-client"
    exit 1
fi

# 创建 .ssh 目录
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# 生成密钥（如果不存在）
if [ ! -f "$KEY_FILE" ]; then
    log_info "生成 ed25519 密钥对: $KEY_FILE"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "miuwin-qemu-access"
else
    log_warn "密钥已存在，使用现有密钥: $KEY_FILE"
fi

PUBKEY=$(cat "$PUBKEY_FILE")
log_info "公钥: $PUBKEY"

# 读取密码
read -s -p "输入 Windows 账户 $WIN_USER 的密码: " WIN_PASS
echo

# 构造 Windows 端 PowerShell 脚本（使用单引号包裹公钥，避免转义问题）
PS_SCRIPT=$(cat <<PSEOF
\$ErrorActionPreference = "Stop"

\$pubkey = '$PUBKEY'

# Windows OpenSSH 对 Administrators 组用户使用的密钥文件
\$keyFile = "\$env:ProgramData\ssh\administrators_authorized_keys"
\$sshDir = "\$env:ProgramData\ssh"

# 确保目录存在
if (-not (Test-Path \$sshDir)) {
    New-Item -ItemType Directory -Path \$sshDir | Out-Null
}

# 如果文件已存在，先删除（目录有 FullControl 即可删除子文件）
if (Test-Path \$keyFile) {
    Remove-Item -Force \$keyFile
}

# 写入公钥
Set-Content -Path \$keyFile -Value \$pubkey -Encoding ASCII

# 设置权限：移除继承，只允许 SYSTEM 和 Administrators 读取
\$acl = Get-Acl \$keyFile
\$acl.SetAccessRuleProtection(\$true, \$false)
\$acl.Access | ForEach-Object { \$acl.RemoveAccessRule(\$_) | Out-Null }

\$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'NT AUTHORITY\SYSTEM', 'Read', 'Allow'
)
\$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Administrators', 'Read', 'Allow'
)

\$acl.SetAccessRule(\$systemRule)
\$acl.SetAccessRule(\$adminRule)
Set-Acl \$keyFile \$acl

# 重启 sshd
Restart-Service sshd

Write-Output "SSH key authentication configured successfully for administrators."
PSEOF
)

# Base64 编码 PowerShell 脚本（UTF-16LE），避免 SSH 传参时的引号问题
ENCODED_PS=$(printf '%s' "$PS_SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)

log_info "执行 Windows 配置脚本..."
expect <<EOF
spawn ssh -p $WIN_PORT $SSH_OPTS $WIN_USER@$WIN_IP powershell -ExecutionPolicy Bypass -EncodedCommand $ENCODED_PS
expect "password:"
send "$WIN_PASS\r"
expect eof
EOF

# 测试免密登录
log_info "测试免密登录..."
if ssh -p "$WIN_PORT" -i "$KEY_FILE" $SSH_OPTS -o PasswordAuthentication=no "$WIN_USER@$WIN_IP" hostname > /dev/null 2>&1; then
    log_info "✓ 免密登录配置成功！"
    echo ""
    echo "之后可以用这个命令连接："
    echo "  ssh -p $WIN_PORT -i $KEY_FILE $WIN_USER@$WIN_IP"
else
    log_error "✗ 免密登录测试失败"
    exit 1
fi
