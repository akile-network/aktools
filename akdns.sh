#!/usr/bin/env bash
# ============================================================
# AKDNS v3.0.0 - 智能 DNS 测速与系统接管工具
# 测试 DNS 连通性 → 选出最优 AKDNS → 接管系统 DNS
# 不论 netplan / systemd-resolved / NetworkManager / resolvconf，
# 一律收敛为「直接读取 /etc/resolv.conf」，确保解锁一定生效。
# 支持 Linux 系统识别、自动备份与一键还原。
# ============================================================

set -uo pipefail

# ---- 全局常量 ----
VERSION="3.0.0"
BACKUP_DIR="/var/lib/akdns/backup"
DOMAIN="www.google.com"
COUNT=5
TIMEOUT=1

# 接管后是否对 /etc/resolv.conf 加 chattr +i 锁定，
# 杜绝 dhclient / cloud-init / 网络管理器在重启或续租时覆盖。
# 还原（菜单「还原 DNS 配置」）会自动解锁。
LOCK_RESOLV_CONF=true

# AKDNS 控制台地址（用于脚本内提示，部署时请改成你的实际域名）
CONSOLE_URL="https://akdns.akile.io/console"

DNS_LIST=(
  "66.66.66.66"
  "45.207.157.146"
  "108.160.138.51"
  "139.180.133.239"
  "45.76.83.113"
  "45.76.71.83"
  "45.63.99.176"
  "166.0.199.207"
)

# ---- 运行时状态 ----
BEST_DNS=""
DISTRO_ID="unknown"
DISTRO_NAME="Unknown"
DISTRO_VERSION=""
INIT_SYSTEM="unknown"
DNS_BACKEND_TEMP="resolv.conf"
DNS_BACKEND_PERM="resolv.conf"

# ---- 颜色定义 ----
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ============================================================
# 工具函数
# ============================================================

log_info()    { printf '%b\n' "${BLUE}[信息]${NC} $*"; }
log_success() { printf '%b\n' "${GREEN}[成功]${NC} $*"; }
log_warn()    { printf '%b\n' "${YELLOW}[警告]${NC} $*"; }
log_error()   { printf '%b\n' "${RED}[错误]${NC} $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "此操作需要 root 权限，请使用 sudo 运行"
    return 1
  fi
}

require_command() {
  local cmd="$1"
  local pkg="${2:-$1}"
  if ! command -v "$cmd" &>/dev/null; then
    log_error "未找到命令: $cmd，请先安装 $pkg"
    return 1
  fi
}

confirm_action() {
  local prompt="${1:-确认执行?}"
  local answer
  printf '%b' "${YELLOW}$prompt [y/N]: ${NC}"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

press_enter() {
  echo ""
  read -r -p "按回车键返回菜单..."
}

validate_ipv4() {
  local ip="$1"
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  local IFS='.'
  read -ra octets <<< "$ip"
  for octet in "${octets[@]}"; do
    if (( octet > 255 )); then
      return 1
    fi
  done
  return 0
}

get_primary_interface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

# 通过默认路由接口获取 NM 连接 UUID（避免连接名含冒号被截断）
get_active_nm_connection_uuid() {
  local iface
  iface=$(get_primary_interface)
  if [[ -z "$iface" ]]; then
    # 回退：取第一个活动连接
    nmcli -t -f UUID con show --active 2>/dev/null | head -1
    return
  fi
  nmcli -t -f UUID,DEVICE con show --active 2>/dev/null \
    | awk -F: -v dev="$iface" '$2==dev {print $1; exit}'
}

# 通过 UUID 获取连接名（用于显示）
get_nm_connection_name() {
  local uuid="$1"
  nmcli -t -f NAME,UUID con show 2>/dev/null \
    | awk -F: -v u="$uuid" '$NF==u {$NF=""; sub(/:$/,""); print; exit}'
}

# 安全写入 resolv.conf：使用 mktemp 在 /etc 下创建临时文件，原子替换
safe_write_resolv_conf() {
  local dns_ip="$1"
  local had_immutable=false
  local had_symlink=""
  local tmpfile=""

  # 内部清理函数：失败时恢复状态
  _swrc_cleanup() {
    # 清理临时文件
    [[ -n "$tmpfile" ]] && [[ -e "$tmpfile" ]] && rm -f "$tmpfile"
    # 恢复 immutable
    if $had_immutable && [[ -e /etc/resolv.conf ]]; then
      chattr +i /etc/resolv.conf 2>/dev/null
    fi
    # 恢复被删的 symlink
    if [[ -n "$had_symlink" ]] && [[ ! -e /etc/resolv.conf ]]; then
      ln -sf "$had_symlink" /etc/resolv.conf 2>/dev/null
      log_warn "已恢复 resolv.conf 符号链接 → $had_symlink"
    fi
  }

  # 检查 chattr 保护
  if command -v lsattr &>/dev/null && [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
    local attrs
    attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
    if [[ "$attrs" == *i* ]]; then
      log_info "检测到 immutable 标志，临时移除..."
      chattr -i /etc/resolv.conf || { log_error "无法移除 immutable 标志"; return 1; }
      had_immutable=true
    fi
  fi

  # 检查 symlink 指向 systemd stub
  if [[ -L /etc/resolv.conf ]]; then
    local link_target
    link_target=$(readlink /etc/resolv.conf 2>/dev/null)
    local link_resolved
    link_resolved=$(readlink -f /etc/resolv.conf 2>/dev/null)
    if [[ "$link_resolved" == *"systemd"* ]] || [[ "$link_resolved" == *"stub"* ]]; then
      log_warn "/etc/resolv.conf 是 systemd 符号链接，删除后直接写入"
      had_symlink="$link_target"
      rm -f /etc/resolv.conf || { log_error "无法删除 resolv.conf 符号链接"; return 1; }
    fi
  fi

  # 使用 mktemp 在 /etc 下创建安全临时文件
  tmpfile=$(mktemp /etc/resolv.conf.akdns.XXXXXX) || { log_error "无法创建临时文件"; _swrc_cleanup; return 1; }

  # 确保临时文件不是符号链接
  if [[ -L "$tmpfile" ]]; then
    log_error "临时文件安全检查失败"
    _swrc_cleanup; return 1
  fi

  # 保留非 nameserver 行
  if [[ -f /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
    grep -v '^nameserver' /etc/resolv.conf > "$tmpfile" 2>/dev/null || true
  fi
  echo "nameserver $dns_ip" >> "$tmpfile"

  # 原子替换（mv 可直接覆盖 symlink，无需先 rm）
  chmod 644 "$tmpfile" || { log_error "无法设置临时文件权限"; _swrc_cleanup; return 1; }
  mv -f "$tmpfile" /etc/resolv.conf || { log_error "无法替换 resolv.conf"; _swrc_cleanup; return 1; }
  tmpfile=""  # mv 成功后不再需要清理

  # SELinux 上下文恢复
  if command -v restorecon &>/dev/null; then
    restorecon -F /etc/resolv.conf 2>/dev/null
  fi

  # 恢复 immutable
  if $had_immutable; then
    log_info "恢复 immutable 标志"
    chattr +i /etc/resolv.conf 2>/dev/null
  fi

  # 验证文件内容
  if ! grep -q "^nameserver $dns_ip" /etc/resolv.conf 2>/dev/null; then
    log_error "resolv.conf 写入验证失败"
    return 1
  fi

  return 0
}

# ============================================================
# 系统 DNS 接管（统一收敛为 /etc/resolv.conf）
# ============================================================

# 锁定 / 解锁 resolv.conf（immutable），防止被其他程序覆盖
lock_resolv_conf() {
  command -v chattr &>/dev/null || return 0
  [[ -e /etc/resolv.conf ]] || return 0
  [[ -L /etc/resolv.conf ]] && return 0   # 符号链接不锁定
  if chattr +i /etc/resolv.conf 2>/dev/null; then
    log_info "已锁定 /etc/resolv.conf（防止被覆盖；还原时会自动解锁）"
  fi
}

unlock_resolv_conf() {
  command -v chattr &>/dev/null || return 0
  [[ -e /etc/resolv.conf ]] || return 0
  [[ -L /etc/resolv.conf ]] && return 0
  local attrs
  attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
  if [[ "$attrs" == *i* ]]; then
    chattr -i /etc/resolv.conf 2>/dev/null && log_info "已解除 /etc/resolv.conf 锁定"
  fi
}

# 确保 NSS 主机解析链路包含 dns，否则停用 resolved 后 resolv.conf 不会被查询
ensure_nsswitch_dns() {
  local f="/etc/nsswitch.conf"
  [[ -f "$f" ]] || return 0
  local line
  line=$(grep -E '^[[:space:]]*hosts:' "$f" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 0
  # 已包含 dns 则无需处理
  if echo "$line" | grep -qw 'dns'; then
    return 0
  fi
  log_info "nsswitch.conf 缺少 dns，自动补充以确保读取 resolv.conf..."
  cp -a "$f" "$f.akdns.bak" 2>/dev/null
  # 在 hosts: 行末尾追加 dns
  sed -i -E 's/^([[:space:]]*hosts:.*)$/\1 dns/' "$f"
}

# 停用所有可能改写 resolv.conf 的 DNS 管理器，让系统直接读取静态 resolv.conf
neutralize_dns_managers() {
  # 1) systemd-resolved：停止并禁用（其 stub 127.0.0.53 会拦截解析）
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null \
        || systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
      log_info "停用 systemd-resolved（接管 DNS）..."
      systemctl disable --now systemd-resolved 2>/dev/null \
        || log_warn "停用 systemd-resolved 失败，将依赖 resolv.conf 锁定兜底"
    fi
  fi

  # 2) NetworkManager：令其不再管理 resolv.conf（dns=none），但不停用网络
  if command -v nmcli &>/dev/null \
      && { systemctl is-active --quiet NetworkManager 2>/dev/null || nmcli general status &>/dev/null 2>&1; }; then
    if [[ -d /etc/NetworkManager ]]; then
      mkdir -p /etc/NetworkManager/conf.d
      cat > /etc/NetworkManager/conf.d/akdns-dns.conf << 'EOF'
# 由 AKDNS 写入：让 NetworkManager 不再覆盖 /etc/resolv.conf
[main]
dns=none
EOF
      chmod 644 /etc/NetworkManager/conf.d/akdns-dns.conf
      log_info "已让 NetworkManager 放手 resolv.conf (dns=none)"
      systemctl reload NetworkManager 2>/dev/null \
        || nmcli general reload 2>/dev/null || true
    fi
  fi

  # 3) resolvconf / openresolv：停用其服务，避免重新生成
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null \
      && systemctl is-active --quiet resolvconf 2>/dev/null; then
    log_info "停用 resolvconf 服务..."
    systemctl disable --now resolvconf 2>/dev/null || true
  fi

  # 4) 确保 NSS 解析链路会查询 resolv.conf
  ensure_nsswitch_dns
}

# 核心：不论原后端是什么，统一接管为静态 /etc/resolv.conf 并写入指定 DNS
force_static_resolv_conf() {
  local dns_ip="$1"
  log_info "接管系统 DNS：统一改为直接读取 /etc/resolv.conf..."

  # 若此前已锁定，先解锁以便写入
  unlock_resolv_conf

  # 停用各类 DNS 管理器
  neutralize_dns_managers

  # 写入静态 resolv.conf（safe_write 会移除 systemd 符号链接并原子替换）
  if ! safe_write_resolv_conf "$dns_ip"; then
    log_error "写入 resolv.conf 失败"
    return 1
  fi

  # 锁定，杜绝 dhclient / cloud-init / 管理器在续租或重启时覆盖
  if $LOCK_RESOLV_CONF; then
    lock_resolv_conf
  fi

  return 0
}

# ============================================================
# 系统识别
# ============================================================

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${NAME:-Unknown}"
    DISTRO_VERSION="${VERSION_ID:-}"
  elif [[ -f /etc/redhat-release ]]; then
    DISTRO_ID="rhel"
    DISTRO_NAME=$(cat /etc/redhat-release)
    DISTRO_VERSION=$(sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' /etc/redhat-release)
  elif [[ -f /etc/alpine-release ]]; then
    DISTRO_ID="alpine"
    DISTRO_NAME="Alpine Linux"
    DISTRO_VERSION=$(cat /etc/alpine-release)
  elif [[ -f /etc/arch-release ]]; then
    DISTRO_ID="arch"
    DISTRO_NAME="Arch Linux"
    DISTRO_VERSION="rolling"
  else
    DISTRO_ID="unknown"
    DISTRO_NAME="Unknown"
    DISTRO_VERSION=""
  fi

  DISTRO_ID=$(echo "$DISTRO_ID" | tr '[:upper:]' '[:lower:]')
  log_info "检测到系统: $DISTRO_NAME ${DISTRO_VERSION}"
}

detect_init_system() {
  if [[ -d /run/systemd/system ]]; then
    INIT_SYSTEM="systemd"
  elif [[ -f /sbin/openrc ]] || command -v openrc &>/dev/null; then
    INIT_SYSTEM="openrc"
  elif [[ -f /etc/init.d/rcS ]] || [[ -d /etc/init.d ]]; then
    INIT_SYSTEM="sysvinit"
  else
    INIT_SYSTEM="unknown"
  fi
  log_info "init 系统: $INIT_SYSTEM"
}

detect_dns_backend() {
  DNS_BACKEND_TEMP="resolv.conf"
  DNS_BACKEND_PERM="resolv.conf"

  local has_netplan=false
  local has_resolved=false
  local has_nm=false

  # 检测 netplan（需要 yaml 文件存在且命令可用）
  if command -v netplan &>/dev/null; then
    local -a yaml_files=()
    # 使用 nullglob 安全检测
    local old_nullglob
    old_nullglob=$(shopt -p nullglob 2>/dev/null || true)
    shopt -s nullglob
    yaml_files=(/etc/netplan/*.yaml)
    eval "$old_nullglob" 2>/dev/null || shopt -u nullglob
    if [[ ${#yaml_files[@]} -gt 0 ]]; then
      has_netplan=true
    fi
  fi

  # 检测 systemd-resolved
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null \
      && systemctl is-active systemd-resolved &>/dev/null; then
    has_resolved=true
  fi

  # 检测 NetworkManager
  if command -v nmcli &>/dev/null; then
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null \
        && systemctl is-active NetworkManager &>/dev/null; then
      has_nm=true
    elif nmcli general status &>/dev/null 2>&1; then
      has_nm=true
    fi
  fi

  # 确定临时后端
  if $has_resolved; then
    DNS_BACKEND_TEMP="systemd-resolved"
  elif $has_nm; then
    DNS_BACKEND_TEMP="networkmanager"
  else
    DNS_BACKEND_TEMP="resolv.conf"
  fi

  # 确定永久后端（netplan 需确认 renderer 实际生效）
  if $has_netplan; then
    # 验证 netplan 是否真正管理网络（检查 renderer）
    local netplan_active=false
    for yf in /etc/netplan/*.yaml; do
      if [[ -f "$yf" ]] && grep -qE 'renderer:\s*(networkd|NetworkManager)' "$yf" 2>/dev/null; then
        netplan_active=true
        break
      fi
    done
    # 即使没有明确 renderer，有 yaml 文件也认为 netplan 生效（默认 renderer 为 networkd）
    if $netplan_active || $has_netplan; then
      DNS_BACKEND_PERM="netplan"
    fi
  elif $has_nm; then
    DNS_BACKEND_PERM="networkmanager"
  elif $has_resolved; then
    DNS_BACKEND_PERM="systemd-resolved"
  else
    DNS_BACKEND_PERM="resolv.conf"
  fi

  log_info "DNS 后端: 临时=$DNS_BACKEND_TEMP, 永久=$DNS_BACKEND_PERM"
}

# ============================================================
# 当前 DNS 读取
# ============================================================

get_current_dns() {
  local dns_servers=""

  case "$DNS_BACKEND_TEMP" in
    systemd-resolved)
      if command -v resolvectl &>/dev/null; then
        # 优先使用默认路由接口获取精确 DNS
        local iface
        iface=$(get_primary_interface)
        if [[ -n "$iface" ]]; then
          dns_servers=$(resolvectl dns "$iface" 2>/dev/null \
            | awk '{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+\./) printf "%s ", $i}')
        fi
        # 回退：全局解析
        if [[ -z "$dns_servers" ]]; then
          dns_servers=$(resolvectl status 2>/dev/null \
            | grep -E "DNS Servers|DNS 服务器" \
            | head -3 \
            | awk '{for(i=NF;i>=1;i--) if($i ~ /^[0-9]+\./) {printf "%s ", $i; break}}')
        fi
      fi
      ;;
    networkmanager)
      dns_servers=$(nmcli dev show 2>/dev/null \
        | awk '/IP4\.DNS/ {print $2}' \
        | tr '\n' ' ')
      ;;
  esac

  # 兜底：从 resolv.conf 读取
  if [[ -z "$dns_servers" ]] && [[ -f /etc/resolv.conf ]]; then
    dns_servers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
  fi

  echo "${dns_servers:-未知}"
}

# ============================================================
# 备份功能
# ============================================================

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR" || { log_error "无法创建备份目录: $BACKUP_DIR"; return 1; }
  chmod 700 "$BACKUP_DIR"
}

do_backup() {
  local tag="${1:-manual}"

  require_root || return 1
  ensure_backup_dir || return 1

  # 设置严格 umask
  local old_umask
  old_umask=$(umask)
  umask 077

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_path="$BACKUP_DIR/${timestamp}_${tag}"
  mkdir -p "$backup_path" || { umask "$old_umask"; log_error "无法创建备份目录"; return 1; }
  chmod 700 "$backup_path"

  local backed_up=()

  # 备份 resolv.conf（使用 -L 解引用符号链接，保存实际内容）
  if [[ -e /etc/resolv.conf ]]; then
    if [[ -L /etc/resolv.conf ]]; then
      # 记录符号链接目标
      readlink -f /etc/resolv.conf > "$backup_path/resolv.conf.symlink" 2>/dev/null
      # 解引用复制内容
      cp -aL /etc/resolv.conf "$backup_path/resolv.conf" 2>/dev/null || \
        cp /etc/resolv.conf "$backup_path/resolv.conf" 2>/dev/null
    else
      cp -a /etc/resolv.conf "$backup_path/"
    fi
    backed_up+=("/etc/resolv.conf")
  fi

  # 根据后端备份额外文件
  case "$DNS_BACKEND_PERM" in
    systemd-resolved)
      if [[ -f /etc/systemd/resolved.conf ]]; then
        cp -a /etc/systemd/resolved.conf "$backup_path/"
        backed_up+=("/etc/systemd/resolved.conf")
      fi
      # 也备份 drop-in（如果有）
      if [[ -d /etc/systemd/resolved.conf.d ]]; then
        mkdir -p "$backup_path/resolved.conf.d"
        cp -a /etc/systemd/resolved.conf.d/* "$backup_path/resolved.conf.d/" 2>/dev/null
        backed_up+=("/etc/systemd/resolved.conf.d/")
      fi
      ;;
    networkmanager)
      if [[ -d /etc/NetworkManager/conf.d ]]; then
        mkdir -p "$backup_path/NetworkManager-conf.d"
        cp -a /etc/NetworkManager/conf.d/* "$backup_path/NetworkManager-conf.d/" 2>/dev/null
      fi
      local nm_uuid
      nm_uuid=$(get_active_nm_connection_uuid)
      if [[ -n "$nm_uuid" ]]; then
        local nm_name
        nm_name=$(get_nm_connection_name "$nm_uuid")
        {
          echo "uuid=$nm_uuid"
          echo "name=$nm_name"
          nmcli -t -f ipv4.dns,ipv4.ignore-auto-dns con show "$nm_uuid" 2>/dev/null
        } > "$backup_path/nm-connection-dns.txt"
        backed_up+=("nm-connection:$nm_uuid")
      fi
      ;;
    netplan)
      local -a yaml_files=()
      local old_ng
      old_ng=$(shopt -p nullglob 2>/dev/null || true)
      shopt -s nullglob
      yaml_files=(/etc/netplan/*.yaml)
      eval "$old_ng" 2>/dev/null || shopt -u nullglob
      if [[ ${#yaml_files[@]} -gt 0 ]]; then
        mkdir -p "$backup_path/netplan"
        cp -a "${yaml_files[@]}" "$backup_path/netplan/"
        backed_up+=("/etc/netplan/*.yaml")
      fi
      ;;
  esac

  # 记录 DNS 管理器状态（供还原时撤销接管）
  local resolved_active=no resolved_enabled=no nm_active=no resolvconf_active=no
  if command -v systemctl &>/dev/null; then
    systemctl is-active  --quiet systemd-resolved 2>/dev/null && resolved_active=yes
    systemctl is-enabled --quiet systemd-resolved 2>/dev/null && resolved_enabled=yes
    systemctl is-active  --quiet resolvconf       2>/dev/null && resolvconf_active=yes
  fi
  if command -v nmcli &>/dev/null \
      && { systemctl is-active --quiet NetworkManager 2>/dev/null || nmcli general status &>/dev/null 2>&1; }; then
    nm_active=yes
  fi

  # 备份 nsswitch.conf（接管可能会补充 dns）
  if [[ -f /etc/nsswitch.conf ]]; then
    cp -a /etc/nsswitch.conf "$backup_path/nsswitch.conf"
    backed_up+=("/etc/nsswitch.conf")
  fi

  # 写入元数据
  {
    echo "timestamp=$timestamp"
    echo "tag=$tag"
    echo "distro=$DISTRO_ID"
    echo "distro_version=$DISTRO_VERSION"
    echo "backend_temp=$DNS_BACKEND_TEMP"
    echo "backend_perm=$DNS_BACKEND_PERM"
    echo "dns_servers=$(get_current_dns)"
    echo "resolved_active=$resolved_active"
    echo "resolved_enabled=$resolved_enabled"
    echo "nm_active=$nm_active"
    echo "resolvconf_active=$resolvconf_active"
    echo "files=${backed_up[*]}"
  } > "$backup_path/metadata.txt"

  umask "$old_umask"

  log_success "备份完成: $backup_path"
  return 0
}

# ============================================================
# 还原功能
# ============================================================

list_backups() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log_warn "未找到任何备份 (目录不存在: $BACKUP_DIR)"
    return 1
  fi

  local -a backup_dirs=()
  while IFS= read -r dir; do
    backup_dirs+=("$dir")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

  if [[ ${#backup_dirs[@]} -eq 0 ]]; then
    log_warn "未找到任何备份"
    return 1
  fi

  echo ""
  printf '%b\n' "${BOLD}可用备份列表:${NC}"
  echo "--------------------------------------------"
  printf "%-4s %-20s %-14s %s\n" "编号" "时间" "标签" "DNS"
  echo "--------------------------------------------"

  local i=1
  for dir in "${backup_dirs[@]}"; do
    if [[ -f "$dir/metadata.txt" ]]; then
      local ts tag dns
      ts=$(grep '^timestamp=' "$dir/metadata.txt" | cut -d= -f2-)
      tag=$(grep '^tag=' "$dir/metadata.txt" | cut -d= -f2-)
      dns=$(grep '^dns_servers=' "$dir/metadata.txt" | cut -d= -f2-)
      printf "%-4s %-20s %-14s %s\n" "$i" "$ts" "$tag" "$dns"
    else
      printf "%-4s %-20s %-14s %s\n" "$i" "$(basename "$dir")" "-" "元数据缺失"
    fi
    ((i++))
  done
  echo "--------------------------------------------"

  return 0
}

do_restore() {
  require_root || return 1

  if ! list_backups; then
    return 1
  fi

  local -a backup_dirs=()
  while IFS= read -r dir; do
    backup_dirs+=("$dir")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

  local choice
  read -r -p "请输入要还原的备份编号 (0 取消): " choice

  if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
    log_info "取消还原"
    return 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backup_dirs[@]} )); then
    log_error "无效的编号: $choice"
    return 1
  fi

  local target_dir="${backup_dirs[$((choice - 1))]}"

  if ! confirm_action "确认从 $(basename "$target_dir") 还原 DNS 配置?"; then
    log_info "取消还原"
    return 0
  fi

  # 还原前自动备份当前状态
  log_info "还原前自动备份当前配置..."
  if ! do_backup "pre-restore"; then
    log_error "备份当前配置失败，为安全起见中止还原"
    return 1
  fi

  # 读取目标备份的后端信息与 DNS 管理器状态
  local backend_perm_saved="resolv.conf"
  local resolved_active_saved="no" resolved_enabled_saved="no" resolvconf_active_saved="no"
  if [[ -f "$target_dir/metadata.txt" ]]; then
    backend_perm_saved=$(grep '^backend_perm=' "$target_dir/metadata.txt" | cut -d= -f2-)
    resolved_active_saved=$(grep '^resolved_active=' "$target_dir/metadata.txt" | cut -d= -f2-)
    resolved_enabled_saved=$(grep '^resolved_enabled=' "$target_dir/metadata.txt" | cut -d= -f2-)
    resolvconf_active_saved=$(grep '^resolvconf_active=' "$target_dir/metadata.txt" | cut -d= -f2-)
  fi

  # 撤销接管：移除 AKDNS 写入的 NetworkManager dns=none 配置
  if [[ -f /etc/NetworkManager/conf.d/akdns-dns.conf ]]; then
    rm -f /etc/NetworkManager/conf.d/akdns-dns.conf
    log_info "已移除 AKDNS 的 NetworkManager dns=none 配置"
  fi

  # 还原 resolv.conf
  if [[ -f "$target_dir/resolv.conf" ]]; then
    local restore_had_immutable=false
    # 检测并移除 immutable 标志
    if command -v lsattr &>/dev/null && [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
      local rattrs
      rattrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
      if [[ "$rattrs" == *i* ]]; then
        log_info "检测到 resolv.conf immutable 标志，临时移除..."
        chattr -i /etc/resolv.conf || { log_error "无法移除 immutable 标志，还原失败"; return 1; }
        restore_had_immutable=true
      fi
    fi
    # 移除现有的（可能是 symlink，或接管时写入的静态文件）
    rm -f /etc/resolv.conf || { log_error "无法移除现有 resolv.conf"; return 1; }
    # 若原本是符号链接（如 systemd-resolved 的 stub），优先恢复符号链接本身
    if [[ -f "$target_dir/resolv.conf.symlink" ]]; then
      local _symlink_target
      _symlink_target=$(cat "$target_dir/resolv.conf.symlink" 2>/dev/null)
      if [[ -n "$_symlink_target" ]]; then
        ln -sf "$_symlink_target" /etc/resolv.conf \
          && log_info "已恢复 resolv.conf 符号链接 → $_symlink_target"
      fi
    fi
    # 非符号链接场景：恢复静态文件内容
    if [[ ! -L /etc/resolv.conf ]]; then
      cp "$target_dir/resolv.conf" /etc/resolv.conf || { log_error "还原 resolv.conf 失败"; return 1; }
      chmod 644 /etc/resolv.conf
      # SELinux 上下文恢复
      if command -v restorecon &>/dev/null; then
        restorecon -F /etc/resolv.conf 2>/dev/null
      fi
    fi
    # 注意：还原的目的是撤销接管，这里不再重新加 immutable 锁
    # （接管时加的锁已在上面移除；如需手动锁定可自行执行 chattr +i）
    log_info "已还原 /etc/resolv.conf"
  fi

  case "$backend_perm_saved" in
    systemd-resolved)
      if [[ -f "$target_dir/resolved.conf" ]]; then
        if cp "$target_dir/resolved.conf" /etc/systemd/resolved.conf; then
          log_info "已还原 /etc/systemd/resolved.conf"
        else
          log_warn "还原 resolved.conf 失败"
        fi
      fi
      # 还原 drop-in
      if [[ -d "$target_dir/resolved.conf.d" ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        # 使用 cp -a src/. dst/ 避免空目录/通配符问题
        if cp -a "$target_dir/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null; then
          log_info "已还原 resolved.conf.d drop-in"
        else
          log_warn "还原 resolved.conf.d drop-in 失败"
        fi
        # 如果备份中没有 akdns.conf 但当前有，说明是还原到"无自定义DNS"状态
        if [[ ! -f "$target_dir/resolved.conf.d/akdns.conf" ]] && [[ -f /etc/systemd/resolved.conf.d/akdns.conf ]]; then
          rm -f /etc/systemd/resolved.conf.d/akdns.conf
        fi
      fi
      ;;
    networkmanager)
      if [[ -d "$target_dir/NetworkManager-conf.d" ]]; then
        mkdir -p /etc/NetworkManager/conf.d
        if cp -a "$target_dir/NetworkManager-conf.d/." /etc/NetworkManager/conf.d/ 2>/dev/null; then
          log_info "已还原 NetworkManager 配置文件"
        else
          log_warn "还原 NetworkManager 配置文件失败"
        fi
      fi
      if [[ -f "$target_dir/nm-connection-dns.txt" ]]; then
        local nm_uuid
        nm_uuid=$(grep '^uuid=' "$target_dir/nm-connection-dns.txt" | cut -d= -f2-)
        local saved_dns
        saved_dns=$(grep '^ipv4.dns:' "$target_dir/nm-connection-dns.txt" | cut -d: -f2-)
        local saved_ignore
        saved_ignore=$(grep '^ipv4.ignore-auto-dns:' "$target_dir/nm-connection-dns.txt" | cut -d: -f2-)
        if [[ -n "$nm_uuid" ]]; then
          local nm_restore_ok=true
          if [[ -n "$saved_dns" ]] && [[ "$saved_dns" != " " ]] && [[ "$saved_dns" != "" ]]; then
            nmcli con mod "$nm_uuid" ipv4.dns "$saved_dns" 2>/dev/null || { log_warn "还原 NM DNS 设置失败"; nm_restore_ok=false; }
          else
            nmcli con mod "$nm_uuid" ipv4.dns "" 2>/dev/null || nm_restore_ok=false
          fi
          if [[ "$saved_ignore" == "yes" ]]; then
            nmcli con mod "$nm_uuid" ipv4.ignore-auto-dns yes 2>/dev/null
          else
            nmcli con mod "$nm_uuid" ipv4.ignore-auto-dns no 2>/dev/null
          fi
          if $nm_restore_ok; then
            log_info "已还原 NetworkManager 连接 DNS 设置 (UUID: $nm_uuid)"
          fi
        fi
      fi
      ;;
    netplan)
      if [[ -d "$target_dir/netplan" ]]; then
        mkdir -p /etc/netplan
        if cp -a "$target_dir/netplan/." /etc/netplan/ 2>/dev/null; then
          log_info "已还原 netplan 配置"
        else
          log_warn "还原 netplan 配置失败"
        fi
      fi
      ;;
  esac

  # 撤销接管：还原 nsswitch.conf
  if [[ -f "$target_dir/nsswitch.conf" ]]; then
    cp -a "$target_dir/nsswitch.conf" /etc/nsswitch.conf 2>/dev/null \
      && log_info "已还原 /etc/nsswitch.conf"
  fi

  # 撤销接管：重新启用此前被停用的 DNS 管理器
  if command -v systemctl &>/dev/null; then
    if [[ "$resolved_enabled_saved" == "yes" ]] || [[ "$resolved_active_saved" == "yes" ]]; then
      log_info "重新启用 systemd-resolved..."
      systemctl enable systemd-resolved 2>/dev/null || true
      systemctl start  systemd-resolved 2>/dev/null || log_warn "systemd-resolved 启动失败，请手动检查"
    fi
    if [[ "$resolvconf_active_saved" == "yes" ]]; then
      log_info "重新启用 resolvconf..."
      systemctl enable --now resolvconf 2>/dev/null || true
    fi
  fi

  # 重载服务
  reload_dns_service "$backend_perm_saved"

  # 验证还原结果
  if verify_system_dns; then
    log_success "DNS 配置已还原并验证通过"
  else
    log_warn "DNS 配置已还原，但验证未通过，请手动检查"
  fi
}

reload_dns_service() {
  local backend="${1:-$DNS_BACKEND_PERM}"

  case "$backend" in
    systemd-resolved)
      if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl 不可用，无法重启 systemd-resolved"
      else
        log_info "重启 systemd-resolved..."
        if ! systemctl restart systemd-resolved; then
          log_warn "systemd-resolved 重启失败"
        fi
      fi
      ;;
    networkmanager)
      log_info "重载 NetworkManager..."
      if ! nmcli con reload; then
        log_warn "NetworkManager 重载失败"
      fi
      local uuid
      uuid=$(get_active_nm_connection_uuid)
      if [[ -n "$uuid" ]]; then
        nmcli con up "$uuid" 2>/dev/null || log_warn "重新激活连接失败"
      fi
      ;;
    netplan)
      log_info "应用 netplan 配置..."
      if ! netplan apply; then
        log_warn "netplan apply 失败"
      fi
      ;;
    resolv.conf)
      log_info "resolv.conf 直接生效，无需重载服务"
      ;;
  esac
}

# 验证系统 DNS 是否生效（走系统 resolver，而非指定 @server）
verify_system_dns() {
  sleep 1
  if ! command -v dig &>/dev/null; then
    return 0
  fi
  log_info "验证系统 DNS 解析..."
  if dig +short +time=3 +tries=1 "$DOMAIN" &>/dev/null; then
    log_success "系统 DNS 解析验证通过"
  else
    log_warn "系统 DNS 解析验证失败，请检查配置"
  fi
}

# ============================================================
# DNS 应用功能
# ============================================================

apply_temp() {
  local dns_ip="$1"
  local iface

  case "$DNS_BACKEND_TEMP" in
    systemd-resolved)
      iface=$(get_primary_interface)
      if [[ -z "$iface" ]]; then
        log_error "无法获取主网络接口"
        return 1
      fi
      log_info "通过 resolvectl 临时设置 DNS (接口: $iface)..."
      if ! resolvectl dns "$iface" "$dns_ip"; then
        log_error "resolvectl 设置 DNS 失败"
        return 1
      fi
      ;;
    networkmanager)
      log_info "临时修改 DNS (NetworkManager 重启后恢复)..."
      local resolv_symlink_target=""
      if [[ -L /etc/resolv.conf ]]; then
        resolv_symlink_target=$(readlink -f /etc/resolv.conf 2>/dev/null)
        if [[ "$resolv_symlink_target" == *"systemd"* ]] || [[ "$resolv_symlink_target" == *"stub"* ]]; then
          log_warn "/etc/resolv.conf 是 systemd 符号链接，使用 resolvectl 替代"
          iface=$(get_primary_interface)
          if [[ -n "$iface" ]]; then
            if resolvectl dns "$iface" "$dns_ip" 2>/dev/null; then
              return 0
            fi
          fi
          log_warn "resolvectl 失败，回退到直接写入"
        fi
      fi
      if ! safe_write_resolv_conf "$dns_ip"; then
        log_error "写入 resolv.conf 失败"
        return 1
      fi
      ;;
    resolv.conf)
      log_info "临时修改 /etc/resolv.conf..."
      if ! safe_write_resolv_conf "$dns_ip"; then
        log_error "写入 resolv.conf 失败"
        return 1
      fi
      ;;
  esac

  return 0
}

apply_perm() {
  local dns_ip="$1"

  # v3.0.0 起：不再分后端各写各的（netplan / systemd-resolved / NetworkManager）。
  # 无论系统原本用什么 DNS 管理器，一律停用它们并接管为「静态 /etc/resolv.conf」，
  # 这样系统所有解析都直接走指定的 AKDNS，确保流媒体解锁一定生效。
  # 原配置已在调用前完整备份，可随时通过菜单「还原 DNS 配置」一键回滚。
  if [[ "$DNS_BACKEND_PERM" != "resolv.conf" ]]; then
    log_info "检测到 DNS 后端: $DNS_BACKEND_PERM → 将接管为 /etc/resolv.conf"
  fi

  force_static_resolv_conf "$dns_ip" || return 1

  return 0
}

# ============================================================
# 测速逻辑
# ============================================================

run_speed_test() {
  if ! command -v dig &>/dev/null; then
    log_error "未找到 dig 命令"
    case "$DISTRO_ID" in
      ubuntu|debian)   log_info "请安装: sudo apt install dnsutils" ;;
      centos|rhel|fedora|rocky|alma) log_info "请安装: sudo yum install bind-utils" ;;
      arch|manjaro)    log_info "请安装: sudo pacman -S bind" ;;
      alpine)          log_info "请安装: sudo apk add bind-tools" ;;
      opensuse*)       log_info "请安装: sudo zypper install bind-utils" ;;
      *)               log_info "请安装 dig (通常在 dnsutils 或 bind-utils 包中)" ;;
    esac
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d) || { log_error "无法创建临时目录"; return 1; }

  # 确保函数退出时清理临时目录
  trap 'rm -rf "$tmpdir"' RETURN

  echo ""
  printf '%b\n' "${BOLD}AKDNS 测速${NC}"
  echo "域名   : $DOMAIN"
  echo "次数   : $COUNT"
  echo "超时   : ${TIMEOUT}s"
  echo "------------------------------------"
  echo "正在测速，请稍候..."

  # 每个子进程写独立文件，避免并发写同一文件
  for dns in "${DNS_LIST[@]}"; do
    for ((i = 1; i <= COUNT; i++)); do
      (
        local t
        t=$(dig @"$dns" "$DOMAIN" +stats +time="$TIMEOUT" +tries=1 2>/dev/null \
          | awk '/Query time/ {print $4}')
        if [[ -n "$t" ]]; then
          echo "$dns $t"
        else
          echo "$dns 1000"
        fi
      ) > "$tmpdir/result_${dns}_${i}" &
    done
  done

  wait

  # 汇总所有结果文件
  cat "$tmpdir"/result_* > "$tmpdir/result" 2>/dev/null

  if [[ ! -s "$tmpdir/result" ]]; then
    log_error "测速失败，未获取到任何结果"
    rm -rf "$tmpdir"
    return 1
  fi

  echo ""
  printf '%b\n' "${BOLD}AKDNS 节点连通性 / 平均延迟:${NC}"
  echo "------------------------------------"

  local result
  result=$(awk '
  {
    sum[$1] += $2
    cnt[$1]++
  }
  END {
    for (dns in sum) {
      avg = sum[dns] / cnt[dns]
      printf "%d %s\n", avg, dns
    }
  }
  ' "$tmpdir/result" | sort -n)

  # avg>=1000 视为该次全部超时，标记为不可达
  echo "$result" | awk '{
    if ($1 + 0 >= 1000) printf "  %-18s %s\n", $2, "超时 / 不可达 ✗";
    else                printf "  %-18s %s ms  ✓\n", $2, $1;
  }'

  # 检查最佳 DNS 是否全部超时（avg >= 1000 表示全部失败）
  local best_avg best_dns
  best_avg=$(echo "$result" | head -n1 | awk '{print $1}')
  best_dns=$(echo "$result" | head -n1 | awk '{print $2}')

  if [[ -z "$best_dns" ]] || (( best_avg >= 1000 )); then
    echo "------------------------------------"
    log_error "所有 DNS 测速均超时，未能选出可用 DNS"
    BEST_DNS=""
    return 1
  fi

  BEST_DNS="$best_dns"

  echo "------------------------------------"
  printf '%b\n' "  最佳 DNS: ${GREEN}${BOLD}$BEST_DNS${NC} (${best_avg}ms)"
  echo ""
  log_info "可选择菜单 2 或 3 来应用此 DNS"
}

# ============================================================
# 菜单应用交互
# ============================================================

menu_apply() {
  local mode="$1"  # temp 或 perm
  local mode_name
  if [[ "$mode" == "temp" ]]; then
    mode_name="临时"
  else
    mode_name="永久"
  fi

  local target_dns="$BEST_DNS"

  if [[ -z "$target_dns" ]]; then
    echo ""
    log_warn "尚未进行测速"
    echo ""
    echo "  1) 先运行测速，使用最佳结果"
    echo "  2) 手动输入 DNS 地址"
    echo "  0) 返回菜单"
    echo ""
    local subchoice
    read -r -p "请选择 [0-2]: " subchoice
    case "$subchoice" in
      1)
        run_speed_test
        target_dns="$BEST_DNS"
        if [[ -z "$target_dns" ]]; then
          log_error "测速未获取到结果"
          return 1
        fi
        ;;
      2)
        read -r -p "请输入 DNS 地址: " target_dns
        if ! validate_ipv4 "$target_dns"; then
          log_error "无效的 IPv4 地址: $target_dns"
          return 1
        fi
        ;;
      *)
        return 0
        ;;
    esac
  fi

  echo ""
  printf '%b\n' "${BOLD}操作摘要:${NC}"
  echo "  模式   : ${mode_name}应用"
  echo "  DNS    : $target_dns"
  if [[ "$mode" == "temp" ]]; then
    echo "  后端   : $DNS_BACKEND_TEMP（重启后失效）"
  else
    echo "  当前后端 : $DNS_BACKEND_PERM"
    echo "  接管方式 : 停用上述管理器 → 直接写入 /etc/resolv.conf"
    if $LOCK_RESOLV_CONF; then
      echo "  防覆盖   : 锁定 /etc/resolv.conf (chattr +i)"
    fi
    echo ""
    printf '%b\n' "  ${YELLOW}说明：将统一接管系统 DNS，确保解析直达 AKDNS。${NC}"
    printf '%b\n' "  ${YELLOW}原配置会自动备份，可随时用菜单「还原 DNS 配置」一键回滚。${NC}"
  fi
  echo ""

  if ! confirm_action "确认${mode_name}应用 DNS $target_dns?"; then
    log_info "取消操作"
    return 0
  fi

  require_root || return 1

  # 自动备份
  log_info "自动备份当前配置..."
  if ! do_backup "pre-apply-${mode}"; then
    log_error "备份当前配置失败，为安全起见中止应用"
    return 1
  fi

  # 执行应用
  if [[ "$mode" == "temp" ]]; then
    apply_temp "$target_dns"
  else
    apply_perm "$target_dns"
  fi

  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    # 使用系统 resolver 验证（而非指定 @server）
    verify_system_dns

    # 额外验证：检查配置是否实际写入
    echo ""
    log_info "当前生效 DNS: $(get_current_dns)"
  else
    log_error "DNS 应用失败"
  fi

  return $exit_code
}

# 一键：测速选最优 → 接管为系统 DNS（步骤③+④串联）
run_test_and_apply() {
  run_speed_test || return 1
  if [[ -z "$BEST_DNS" ]]; then
    log_error "未选出可用 DNS，已中止"
    return 1
  fi
  echo ""
  log_info "即将把最优 DNS（$BEST_DNS）接管为系统 DNS..."
  menu_apply perm
}

# ============================================================
# 流媒体解锁检测
# ============================================================

run_unlock_check() {
  if ! command -v curl &>/dev/null; then
    log_error "未找到 curl 命令，无法下载解锁检测脚本"
    case "$DISTRO_ID" in
      ubuntu|debian)   log_info "请安装: sudo apt install curl" ;;
      centos|rhel|fedora|rocky|alma) log_info "请安装: sudo yum install curl" ;;
      arch|manjaro)    log_info "请安装: sudo pacman -S curl" ;;
      alpine)          log_info "请安装: sudo apk add curl" ;;
      *)               log_info "请安装 curl" ;;
    esac
    return 1
  fi

  local script_url="https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh"
  local tmp_script
  tmp_script=$(mktemp /tmp/akdns-unlock-check.XXXXXX) || { log_error "无法创建临时文件"; return 1; }

  # 确保退出时清理临时文件
  trap 'rm -f "$tmp_script"' RETURN

  log_info "正在下载解锁检测脚本..."
  if ! curl -L -s --fail --connect-timeout 10 --max-time 30 "$script_url" -o "$tmp_script"; then
    log_error "下载解锁检测脚本失败，请检查网络连接"
    return 1
  fi

  # 验证下载内容非空
  if [[ ! -s "$tmp_script" ]]; then
    log_error "下载的脚本内容为空"
    return 1
  fi

  echo ""
  bash "$tmp_script" -M 4
  local exit_code=$?
  echo ""
  if [[ $exit_code -eq 0 ]]; then
    log_success "解锁检测完成"
  else
    log_warn "解锁检测脚本退出码: $exit_code"
  fi

  echo ""
  printf '%b\n' "${BOLD}下一步：${NC}"
  echo "  · 若未解锁 → 回到控制台为本机 IP 勾选要解锁的服务与节点，"
  echo "    然后重新运行本项「流媒体解锁检测」复测。"
  echo "  · 控制台： $CONSOLE_URL"
}

# ============================================================
# 状态查看
# ============================================================

show_status() {
  echo ""
  printf '%b\n' "${BOLD}====== AKDNS 系统状态 ======${NC}"
  echo ""
  printf "  %-16s %s\n" "发行版:" "$DISTRO_NAME $DISTRO_VERSION"
  printf "  %-16s %s\n" "发行版 ID:" "$DISTRO_ID"
  printf "  %-16s %s\n" "init 系统:" "$INIT_SYSTEM"
  printf "  %-16s %s\n" "DNS 后端(临时):" "$DNS_BACKEND_TEMP"
  printf "  %-16s %s\n" "DNS 后端(永久):" "$DNS_BACKEND_PERM"
  printf "  %-16s %s\n" "当前 DNS:" "$(get_current_dns)"
  printf "  %-16s %s\n" "主网络接口:" "$(get_primary_interface)"

  # 备份信息
  if [[ -d "$BACKUP_DIR" ]]; then
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    printf "  %-16s %s\n" "备份数量:" "$backup_count"
    if (( backup_count > 0 )); then
      local latest
      latest=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)
      if [[ -f "$latest/metadata.txt" ]]; then
        local ts
        ts=$(grep '^timestamp=' "$latest/metadata.txt" | cut -d= -f2-)
        printf "  %-16s %s\n" "最近备份:" "$ts"
      fi
    fi
  else
    printf "  %-16s %s\n" "备份数量:" "0 (目录未创建)"
  fi

  # 缓存的测速结果
  if [[ -n "$BEST_DNS" ]]; then
    printf "  %-16s %s\n" "最佳 DNS(缓存):" "$BEST_DNS"
  fi

  echo ""
  printf '%b\n' "${BOLD}============================${NC}"
}

# ============================================================
# Banner 与菜单
# ============================================================

show_banner() {
  echo ""
  printf '%b' "${CYAN}${BOLD}"
  echo "     _    _  ______  _   _  _____ "
  echo "    / \\  | |/ /  _ \\| \\ | |/ ____|"
  echo "   / _ \\ | ' /| | | |  \\| | (___  "
  echo "  / ___ \\| . \\| |_| | |\\  |\\___ \\ "
  echo " /_/   \\_\\_|\\_\\____/|_| \\_|____) |"
  echo "                                   "
  printf '%b\n' "${NC}"
  printf '%b\n' " ${BOLD}AKDNS v${VERSION}${NC} - 智能 DNS 测速与系统接管工具"
  echo " ========================================="
  printf '%b\n' " 系统       : ${GREEN}$DISTRO_NAME $DISTRO_VERSION${NC}"
  echo " init       : $INIT_SYSTEM"
  echo " 当前 DNS 后端 : $DNS_BACKEND_PERM"
  echo " 当前 DNS   : $(get_current_dns)"
  printf '%b\n' " 接管目标   : ${GREEN}直接读取 /etc/resolv.conf${NC}（设为系统 DNS 时生效）"
  echo " ========================================="
}

show_menu() {
  echo ""
  printf '%b\n' " ${BOLD}推荐流程:${NC} ①控制台添加本机 IP → ②测解锁(基线) → ③测 DNS → ④设为系统 DNS → ⑤控制台配置分服务 → ⑥复测解锁"
  echo ""
  printf '%b\n' " ${BOLD}请选择操作:${NC}"
  echo ""
  printf '%b\n' "  ${GREEN}1)${NC} 流媒体解锁检测                    ${CYAN}(步骤 ②/⑥)${NC}"
  printf '%b\n' "  ${GREEN}2)${NC} DNS 测速 / 连通性测试              ${CYAN}(步骤 ③)${NC}"
  printf '%b\n' "  ${GREEN}3)${NC} 设为系统 DNS (永久·接管 resolv.conf) ${CYAN}(步骤 ④)${NC}"
  printf '%b\n' "  ${GREEN}4)${NC} 一键: 测速并设为系统 DNS          ${CYAN}(③+④)${NC}"
  echo ""
  printf '%b\n' "  ${GREEN}5)${NC} 临时设置 DNS (重启失效)"
  printf '%b\n' "  ${GREEN}6)${NC} 备份当前 DNS 配置"
  printf '%b\n' "  ${GREEN}7)${NC} 还原 DNS 配置 (撤销接管 / 回滚)"
  printf '%b\n' "  ${GREEN}8)${NC} 查看当前状态"
  printf '%b\n' "  ${RED}0)${NC} 退出"
  echo ""
}

# ============================================================
# 主入口
# ============================================================

main() {
  # 处理命令行参数
  case "${1:-}" in
    --help|-h)
      echo "AKDNS v$VERSION - 智能 DNS 测速与系统接管工具"
      echo ""
      echo "测试 DNS 连通性 → 选出最优 AKDNS → 接管系统 DNS。"
      echo "无论 netplan / systemd-resolved / NetworkManager / resolvconf，"
      echo "一律收敛为「直接读取 /etc/resolv.conf」，确保流媒体解锁一定生效。"
      echo ""
      echo "用法: $(basename "$0") [选项]"
      echo ""
      echo "选项:"
      echo "  --help, -h       显示帮助信息"
      echo "  --version, -v    显示版本号"
      echo ""
      echo "无参数运行时进入交互式菜单模式。"
      echo "原 DNS 配置会在接管前自动备份，可用菜单「还原 DNS 配置」一键回滚。"
      exit 0
      ;;
    --version|-v)
      echo "akdns v$VERSION"
      exit 0
      ;;
    "")
      # 进入菜单模式
      ;;
    *)
      echo "未知参数: $1"
      echo "使用 --help 查看帮助"
      exit 1
      ;;
  esac

  # 初始化：检测系统信息
  detect_distro
  detect_init_system
  detect_dns_backend

  # 支持 wget ... | bash 管道调用：将 stdin 重定向回终端
  # 管道模式下 stdin 是脚本内容，read 无法获取用户输入
  if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty ]]; then
      exec < /dev/tty || { log_error "无法获取终端输入，请改用: bash <(wget -qO- URL)"; exit 1; }
    else
      log_error "未检测到可用终端，无法进入交互模式"
      log_info "请直接运行脚本文件: bash akdns.sh"
      exit 1
    fi
  fi

  while true; do
    clear
    show_banner
    show_menu
    local choice
    read -r -p " 请选择 [0-8]: " choice
    case "$choice" in
      1) run_unlock_check ;;
      2) run_speed_test ;;
      3) menu_apply perm ;;
      4) run_test_and_apply ;;
      5) menu_apply temp ;;
      6)
        require_root && do_backup "manual"
        ;;
      7) do_restore ;;
      8) show_status ;;
      0)
        clear
        log_info "再见！"
        exit 0
        ;;
      *)
        log_warn "无效选择，请输入 0-8"
        ;;
    esac
    press_enter
  done
}

main "$@"
