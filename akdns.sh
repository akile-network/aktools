#!/usr/bin/env bash
# ============================================================
# AKDNS v3.0.0 - 智能 DNS 测速与系统接管工具
# 测试 DNS 连通性 → 选出最优 AKDNS → 接管系统 DNS
# 不论 netplan / systemd-resolved / NetworkManager / resolvconf，
# 一律收敛为「直接读取 /etc/resolv.conf」，确保解锁一定生效。
# 支持 Linux 系统识别、自动备份与一键还原。
# 界面支持中文 / English（自动检测 $LANG，可菜单或 --lang 切换）。
# ============================================================

set -uo pipefail

# 多语言依赖关联数组（associative array），需要 bash 4.0+
if [[ -z "${BASH_VERSINFO:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
  echo "AKDNS requires bash 4.0+ (associative arrays)。本脚本需要 bash 4.0 及以上版本。" >&2
  exit 1
fi

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

# AKDNS 控制台地址（用于脚本内提示）
CONSOLE_URL="https://dns.akile.ai/console"
AKDNS_TG_URL="https://t.me/+MEKKEBUkW6ZjMzBl"

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
# 当 UDP 测速全部超时时自动置 true：应用时写入 `options use-vc` 强制走 TCP
DNS_USE_TCP=false
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
# 多语言 i18n（zh / en）
# ============================================================

# 当前界面语言：zh 或 en（detect_language 设定，菜单 / --lang 可切换）
UI_LANG="en"

# 语言持久化文件：记住用户手动选择的语言
LANG_STATE_FILE="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/akdns/lang"

# 消息目录：键为 "<lang>.<id>"
declare -A MSG

# ---- 日志标签 ----
MSG[zh.tag_info]="信息";    MSG[en.tag_info]="INFO"
MSG[zh.tag_ok]="成功";      MSG[en.tag_ok]="OK"
MSG[zh.tag_warn]="警告";    MSG[en.tag_warn]="WARN"
MSG[zh.tag_error]="错误";   MSG[en.tag_error]="ERROR"

# ---- 通用 ----
MSG[zh.need_root]="此操作需要 root 权限，请使用 sudo 运行"
MSG[en.need_root]="This operation requires root privileges. Please run with sudo."
MSG[zh.cmd_not_found]="未找到命令: %s，请先安装 %s"
MSG[en.cmd_not_found]="Command not found: %s. Please install %s first."
MSG[zh.confirm_default]="确认执行?"
MSG[en.confirm_default]="Proceed?"
MSG[zh.press_enter_prompt]="按回车键返回菜单..."
MSG[en.press_enter_prompt]="Press Enter to return to the menu..."
MSG[zh.unknown]="未知"
MSG[en.unknown]="unknown"
MSG[zh.back]="返回"
MSG[en.back]="Back"

# ---- safe_write_resolv_conf / 锁定 ----
MSG[zh.swrc_restored_symlink]="已恢复 resolv.conf 符号链接 → %s"
MSG[en.swrc_restored_symlink]="Restored resolv.conf symlink → %s"
MSG[zh.immutable_detected_remove]="检测到 immutable 标志，临时移除..."
MSG[en.immutable_detected_remove]="Immutable flag detected; removing it temporarily..."
MSG[zh.immutable_remove_fail]="无法移除 immutable 标志"
MSG[en.immutable_remove_fail]="Failed to remove the immutable flag"
MSG[zh.resolv_is_symlink_del]="/etc/resolv.conf 是 systemd 符号链接，删除后直接写入"
MSG[en.resolv_is_symlink_del]="/etc/resolv.conf is a systemd symlink; removing it to write directly"
MSG[zh.symlink_del_fail]="无法删除 resolv.conf 符号链接"
MSG[en.symlink_del_fail]="Failed to remove the resolv.conf symlink"
MSG[zh.mktemp_fail]="无法创建临时文件"
MSG[en.mktemp_fail]="Failed to create a temporary file"
MSG[zh.tmpfile_security_fail]="临时文件安全检查失败"
MSG[en.tmpfile_security_fail]="Temporary file security check failed"
MSG[zh.use_vc_written]="已写入 options use-vc：强制 DNS 走 TCP"
MSG[en.use_vc_written]="Wrote 'options use-vc': forcing DNS over TCP"
MSG[zh.chmod_tmp_fail]="无法设置临时文件权限"
MSG[en.chmod_tmp_fail]="Failed to set temporary file permissions"
MSG[zh.mv_resolv_fail]="无法替换 resolv.conf"
MSG[en.mv_resolv_fail]="Failed to replace resolv.conf"
MSG[zh.resolv_verify_fail]="resolv.conf 写入验证失败"
MSG[en.resolv_verify_fail]="resolv.conf write verification failed"
MSG[zh.locked_resolv]="已锁定 /etc/resolv.conf（防止被覆盖；还原时会自动解锁）"
MSG[en.locked_resolv]="Locked /etc/resolv.conf (prevents overwrite; auto-unlocked on restore)"
MSG[zh.unlocked_resolv]="已解除 /etc/resolv.conf 锁定"
MSG[en.unlocked_resolv]="Unlocked /etc/resolv.conf"

# ---- nsswitch / 接管管理器 ----
MSG[zh.nsswitch_add_dns]="nsswitch.conf 缺少 dns，自动补充以确保读取 resolv.conf..."
MSG[en.nsswitch_add_dns]="nsswitch.conf is missing 'dns'; adding it so resolv.conf is consulted..."
MSG[zh.disable_resolved]="停用 systemd-resolved（接管 DNS）..."
MSG[en.disable_resolved]="Disabling systemd-resolved (taking over DNS)..."
MSG[zh.disable_resolved_fail]="停用 systemd-resolved 失败，将依赖 resolv.conf 锁定兜底"
MSG[en.disable_resolved_fail]="Failed to disable systemd-resolved; relying on the resolv.conf lock as a fallback"
MSG[zh.nm_dns_none]="已让 NetworkManager 放手 resolv.conf (dns=none)"
MSG[en.nm_dns_none]="Set NetworkManager to release resolv.conf (dns=none)"
MSG[zh.disable_resolvconf]="停用 resolvconf 服务..."
MSG[en.disable_resolvconf]="Disabling the resolvconf service..."
MSG[zh.takeover_start]="接管系统 DNS：统一改为直接读取 /etc/resolv.conf..."
MSG[en.takeover_start]="Taking over system DNS: switching to read /etc/resolv.conf directly..."
MSG[zh.write_resolv_fail]="写入 resolv.conf 失败"
MSG[en.write_resolv_fail]="Failed to write resolv.conf"

# ---- 系统识别 ----
MSG[zh.detected_system]="检测到系统: %s %s"
MSG[en.detected_system]="Detected system: %s %s"
MSG[zh.init_system_is]="init 系统: %s"
MSG[en.init_system_is]="init system: %s"
MSG[zh.dns_backend_is]="DNS 后端: 临时=%s, 永久=%s"
MSG[en.dns_backend_is]="DNS backend: temp=%s, perm=%s"

# ---- 备份 ----
MSG[zh.backup_dir_fail]="无法创建备份目录: %s"
MSG[en.backup_dir_fail]="Failed to create backup directory: %s"
MSG[zh.backup_mkdir_fail]="无法创建备份目录"
MSG[en.backup_mkdir_fail]="Failed to create backup directory"
MSG[zh.backup_done]="备份完成: %s"
MSG[en.backup_done]="Backup complete: %s"

# ---- 还原 / 列表 ----
MSG[zh.no_backups_dir]="未找到任何备份 (目录不存在: %s)"
MSG[en.no_backups_dir]="No backups found (directory does not exist: %s)"
MSG[zh.no_backups]="未找到任何备份"
MSG[en.no_backups]="No backups found"
MSG[zh.avail_backups]="可用备份列表:"
MSG[en.avail_backups]="Available backups:"
MSG[zh.col_no]="编号";   MSG[en.col_no]="No."
MSG[zh.col_time]="时间"; MSG[en.col_time]="Time"
MSG[zh.col_tag]="标签";  MSG[en.col_tag]="Tag"
MSG[zh.col_dns]="DNS";   MSG[en.col_dns]="DNS"
MSG[zh.meta_missing]="元数据缺失"
MSG[en.meta_missing]="metadata missing"
MSG[zh.restore_prompt]="请输入要还原的备份编号 (0 取消): "
MSG[en.restore_prompt]="Enter the backup number to restore (0 to cancel): "
MSG[zh.cancel_restore]="取消还原"
MSG[en.cancel_restore]="Restore canceled"
MSG[zh.invalid_number]="无效的编号: %s"
MSG[en.invalid_number]="Invalid number: %s"
MSG[zh.confirm_restore]="确认从 %s 还原 DNS 配置?"
MSG[en.confirm_restore]="Restore DNS configuration from %s?"
MSG[zh.pre_restore_backup]="还原前自动备份当前配置..."
MSG[en.pre_restore_backup]="Backing up the current configuration before restore..."
MSG[zh.pre_restore_backup_fail]="备份当前配置失败，为安全起见中止还原"
MSG[en.pre_restore_backup_fail]="Failed to back up the current config; aborting restore for safety"
MSG[zh.removed_nm_dns_none]="已移除 AKDNS 的 NetworkManager dns=none 配置"
MSG[en.removed_nm_dns_none]="Removed the AKDNS NetworkManager dns=none config"
MSG[zh.restore_immutable_detected]="检测到 resolv.conf immutable 标志，临时移除..."
MSG[en.restore_immutable_detected]="resolv.conf immutable flag detected; removing it temporarily..."
MSG[zh.restore_immutable_fail]="无法移除 immutable 标志，还原失败"
MSG[en.restore_immutable_fail]="Failed to remove the immutable flag; restore failed"
MSG[zh.restore_rm_resolv_fail]="无法移除现有 resolv.conf"
MSG[en.restore_rm_resolv_fail]="Failed to remove the existing resolv.conf"
MSG[zh.restored_resolv]="已还原 /etc/resolv.conf"
MSG[en.restored_resolv]="Restored /etc/resolv.conf"
MSG[zh.restore_resolv_fail]="还原 resolv.conf 失败"
MSG[en.restore_resolv_fail]="Failed to restore resolv.conf"
MSG[zh.restored_resolved_conf]="已还原 /etc/systemd/resolved.conf"
MSG[en.restored_resolved_conf]="Restored /etc/systemd/resolved.conf"
MSG[zh.restore_resolved_conf_fail]="还原 resolved.conf 失败"
MSG[en.restore_resolved_conf_fail]="Failed to restore resolved.conf"
MSG[zh.restored_resolved_dropin]="已还原 resolved.conf.d drop-in"
MSG[en.restored_resolved_dropin]="Restored the resolved.conf.d drop-in"
MSG[zh.restore_resolved_dropin_fail]="还原 resolved.conf.d drop-in 失败"
MSG[en.restore_resolved_dropin_fail]="Failed to restore the resolved.conf.d drop-in"
MSG[zh.restored_nm_conf]="已还原 NetworkManager 配置文件"
MSG[en.restored_nm_conf]="Restored NetworkManager config files"
MSG[zh.restore_nm_conf_fail]="还原 NetworkManager 配置文件失败"
MSG[en.restore_nm_conf_fail]="Failed to restore NetworkManager config files"
MSG[zh.restore_nm_dns_fail]="还原 NM DNS 设置失败"
MSG[en.restore_nm_dns_fail]="Failed to restore the NM DNS settings"
MSG[zh.restored_nm_dns]="已还原 NetworkManager 连接 DNS 设置 (UUID: %s)"
MSG[en.restored_nm_dns]="Restored NetworkManager connection DNS settings (UUID: %s)"
MSG[zh.restored_netplan]="已还原 netplan 配置"
MSG[en.restored_netplan]="Restored the netplan configuration"
MSG[zh.restore_netplan_fail]="还原 netplan 配置失败"
MSG[en.restore_netplan_fail]="Failed to restore the netplan configuration"
MSG[zh.restored_nsswitch]="已还原 /etc/nsswitch.conf"
MSG[en.restored_nsswitch]="Restored /etc/nsswitch.conf"
MSG[zh.reenable_resolved]="重新启用 systemd-resolved..."
MSG[en.reenable_resolved]="Re-enabling systemd-resolved..."
MSG[zh.resolved_start_fail]="systemd-resolved 启动失败，请手动检查"
MSG[en.resolved_start_fail]="systemd-resolved failed to start; please check manually"
MSG[zh.reenable_resolvconf]="重新启用 resolvconf..."
MSG[en.reenable_resolvconf]="Re-enabling resolvconf..."
MSG[zh.restore_ok_verified]="DNS 配置已还原并验证通过"
MSG[en.restore_ok_verified]="DNS configuration restored and verified"
MSG[zh.restore_ok_unverified]="DNS 配置已还原，但验证未通过，请手动检查"
MSG[en.restore_ok_unverified]="DNS configuration restored, but verification failed; please check manually"

# ---- reload_dns_service ----
MSG[zh.systemctl_unavailable_resolved]="systemctl 不可用，无法重启 systemd-resolved"
MSG[en.systemctl_unavailable_resolved]="systemctl unavailable; cannot restart systemd-resolved"
MSG[zh.restart_resolved]="重启 systemd-resolved..."
MSG[en.restart_resolved]="Restarting systemd-resolved..."
MSG[zh.restart_resolved_fail]="systemd-resolved 重启失败"
MSG[en.restart_resolved_fail]="Failed to restart systemd-resolved"
MSG[zh.reload_nm]="重载 NetworkManager..."
MSG[en.reload_nm]="Reloading NetworkManager..."
MSG[zh.reload_nm_fail]="NetworkManager 重载失败"
MSG[en.reload_nm_fail]="Failed to reload NetworkManager"
MSG[zh.nm_reactivate_fail]="重新激活连接失败"
MSG[en.nm_reactivate_fail]="Failed to reactivate the connection"
MSG[zh.apply_netplan]="应用 netplan 配置..."
MSG[en.apply_netplan]="Applying the netplan configuration..."
MSG[zh.apply_netplan_fail]="netplan apply 失败"
MSG[en.apply_netplan_fail]="netplan apply failed"
MSG[zh.resolv_no_reload]="resolv.conf 直接生效，无需重载服务"
MSG[en.resolv_no_reload]="resolv.conf takes effect directly; no service reload needed"

# ---- 验证 ----
MSG[zh.verify_dns]="验证系统 DNS 解析..."
MSG[en.verify_dns]="Verifying system DNS resolution..."
MSG[zh.tcp_paren]="（TCP）"
MSG[en.tcp_paren]=" (TCP)"
MSG[zh.verify_ok]="系统 DNS 解析验证通过%s"
MSG[en.verify_ok]="System DNS resolution verified%s"
MSG[zh.verify_fail]="系统 DNS 解析验证失败，请检查配置"
MSG[en.verify_fail]="System DNS resolution check failed; please verify the configuration"

# ---- 应用 ----
MSG[zh.no_primary_iface]="无法获取主网络接口"
MSG[en.no_primary_iface]="Could not determine the primary network interface"
MSG[zh.resolvectl_set]="通过 resolvectl 临时设置 DNS (接口: %s)..."
MSG[en.resolvectl_set]="Setting DNS temporarily via resolvectl (interface: %s)..."
MSG[zh.resolvectl_set_fail]="resolvectl 设置 DNS 失败"
MSG[en.resolvectl_set_fail]="resolvectl failed to set DNS"
MSG[zh.temp_nm_note]="临时修改 DNS (NetworkManager 重启后恢复)..."
MSG[en.temp_nm_note]="Changing DNS temporarily (NetworkManager reverts after a restart)..."
MSG[zh.resolv_symlink_use_resolvectl]="/etc/resolv.conf 是 systemd 符号链接，使用 resolvectl 替代"
MSG[en.resolv_symlink_use_resolvectl]="/etc/resolv.conf is a systemd symlink; using resolvectl instead"
MSG[zh.resolvectl_fail_fallback]="resolvectl 失败，回退到直接写入"
MSG[en.resolvectl_fail_fallback]="resolvectl failed; falling back to a direct write"
MSG[zh.temp_edit_resolv]="临时修改 /etc/resolv.conf..."
MSG[en.temp_edit_resolv]="Temporarily editing /etc/resolv.conf..."
MSG[zh.detected_backend_takeover]="检测到 DNS 后端: %s → 将接管为 /etc/resolv.conf"
MSG[en.detected_backend_takeover]="Detected DNS backend: %s → will take over via /etc/resolv.conf"

# ---- 测速 ----
MSG[zh.dig_not_found]="未找到 dig 命令"
MSG[en.dig_not_found]="The 'dig' command was not found"
MSG[zh.please_install]="请安装: %s"
MSG[en.please_install]="Please install: %s"
MSG[zh.please_install_dig_generic]="请安装 dig (通常在 dnsutils 或 bind-utils 包中)"
MSG[en.please_install_dig_generic]="Please install dig (usually in the dnsutils or bind-utils package)"
MSG[zh.speed_test_title]="AKDNS 测速"
MSG[en.speed_test_title]="AKDNS Speed Test"
MSG[zh.label_domain]="域名"
MSG[en.label_domain]="Domain"
MSG[zh.label_count]="次数"
MSG[en.label_count]="Count"
MSG[zh.label_timeout]="超时"
MSG[en.label_timeout]="Timeout"
MSG[zh.testing_udp]="正在测试 UDP DNS 连通性，请稍候..."
MSG[en.testing_udp]="Testing UDP DNS connectivity, please wait..."
MSG[zh.udp_all_timeout_try_tcp]="UDP DNS 全部超时，尝试改用 TCP 重新测试..."
MSG[en.udp_all_timeout_try_tcp]="All UDP DNS timed out; retrying over TCP..."
MSG[zh.testing_tcp]="正在测试 TCP DNS 连通性，请稍候..."
MSG[en.testing_tcp]="Testing TCP DNS connectivity, please wait..."
MSG[zh.tcp_available]="TCP DNS 可用，将以 TCP 模式应用（写入 options use-vc）"
MSG[en.tcp_available]="TCP DNS available; will apply in TCP mode (writes 'options use-vc')"
MSG[zh.alpine_musl_warn]="检测到 Alpine/musl：musl libc 可能不支持 options use-vc，强制 TCP 或不生效"
MSG[en.alpine_musl_warn]="Alpine/musl detected: musl libc may not support 'options use-vc'; forced TCP may not take effect"
MSG[zh.node_latency_header]="AKDNS 节点连通性 / 平均延迟（%s）:"
MSG[en.node_latency_header]="AKDNS node connectivity / average latency (%s):"
MSG[zh.node_timeout]="超时 / 不可达 ✗"
MSG[en.node_timeout]="timeout / unreachable ✗"
MSG[zh.both_timeout]="UDP 与 TCP 测速均超时，未能选出可用 DNS"
MSG[en.both_timeout]="Both UDP and TCP timed out; no usable DNS selected"
MSG[zh.best_dns_label]="最佳 DNS"
MSG[en.best_dns_label]="Best DNS"
MSG[zh.transport_forced_tcp]="传输方式: 强制 TCP —— 应用时会写入 options use-vc"
MSG[en.transport_forced_tcp]="Transport: forced TCP — 'options use-vc' will be written on apply"
MSG[zh.speed_hint_next]="可选择菜单 3（设为系统 DNS）或 4（一键测速并应用）"
MSG[en.speed_hint_next]="Tip: choose menu 3 (set as system DNS) or 4 (one-click test & apply)"

# ---- menu_apply ----
MSG[zh.mode_temp]="临时";  MSG[en.mode_temp]="Temporary"
MSG[zh.mode_perm]="永久";  MSG[en.mode_perm]="Permanent"
MSG[zh.not_tested_yet]="尚未进行测速"
MSG[en.not_tested_yet]="No speed test has been run yet"
MSG[zh.subopt_run_test]="先运行测速，使用最佳结果"
MSG[en.subopt_run_test]="Run a speed test first and use the best result"
MSG[zh.subopt_manual_dns]="手动输入 DNS 地址"
MSG[en.subopt_manual_dns]="Enter a DNS address manually"
MSG[zh.subopt_back]="返回菜单"
MSG[en.subopt_back]="Back to menu"
MSG[zh.select_0_2]="请选择 [0-2]: "
MSG[en.select_0_2]="Choose [0-2]: "
MSG[zh.speed_test_no_result]="测速未获取到结果"
MSG[en.speed_test_no_result]="The speed test returned no result"
MSG[zh.enter_dns]="请输入 DNS 地址: "
MSG[en.enter_dns]="Enter a DNS address: "
MSG[zh.invalid_ipv4]="无效的 IPv4 地址: %s"
MSG[en.invalid_ipv4]="Invalid IPv4 address: %s"
MSG[zh.op_summary]="操作摘要:"
MSG[en.op_summary]="Summary:"
MSG[zh.sum_mode]="模式"
MSG[en.sum_mode]="Mode"
MSG[zh.summary_mode_value]="%s应用"
MSG[en.summary_mode_value]="%s apply"
MSG[zh.sum_dns]="DNS"
MSG[en.sum_dns]="DNS"
MSG[zh.backend_label]="后端"
MSG[en.backend_label]="Backend"
MSG[zh.backend_temp_expire]="%s（重启后失效）"
MSG[en.backend_temp_expire]="%s (reverts after reboot)"
MSG[zh.cur_backend_label]="当前后端"
MSG[en.cur_backend_label]="Current backend"
MSG[zh.takeover_method_label]="接管方式"
MSG[en.takeover_method_label]="Takeover"
MSG[zh.takeover_method_value]="停用上述管理器 → 直接写入 /etc/resolv.conf"
MSG[en.takeover_method_value]="Disable the managers above → write /etc/resolv.conf directly"
MSG[zh.transport_label]="传输方式"
MSG[en.transport_label]="Transport"
MSG[zh.transport_forced_tcp_value]="强制 TCP (options use-vc) —— UDP 已全部超时"
MSG[en.transport_forced_tcp_value]="Forced TCP (options use-vc) — all UDP timed out"
MSG[zh.antioverwrite_label]="防覆盖"
MSG[en.antioverwrite_label]="Anti-overwrite"
MSG[zh.antioverwrite_value]="锁定 /etc/resolv.conf (chattr +i)"
MSG[en.antioverwrite_value]="Lock /etc/resolv.conf (chattr +i)"
MSG[zh.takeover_note1]="说明：将统一接管系统 DNS，确保解析直达 AKDNS。"
MSG[en.takeover_note1]="Note: this takes over system DNS so all resolution goes straight to AKDNS."
MSG[zh.takeover_note2]="原配置会自动备份，可随时用菜单「还原 DNS 配置」一键回滚。"
MSG[en.takeover_note2]="The original config is auto-backed up; use the \"Restore DNS configuration\" menu to roll back anytime."
MSG[zh.confirm_apply]="确认%s应用 DNS %s?"
MSG[en.confirm_apply]="Apply %s DNS %s?"
MSG[zh.cancel_op]="取消操作"
MSG[en.cancel_op]="Operation canceled"
MSG[zh.auto_backup_now]="自动备份当前配置..."
MSG[en.auto_backup_now]="Backing up the current configuration..."
MSG[zh.auto_backup_fail]="备份当前配置失败，为安全起见中止应用"
MSG[en.auto_backup_fail]="Failed to back up the current config; aborting apply for safety"
MSG[zh.current_effective_dns]="当前生效 DNS: %s"
MSG[en.current_effective_dns]="Current effective DNS: %s"
MSG[zh.apply_failed]="DNS 应用失败"
MSG[en.apply_failed]="Failed to apply DNS"
MSG[zh.no_dns_aborted]="未选出可用 DNS，已中止"
MSG[en.no_dns_aborted]="No usable DNS selected; aborted"
MSG[zh.about_to_takeover]="即将把最优 DNS（%s）接管为系统 DNS..."
MSG[en.about_to_takeover]="About to take over the best DNS (%s) as the system DNS..."

# ---- 流媒体解锁检测 ----
MSG[zh.curl_not_found]="未找到 curl 命令，无法下载解锁检测脚本"
MSG[en.curl_not_found]="The 'curl' command was not found; cannot download the unlock-check script"
MSG[zh.downloading_unlock]="正在下载解锁检测脚本..."
MSG[en.downloading_unlock]="Downloading the streaming unlock-check script..."
MSG[zh.unlock_third_party_notice]="提示：流媒体解锁检测使用第三方开源脚本（1-stream/RegionRestrictionCheck），检测脚本与结果非 AKDNS 官方。"
MSG[en.unlock_third_party_notice]="Notice: Streaming unlock check uses a third-party open-source script (1-stream/RegionRestrictionCheck); the script and results are not official AKDNS output."
MSG[zh.injecting_unlock_context]="正在向第三方检测脚本注入 AKDNS 信息..."
MSG[en.injecting_unlock_context]="Injecting AKDNS context into the third-party unlock-check script..."
MSG[zh.inject_unlock_context_fail]="注入 AKDNS 信息失败，已中止执行，避免运行未标注的第三方检测脚本"
MSG[en.inject_unlock_context_fail]="Failed to inject AKDNS context; aborted to avoid running an unlabelled third-party check script"
MSG[zh.download_unlock_fail]="下载解锁检测脚本失败，请检查网络连接"
MSG[en.download_unlock_fail]="Failed to download the unlock-check script; please check your network"
MSG[zh.download_empty]="下载的脚本内容为空"
MSG[en.download_empty]="The downloaded script is empty"
MSG[zh.unlock_done]="解锁检测完成"
MSG[en.unlock_done]="Unlock check complete"
MSG[zh.unlock_exit_code]="解锁检测脚本退出码: %s"
MSG[en.unlock_exit_code]="Unlock-check script exit code: %s"
MSG[zh.next_step_title]="下一步："
MSG[en.next_step_title]="Next steps:"
MSG[zh.unlock_next1]="· 若未解锁 → 回到控制台为本机 IP 勾选要解锁的服务与节点，"
MSG[en.unlock_next1]="· Not unlocked? → In the console, select the services and nodes to unlock for this IP,"
MSG[zh.unlock_next1b]="然后重新运行本项「流媒体解锁检测」复测。"
MSG[en.unlock_next1b]="then run \"Streaming unlock check\" again to re-test."
MSG[zh.unlock_console]="控制台： %s"
MSG[en.unlock_console]="Console: %s"

# ---- 状态 ----
MSG[zh.status_title]="AKDNS 系统状态"
MSG[en.status_title]="AKDNS System Status"
MSG[zh.st_distro]="发行版:";        MSG[en.st_distro]="Distro:"
MSG[zh.st_distro_id]="发行版 ID:";  MSG[en.st_distro_id]="Distro ID:"
MSG[zh.st_init]="init 系统:";       MSG[en.st_init]="init system:"
MSG[zh.st_backend_temp]="DNS 后端(临时):"; MSG[en.st_backend_temp]="DNS backend(temp):"
MSG[zh.st_backend_perm]="DNS 后端(永久):"; MSG[en.st_backend_perm]="DNS backend(perm):"
MSG[zh.st_cur_dns]="当前 DNS:";     MSG[en.st_cur_dns]="Current DNS:"
MSG[zh.st_iface]="主网络接口:";     MSG[en.st_iface]="Primary iface:"
MSG[zh.st_backup_count]="备份数量:"; MSG[en.st_backup_count]="Backup count:"
MSG[zh.st_backup_count_none]="0 (目录未创建)"
MSG[en.st_backup_count_none]="0 (directory not created)"
MSG[zh.st_last_backup]="最近备份:"; MSG[en.st_last_backup]="Last backup:"
MSG[zh.st_best_cached]="最佳 DNS(缓存):"; MSG[en.st_best_cached]="Best DNS(cached):"
MSG[zh.st_dns_transport]="DNS 传输:"; MSG[en.st_dns_transport]="DNS transport:"

# ---- Banner / 菜单 ----
MSG[zh.banner_subtitle]="智能 DNS 测速与系统接管工具"
MSG[en.banner_subtitle]="Smart DNS speed-test & system takeover tool"
MSG[zh.banner_system]="系统";          MSG[en.banner_system]="System"
MSG[zh.banner_cur_backend]="当前 DNS 后端"; MSG[en.banner_cur_backend]="DNS backend"
MSG[zh.banner_cur_dns]="当前 DNS";     MSG[en.banner_cur_dns]="Current DNS"
MSG[zh.banner_takeover_target]="接管目标"; MSG[en.banner_takeover_target]="Takeover target"
MSG[zh.banner_takeover_value]="直接读取 /etc/resolv.conf（设为系统 DNS 时生效）"
MSG[en.banner_takeover_value]="Read /etc/resolv.conf directly (applied when set as system DNS)"
MSG[zh.recommend_flow]="推荐流程: ①控制台添加本机 IP → ②测解锁(基线) → ③测 DNS → ④设为系统 DNS → ⑤控制台配置分服务 → ⑥复测解锁"
MSG[en.recommend_flow]="Recommended flow: ① add this IP in the console → ② test unlock (baseline) → ③ test DNS → ④ set as system DNS → ⑤ configure per-service in the console → ⑥ re-test unlock"
MSG[zh.menu_choose]="请选择操作:"
MSG[en.menu_choose]="Choose an action:"
MSG[zh.m_unlock]="流媒体解锁检测";       MSG[en.m_unlock]="Streaming unlock check"
MSG[zh.m_unlock_hint]="(第三方脚本 · 步骤 ②/⑥)"; MSG[en.m_unlock_hint]="(third-party script · step ②/⑥)"
MSG[zh.m_speed]="DNS 测速 / 连通性测试"; MSG[en.m_speed]="DNS speed / connectivity test"
MSG[zh.m_speed_hint]="(步骤 ③)";        MSG[en.m_speed_hint]="(step ③)"
MSG[zh.m_setdns]="设为系统 DNS (永久·接管 resolv.conf)"
MSG[en.m_setdns]="Set as system DNS (permanent · take over resolv.conf)"
MSG[zh.m_setdns_hint]="(步骤 ④)";       MSG[en.m_setdns_hint]="(step ④)"
MSG[zh.m_oneclick]="一键: 测速并设为系统 DNS"
MSG[en.m_oneclick]="One-click: test & set as system DNS"
MSG[zh.m_oneclick_hint]="(③+④)";       MSG[en.m_oneclick_hint]="(③+④)"
MSG[zh.m_temp]="临时设置 DNS (重启失效)"
MSG[en.m_temp]="Set DNS temporarily (reverts on reboot)"
MSG[zh.m_backup]="备份当前 DNS 配置"
MSG[en.m_backup]="Back up the current DNS configuration"
MSG[zh.m_restore]="还原 DNS 配置 (撤销接管 / 回滚)"
MSG[en.m_restore]="Restore DNS configuration (undo takeover / roll back)"
MSG[zh.m_status]="查看当前状态"
MSG[en.m_status]="Show current status"
MSG[zh.m_lang]="切换语言 / Switch language"
MSG[en.m_lang]="Switch language / 切换语言"
MSG[zh.m_exit]="退出";   MSG[en.m_exit]="Exit"
MSG[zh.menu_prompt]="请选择 [0-8, L]: "
MSG[en.menu_prompt]="Choose [0-8, L]: "
MSG[zh.invalid_choice]="无效选择，请输入 0-8 或 L"
MSG[en.invalid_choice]="Invalid choice; please enter 0-8 or L"
MSG[zh.goodbye]="再见！"
MSG[en.goodbye]="Goodbye!"

# ---- 语言切换 ----
MSG[zh.lang_menu_title]="选择语言 / Select language"
MSG[en.lang_menu_title]="Select language / 选择语言"
MSG[zh.lang_menu_prompt]="请选择 [0-2]: "
MSG[en.lang_menu_prompt]="Choose [0-2]: "
MSG[zh.lang_switched]="语言已切换为中文"
MSG[en.lang_switched]="Language switched to English"

# ---- CLI / help ----
MSG[zh.help_title]="AKDNS v%s - 智能 DNS 测速与系统接管工具"
MSG[en.help_title]="AKDNS v%s - Smart DNS speed-test & system takeover tool"
MSG[zh.help_desc1]="测试 DNS 连通性 → 选出最优 AKDNS → 接管系统 DNS。"
MSG[en.help_desc1]="Test DNS connectivity → pick the best AKDNS → take over system DNS."
MSG[zh.help_desc2]="无论 netplan / systemd-resolved / NetworkManager / resolvconf，"
MSG[en.help_desc2]="Regardless of netplan / systemd-resolved / NetworkManager / resolvconf,"
MSG[zh.help_desc3]="一律收敛为「直接读取 /etc/resolv.conf」，确保流媒体解锁一定生效。"
MSG[en.help_desc3]="everything converges to \"read /etc/resolv.conf directly\" so streaming unlock always works."
MSG[zh.help_usage]="用法: %s [选项]"
MSG[en.help_usage]="Usage: %s [options]"
MSG[zh.help_options]="选项:"
MSG[en.help_options]="Options:"
MSG[zh.help_opt_help]="显示帮助信息"
MSG[en.help_opt_help]="Show this help"
MSG[zh.help_opt_version]="显示版本号"
MSG[en.help_opt_version]="Show the version"
MSG[zh.help_opt_lang]="设置界面语言 (zh 或 en)"
MSG[en.help_opt_lang]="Set the interface language (zh or en)"
MSG[zh.help_interactive]="无参数运行时进入交互式菜单模式。"
MSG[en.help_interactive]="Run without arguments to enter interactive menu mode."
MSG[zh.help_backup_note]="原 DNS 配置会在接管前自动备份，可用菜单「还原 DNS 配置」一键回滚。"
MSG[en.help_backup_note]="The original DNS config is auto-backed up before takeover; use the \"Restore DNS configuration\" menu to roll back."
MSG[zh.unknown_arg]="未知参数: %s"
MSG[en.unknown_arg]="Unknown argument: %s"
MSG[zh.see_help]="使用 --help 查看帮助"
MSG[en.see_help]="Use --help for usage"
MSG[zh.no_tty_pipe]="无法获取终端输入，请改用: bash <(wget -qO- URL)"
MSG[en.no_tty_pipe]="Cannot read terminal input; use: bash <(wget -qO- URL)"
MSG[zh.no_tty]="未检测到可用终端，无法进入交互模式"
MSG[en.no_tty]="No usable terminal detected; cannot enter interactive mode"
MSG[zh.run_directly]="请直接运行脚本文件: bash akdns.sh"
MSG[en.run_directly]="Run the script file directly: bash akdns.sh"

# 翻译查找：t <id> [printf 参数...]
#   无参数 → 原样输出（%s 不会被解释）；有参数 → 按 printf 格式串展开
t() {
  local id="$1"; shift
  local s
  if [[ -n "${MSG[${UI_LANG}.${id}]+x}" ]]; then
    s="${MSG[${UI_LANG}.${id}]}"
  elif [[ -n "${MSG[en.${id}]+x}" ]]; then
    s="${MSG[en.${id}]}"
  else
    s="$id"
  fi
  if (( $# )); then
    # shellcheck disable=SC2059
    printf "$s" "$@"
  else
    printf '%s' "$s"
  fi
}

# 自动检测界面语言：已保存的手动选择优先，其次按环境变量
detect_language() {
  if [[ -f "$LANG_STATE_FILE" ]]; then
    local saved
    saved=$(tr -d '[:space:]' < "$LANG_STATE_FILE" 2>/dev/null)
    case "$saved" in
      zh|en) UI_LANG="$saved"; return ;;
    esac
  fi
  local loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-${LANGUAGE:-}}}}"
  case "$loc" in
    zh*|*[._]zh|*[._]zh[._]*|*Chinese*) UI_LANG="zh" ;;
    *) UI_LANG="en" ;;
  esac
}

# 设置并持久化界面语言
set_language() {
  case "$1" in zh|en) UI_LANG="$1" ;; *) return 1 ;; esac
  mkdir -p "$(dirname "$LANG_STATE_FILE")" 2>/dev/null \
    && printf '%s\n' "$UI_LANG" > "$LANG_STATE_FILE" 2>/dev/null
  return 0
}

# 菜单：切换语言
choose_language() {
  echo ""
  printf '%b\n' " ${BOLD}$(t lang_menu_title)${NC}"
  echo "  1) 中文 (Chinese)"
  echo "  2) English"
  printf '  0) %s\n' "$(t back)"
  echo ""
  local c
  read -r -p " $(t lang_menu_prompt)" c
  case "$c" in
    1) set_language zh; log_success "$(t lang_switched)" ;;
    2) set_language en; log_success "$(t lang_switched)" ;;
    *) : ;;
  esac
}

# ============================================================
# 工具函数
# ============================================================

log_info()    { printf '%b\n' "${BLUE}[$(t tag_info)]${NC} $*"; }
log_success() { printf '%b\n' "${GREEN}[$(t tag_ok)]${NC} $*"; }
log_warn()    { printf '%b\n' "${YELLOW}[$(t tag_warn)]${NC} $*"; }
log_error()   { printf '%b\n' "${RED}[$(t tag_error)]${NC} $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "$(t need_root)"
    return 1
  fi
}

require_command() {
  local cmd="$1"
  local pkg="${2:-$1}"
  if ! command -v "$cmd" &>/dev/null; then
    log_error "$(t cmd_not_found "$cmd" "$pkg")"
    return 1
  fi
}

confirm_action() {
  local prompt="${1:-$(t confirm_default)}"
  local answer
  printf '%b' "${YELLOW}$prompt [y/N]: ${NC}"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

press_enter() {
  echo ""
  read -r -p "$(t press_enter_prompt)"
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
      log_warn "$(t swrc_restored_symlink "$had_symlink")"
    fi
  }

  # 检查 chattr 保护
  if command -v lsattr &>/dev/null && [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
    local attrs
    attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
    if [[ "$attrs" == *i* ]]; then
      log_info "$(t immutable_detected_remove)"
      chattr -i /etc/resolv.conf || { log_error "$(t immutable_remove_fail)"; return 1; }
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
      log_warn "$(t resolv_is_symlink_del)"
      had_symlink="$link_target"
      rm -f /etc/resolv.conf || { log_error "$(t symlink_del_fail)"; return 1; }
    fi
  fi

  # 使用 mktemp 在 /etc 下创建安全临时文件
  tmpfile=$(mktemp /etc/resolv.conf.akdns.XXXXXX) || { log_error "$(t mktemp_fail)"; _swrc_cleanup; return 1; }

  # 确保临时文件不是符号链接
  if [[ -L "$tmpfile" ]]; then
    log_error "$(t tmpfile_security_fail)"
    _swrc_cleanup; return 1
  fi

  # 保留非 nameserver / 非本脚本管理的 options 行
  if [[ -f /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
    grep -vE '^nameserver|^options use-vc' /etc/resolv.conf > "$tmpfile" 2>/dev/null || true
  fi
  echo "nameserver $dns_ip" >> "$tmpfile"
  # UDP 被封锁时，强制所有解析走 TCP（glibc resolver 遵守 use-vc）
  if ${DNS_USE_TCP:-false}; then
    echo "options use-vc" >> "$tmpfile"
    log_info "$(t use_vc_written)"
  fi

  # 原子替换（mv 可直接覆盖 symlink，无需先 rm）
  chmod 644 "$tmpfile" || { log_error "$(t chmod_tmp_fail)"; _swrc_cleanup; return 1; }
  mv -f "$tmpfile" /etc/resolv.conf || { log_error "$(t mv_resolv_fail)"; _swrc_cleanup; return 1; }
  tmpfile=""  # mv 成功后不再需要清理

  # SELinux 上下文恢复
  if command -v restorecon &>/dev/null; then
    restorecon -F /etc/resolv.conf 2>/dev/null
  fi

  # 恢复 immutable
  if $had_immutable; then
    log_info "$(t immutable_detected_remove)"
    chattr +i /etc/resolv.conf 2>/dev/null
  fi

  # 验证文件内容
  if ! grep -q "^nameserver $dns_ip" /etc/resolv.conf 2>/dev/null; then
    log_error "$(t resolv_verify_fail)"
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
    log_info "$(t locked_resolv)"
  fi
}

unlock_resolv_conf() {
  command -v chattr &>/dev/null || return 0
  [[ -e /etc/resolv.conf ]] || return 0
  [[ -L /etc/resolv.conf ]] && return 0
  local attrs
  attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
  if [[ "$attrs" == *i* ]]; then
    chattr -i /etc/resolv.conf 2>/dev/null && log_info "$(t unlocked_resolv)"
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
  log_info "$(t nsswitch_add_dns)"
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
      log_info "$(t disable_resolved)"
      systemctl disable --now systemd-resolved 2>/dev/null \
        || log_warn "$(t disable_resolved_fail)"
    fi
  fi

  # 2) NetworkManager：令其不再管理 resolv.conf（dns=none），但不停用网络
  if command -v nmcli &>/dev/null \
      && { systemctl is-active --quiet NetworkManager 2>/dev/null || nmcli general status &>/dev/null 2>&1; }; then
    if [[ -d /etc/NetworkManager ]]; then
      mkdir -p /etc/NetworkManager/conf.d
      cat > /etc/NetworkManager/conf.d/akdns-dns.conf << 'EOF'
# Written by AKDNS: keep NetworkManager from overwriting /etc/resolv.conf
[main]
dns=none
EOF
      chmod 644 /etc/NetworkManager/conf.d/akdns-dns.conf
      log_info "$(t nm_dns_none)"
      systemctl reload NetworkManager 2>/dev/null \
        || nmcli general reload 2>/dev/null || true
    fi
  fi

  # 3) resolvconf / openresolv：停用其服务，避免重新生成
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null \
      && systemctl is-active --quiet resolvconf 2>/dev/null; then
    log_info "$(t disable_resolvconf)"
    systemctl disable --now resolvconf 2>/dev/null || true
  fi

  # 4) 确保 NSS 解析链路会查询 resolv.conf
  ensure_nsswitch_dns
}

# 核心：不论原后端是什么，统一接管为静态 /etc/resolv.conf 并写入指定 DNS
force_static_resolv_conf() {
  local dns_ip="$1"
  log_info "$(t takeover_start)"

  # 若此前已锁定，先解锁以便写入
  unlock_resolv_conf

  # 停用各类 DNS 管理器
  neutralize_dns_managers

  # 写入静态 resolv.conf（safe_write 会移除 systemd 符号链接并原子替换）
  if ! safe_write_resolv_conf "$dns_ip"; then
    log_error "$(t write_resolv_fail)"
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
  log_info "$(t detected_system "$DISTRO_NAME" "$DISTRO_VERSION")"
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
  log_info "$(t init_system_is "$INIT_SYSTEM")"
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

  log_info "$(t dns_backend_is "$DNS_BACKEND_TEMP" "$DNS_BACKEND_PERM")"
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

  echo "${dns_servers:-$(t unknown)}"
}

# ============================================================
# 备份功能
# ============================================================

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR" || { log_error "$(t backup_dir_fail "$BACKUP_DIR")"; return 1; }
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
  mkdir -p "$backup_path" || { umask "$old_umask"; log_error "$(t backup_mkdir_fail)"; return 1; }
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

  log_success "$(t backup_done "$backup_path")"
  return 0
}

# ============================================================
# 还原功能
# ============================================================

list_backups() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log_warn "$(t no_backups_dir "$BACKUP_DIR")"
    return 1
  fi

  local -a backup_dirs=()
  while IFS= read -r dir; do
    backup_dirs+=("$dir")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

  if [[ ${#backup_dirs[@]} -eq 0 ]]; then
    log_warn "$(t no_backups)"
    return 1
  fi

  echo ""
  printf '%b\n' "${BOLD}$(t avail_backups)${NC}"
  echo "--------------------------------------------"
  printf "%-4s %-20s %-14s %s\n" "$(t col_no)" "$(t col_time)" "$(t col_tag)" "$(t col_dns)"
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
      printf "%-4s %-20s %-14s %s\n" "$i" "$(basename "$dir")" "-" "$(t meta_missing)"
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
  read -r -p "$(t restore_prompt)" choice

  if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
    log_info "$(t cancel_restore)"
    return 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backup_dirs[@]} )); then
    log_error "$(t invalid_number "$choice")"
    return 1
  fi

  local target_dir="${backup_dirs[$((choice - 1))]}"

  if ! confirm_action "$(t confirm_restore "$(basename "$target_dir")")"; then
    log_info "$(t cancel_restore)"
    return 0
  fi

  # 还原前自动备份当前状态
  log_info "$(t pre_restore_backup)"
  if ! do_backup "pre-restore"; then
    log_error "$(t pre_restore_backup_fail)"
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
    log_info "$(t removed_nm_dns_none)"
  fi

  # 还原 resolv.conf
  if [[ -f "$target_dir/resolv.conf" ]]; then
    local restore_had_immutable=false
    # 检测并移除 immutable 标志
    if command -v lsattr &>/dev/null && [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
      local rattrs
      rattrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
      if [[ "$rattrs" == *i* ]]; then
        log_info "$(t restore_immutable_detected)"
        chattr -i /etc/resolv.conf || { log_error "$(t restore_immutable_fail)"; return 1; }
        restore_had_immutable=true
      fi
    fi
    # 移除现有的（可能是 symlink，或接管时写入的静态文件）
    rm -f /etc/resolv.conf || { log_error "$(t restore_rm_resolv_fail)"; return 1; }
    # 若原本是符号链接（如 systemd-resolved 的 stub），优先恢复符号链接本身
    if [[ -f "$target_dir/resolv.conf.symlink" ]]; then
      local _symlink_target
      _symlink_target=$(cat "$target_dir/resolv.conf.symlink" 2>/dev/null)
      if [[ -n "$_symlink_target" ]]; then
        ln -sf "$_symlink_target" /etc/resolv.conf \
          && log_info "$(t swrc_restored_symlink "$_symlink_target")"
      fi
    fi
    # 非符号链接场景：恢复静态文件内容
    if [[ ! -L /etc/resolv.conf ]]; then
      cp "$target_dir/resolv.conf" /etc/resolv.conf || { log_error "$(t restore_resolv_fail)"; return 1; }
      chmod 644 /etc/resolv.conf
      # SELinux 上下文恢复
      if command -v restorecon &>/dev/null; then
        restorecon -F /etc/resolv.conf 2>/dev/null
      fi
    fi
    # 注意：还原的目的是撤销接管，这里不再重新加 immutable 锁
    # （接管时加的锁已在上面移除；如需手动锁定可自行执行 chattr +i）
    log_info "$(t restored_resolv)"
  fi

  case "$backend_perm_saved" in
    systemd-resolved)
      if [[ -f "$target_dir/resolved.conf" ]]; then
        if cp "$target_dir/resolved.conf" /etc/systemd/resolved.conf; then
          log_info "$(t restored_resolved_conf)"
        else
          log_warn "$(t restore_resolved_conf_fail)"
        fi
      fi
      # 还原 drop-in
      if [[ -d "$target_dir/resolved.conf.d" ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        # 使用 cp -a src/. dst/ 避免空目录/通配符问题
        if cp -a "$target_dir/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null; then
          log_info "$(t restored_resolved_dropin)"
        else
          log_warn "$(t restore_resolved_dropin_fail)"
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
          log_info "$(t restored_nm_conf)"
        else
          log_warn "$(t restore_nm_conf_fail)"
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
            nmcli con mod "$nm_uuid" ipv4.dns "$saved_dns" 2>/dev/null || { log_warn "$(t restore_nm_dns_fail)"; nm_restore_ok=false; }
          else
            nmcli con mod "$nm_uuid" ipv4.dns "" 2>/dev/null || nm_restore_ok=false
          fi
          if [[ "$saved_ignore" == "yes" ]]; then
            nmcli con mod "$nm_uuid" ipv4.ignore-auto-dns yes 2>/dev/null
          else
            nmcli con mod "$nm_uuid" ipv4.ignore-auto-dns no 2>/dev/null
          fi
          if $nm_restore_ok; then
            log_info "$(t restored_nm_dns "$nm_uuid")"
          fi
        fi
      fi
      ;;
    netplan)
      if [[ -d "$target_dir/netplan" ]]; then
        mkdir -p /etc/netplan
        if cp -a "$target_dir/netplan/." /etc/netplan/ 2>/dev/null; then
          log_info "$(t restored_netplan)"
        else
          log_warn "$(t restore_netplan_fail)"
        fi
      fi
      ;;
  esac

  # 撤销接管：还原 nsswitch.conf
  if [[ -f "$target_dir/nsswitch.conf" ]]; then
    cp -a "$target_dir/nsswitch.conf" /etc/nsswitch.conf 2>/dev/null \
      && log_info "$(t restored_nsswitch)"
  fi

  # 撤销接管：重新启用此前被停用的 DNS 管理器
  if command -v systemctl &>/dev/null; then
    if [[ "$resolved_enabled_saved" == "yes" ]] || [[ "$resolved_active_saved" == "yes" ]]; then
      log_info "$(t reenable_resolved)"
      systemctl enable systemd-resolved 2>/dev/null || true
      systemctl start  systemd-resolved 2>/dev/null || log_warn "$(t resolved_start_fail)"
    fi
    if [[ "$resolvconf_active_saved" == "yes" ]]; then
      log_info "$(t reenable_resolvconf)"
      systemctl enable --now resolvconf 2>/dev/null || true
    fi
  fi

  # 重载服务
  reload_dns_service "$backend_perm_saved"

  # 验证还原结果
  if verify_system_dns; then
    log_success "$(t restore_ok_verified)"
  else
    log_warn "$(t restore_ok_unverified)"
  fi
}

reload_dns_service() {
  local backend="${1:-$DNS_BACKEND_PERM}"

  case "$backend" in
    systemd-resolved)
      if ! command -v systemctl &>/dev/null; then
        log_warn "$(t systemctl_unavailable_resolved)"
      else
        log_info "$(t restart_resolved)"
        if ! systemctl restart systemd-resolved; then
          log_warn "$(t restart_resolved_fail)"
        fi
      fi
      ;;
    networkmanager)
      log_info "$(t reload_nm)"
      if ! nmcli con reload; then
        log_warn "$(t reload_nm_fail)"
      fi
      local uuid
      uuid=$(get_active_nm_connection_uuid)
      if [[ -n "$uuid" ]]; then
        nmcli con up "$uuid" 2>/dev/null || log_warn "$(t nm_reactivate_fail)"
      fi
      ;;
    netplan)
      log_info "$(t apply_netplan)"
      if ! netplan apply; then
        log_warn "$(t apply_netplan_fail)"
      fi
      ;;
    resolv.conf)
      log_info "$(t resolv_no_reload)"
      ;;
  esac
}

# 验证系统 DNS 是否生效（走系统 resolver，而非指定 @server）
verify_system_dns() {
  sleep 1
  log_info "$(t verify_dns)"

  local tcp_note=""
  ${DNS_USE_TCP:-false} && tcp_note="$(t tcp_paren)"

  # 优先用 getent：走 glibc resolver，会遵守 resolv.conf 的 options use-vc（TCP）
  if command -v getent &>/dev/null; then
    if getent hosts "$DOMAIN" &>/dev/null; then
      log_success "$(t verify_ok "$tcp_note")"
      return 0
    fi
  fi

  # 回退到 dig；TCP 模式下显式加 +tcp（dig 默认走 UDP，不读 use-vc）
  if command -v dig &>/dev/null; then
    local digargs="+short +time=3 +tries=1"
    ${DNS_USE_TCP:-false} && digargs="+tcp $digargs"
    if dig $digargs "$DOMAIN" &>/dev/null; then
      log_success "$(t verify_ok "$tcp_note")"
      return 0
    fi
    log_warn "$(t verify_fail)"
    return 0
  fi

  return 0
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
        log_error "$(t no_primary_iface)"
        return 1
      fi
      log_info "$(t resolvectl_set "$iface")"
      if ! resolvectl dns "$iface" "$dns_ip"; then
        log_error "$(t resolvectl_set_fail)"
        return 1
      fi
      ;;
    networkmanager)
      log_info "$(t temp_nm_note)"
      local resolv_symlink_target=""
      if [[ -L /etc/resolv.conf ]]; then
        resolv_symlink_target=$(readlink -f /etc/resolv.conf 2>/dev/null)
        if [[ "$resolv_symlink_target" == *"systemd"* ]] || [[ "$resolv_symlink_target" == *"stub"* ]]; then
          log_warn "$(t resolv_symlink_use_resolvectl)"
          iface=$(get_primary_interface)
          if [[ -n "$iface" ]]; then
            if resolvectl dns "$iface" "$dns_ip" 2>/dev/null; then
              return 0
            fi
          fi
          log_warn "$(t resolvectl_fail_fallback)"
        fi
      fi
      if ! safe_write_resolv_conf "$dns_ip"; then
        log_error "$(t write_resolv_fail)"
        return 1
      fi
      ;;
    resolv.conf)
      log_info "$(t temp_edit_resolv)"
      if ! safe_write_resolv_conf "$dns_ip"; then
        log_error "$(t write_resolv_fail)"
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
    log_info "$(t detected_backend_takeover "$DNS_BACKEND_PERM")"
  fi

  force_static_resolv_conf "$dns_ip" || return 1

  return 0
}

# ============================================================
# 测速逻辑
# ============================================================

# 测量所有 AKDNS 节点的平均响应时间。
#   $1: 传输标签(udp/tcp，仅用于命名)  $2: 传给 dig 的额外参数（"" 或 "+tcp"）
# 输出: 已按延迟升序排列的 "avg dns" 行；avg=1000 表示该节点本轮全部超时。
measure_dns_transport() {
  local extra="${2:-}"
  local tmpdir
  tmpdir=$(mktemp -d) || return 1

  local dns i
  for dns in "${DNS_LIST[@]}"; do
    for ((i = 1; i <= COUNT; i++)); do
      (
        local t
        t=$(dig @"$dns" "$DOMAIN" $extra +stats +time="$TIMEOUT" +tries=1 2>/dev/null \
          | awk '/Query time/ {print $4}')
        if [[ -n "$t" ]]; then echo "$dns $t"; else echo "$dns 1000"; fi
      ) > "$tmpdir/result_${dns}_${i}" &
    done
  done
  wait

  cat "$tmpdir"/result_* 2>/dev/null | awk '
    { sum[$1] += $2; cnt[$1]++ }
    END { for (d in sum) printf "%d %s\n", sum[d] / cnt[d], d }
  ' | sort -n

  rm -rf "$tmpdir"
}

run_speed_test() {
  if ! command -v dig &>/dev/null; then
    log_error "$(t dig_not_found)"
    case "$DISTRO_ID" in
      ubuntu|debian)   log_info "$(t please_install "sudo apt install dnsutils")" ;;
      centos|rhel|fedora|rocky|alma) log_info "$(t please_install "sudo yum install bind-utils")" ;;
      arch|manjaro)    log_info "$(t please_install "sudo pacman -S bind")" ;;
      alpine)          log_info "$(t please_install "sudo apk add bind-tools")" ;;
      opensuse*)       log_info "$(t please_install "sudo zypper install bind-utils")" ;;
      *)               log_info "$(t please_install_dig_generic)" ;;
    esac
    return 1
  fi

  echo ""
  printf '%b\n' "${BOLD}$(t speed_test_title)${NC}"
  echo "$(t label_domain)   : $DOMAIN"
  echo "$(t label_count)   : $COUNT"
  echo "$(t label_timeout)   : ${TIMEOUT}s"
  echo "------------------------------------"

  # 每次测速重新判定传输方式
  DNS_USE_TCP=false
  local transport="UDP"

  echo "$(t testing_udp)"
  local result
  result=$(measure_dns_transport udp "")

  # UDP 全部超时 → 自动回退到 TCP（常见于网络封锁 UDP/53 但放行 TCP/53）
  local best_avg
  best_avg=$(echo "$result" | head -n1 | awk '{print $1}')
  if [[ -z "$result" ]] || (( ${best_avg:-1000} >= 1000 )); then
    log_warn "$(t udp_all_timeout_try_tcp)"
    echo "$(t testing_tcp)"
    local tcp_result tcp_best_avg
    tcp_result=$(measure_dns_transport tcp "+tcp")
    tcp_best_avg=$(echo "$tcp_result" | head -n1 | awk '{print $1}')
    if [[ -n "$tcp_result" ]] && (( ${tcp_best_avg:-1000} < 1000 )); then
      result="$tcp_result"
      DNS_USE_TCP=true
      transport="TCP"
      log_success "$(t tcp_available)"
      if [[ "$DISTRO_ID" == "alpine" ]]; then
        log_warn "$(t alpine_musl_warn)"
      fi
    fi
  fi

  echo ""
  printf '%b\n' "${BOLD}$(t node_latency_header "$transport")${NC}"
  echo "------------------------------------"
  # avg>=1000 视为该节点全部超时，标记为不可达
  local _to; _to="$(t node_timeout)"
  echo "$result" | awk -v to="$_to" '{
    if ($1 + 0 >= 1000) printf "  %-18s %s\n", $2, to;
    else                printf "  %-18s %s ms  ✓\n", $2, $1;
  }'

  local best_dns
  best_avg=$(echo "$result" | head -n1 | awk '{print $1}')
  best_dns=$(echo "$result" | head -n1 | awk '{print $2}')

  if [[ -z "$best_dns" ]] || (( ${best_avg:-1000} >= 1000 )); then
    echo "------------------------------------"
    log_error "$(t both_timeout)"
    BEST_DNS=""
    DNS_USE_TCP=false
    return 1
  fi

  BEST_DNS="$best_dns"

  echo "------------------------------------"
  printf '%b\n' "  $(t best_dns_label): ${GREEN}${BOLD}$BEST_DNS${NC} (${best_avg}ms, ${transport})"
  if $DNS_USE_TCP; then
    printf '%b\n' "  ${YELLOW}$(t transport_forced_tcp)${NC}"
  fi
  echo ""
  log_info "$(t speed_hint_next)"
}

# ============================================================
# 菜单应用交互
# ============================================================

menu_apply() {
  local mode="$1"  # temp 或 perm
  local mode_name
  if [[ "$mode" == "temp" ]]; then
    mode_name="$(t mode_temp)"
  else
    mode_name="$(t mode_perm)"
  fi

  local target_dns="$BEST_DNS"

  if [[ -z "$target_dns" ]]; then
    echo ""
    log_warn "$(t not_tested_yet)"
    echo ""
    echo "  1) $(t subopt_run_test)"
    echo "  2) $(t subopt_manual_dns)"
    echo "  0) $(t subopt_back)"
    echo ""
    local subchoice
    read -r -p "$(t select_0_2)" subchoice
    case "$subchoice" in
      1)
        run_speed_test
        target_dns="$BEST_DNS"
        if [[ -z "$target_dns" ]]; then
          log_error "$(t speed_test_no_result)"
          return 1
        fi
        ;;
      2)
        read -r -p "$(t enter_dns)" target_dns
        if ! validate_ipv4 "$target_dns"; then
          log_error "$(t invalid_ipv4 "$target_dns")"
          return 1
        fi
        ;;
      *)
        return 0
        ;;
    esac
  fi

  echo ""
  printf '%b\n' "${BOLD}$(t op_summary)${NC}"
  echo "  $(t sum_mode)   : $(t summary_mode_value "$mode_name")"
  echo "  $(t sum_dns)    : $target_dns"
  if [[ "$mode" == "temp" ]]; then
    echo "  $(t backend_label)   : $(t backend_temp_expire "$DNS_BACKEND_TEMP")"
  else
    echo "  $(t cur_backend_label) : $DNS_BACKEND_PERM"
    echo "  $(t takeover_method_label) : $(t takeover_method_value)"
    if ${DNS_USE_TCP:-false}; then
      echo "  $(t transport_label) : $(t transport_forced_tcp_value)"
    fi
    if $LOCK_RESOLV_CONF; then
      echo "  $(t antioverwrite_label)   : $(t antioverwrite_value)"
    fi
    echo ""
    printf '%b\n' "  ${YELLOW}$(t takeover_note1)${NC}"
    printf '%b\n' "  ${YELLOW}$(t takeover_note2)${NC}"
  fi
  echo ""

  if ! confirm_action "$(t confirm_apply "$mode_name" "$target_dns")"; then
    log_info "$(t cancel_op)"
    return 0
  fi

  require_root || return 1

  # 自动备份
  log_info "$(t auto_backup_now)"
  if ! do_backup "pre-apply-${mode}"; then
    log_error "$(t auto_backup_fail)"
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
    log_info "$(t current_effective_dns "$(get_current_dns)")"
  else
    log_error "$(t apply_failed)"
  fi

  return $exit_code
}

# 一键：测速选最优 → 接管为系统 DNS（步骤③+④串联）
run_test_and_apply() {
  run_speed_test || return 1
  if [[ -z "$BEST_DNS" ]]; then
    log_error "$(t no_dns_aborted)"
    return 1
  fi
  echo ""
  log_info "$(t about_to_takeover "$BEST_DNS")"
  menu_apply perm
}

# ============================================================
# 流媒体解锁检测
# ============================================================

inject_akdns_unlock_context() {
  local script_path="$1"
  local patch_tmp
  patch_tmp=$(mktemp /tmp/akdns-unlock-check-patched.XXXXXX) || return 1

  if awk -v console="$CONSOLE_URL" -v akdns_tg="$AKDNS_TG_URL" '
    function emit_context() {
      print "    if [[ \"${language:-}\" == \"e\" ]]; then"
      print "        echo -e \"${Font_Green}AKDNS:${Font_Suffix} ${Font_Yellow}Smart DNS unlock routing / Console: " console " ${Font_Suffix}\""
      print "        echo -e \"${Font_Green}AKDNS Telegram:${Font_Suffix} ${Font_Yellow}" akdns_tg " ${Font_Suffix}\""
      print "        echo -e \"${Font_Yellow}This runtime copy was downloaded from 1-stream/RegionRestrictionCheck and patched by AKDNS to show AKDNS context; detection logic and results remain third-party reference output.${Font_Suffix}\""
      print "        echo \"\""
      print "    else"
      print "        echo -e \"${Font_Green}AKDNS:${Font_Suffix} ${Font_Yellow}智能 DNS 流媒体解锁分流 / 控制台：" console " ${Font_Suffix}\""
      print "        echo -e \"${Font_Green}AKDNS TG 群组:${Font_Suffix} ${Font_Yellow}" akdns_tg " ${Font_Suffix}\""
      print "        echo -e \"${Font_Yellow}当前临时脚本下载自 1-stream/RegionRestrictionCheck，并由 AKDNS 运行时注入说明；检测逻辑与结果仍为第三方脚本参考输出。${Font_Suffix}\""
      print "        echo \"\""
      print "    fi"
    }
    {
      if ($0 ~ /\[商家\]TG群组/) {
        sub(/\[商家\]TG群组/, "第三方脚本 TG 群组（非 AKDNS 官方群）")
      }
      print
      if (!done && $0 ~ /^function ScriptTitle\(\)[[:space:]]*\{/) {
        emit_context()
        done = 1
      }
    }
    END {
      if (!done) {
        exit 42
      }
    }
  ' "$script_path" > "$patch_tmp"; then
    mv "$patch_tmp" "$script_path"
    return 0
  fi

  rm -f "$patch_tmp"
  return 1
}

run_unlock_check() {
  if ! command -v curl &>/dev/null; then
    log_error "$(t curl_not_found)"
    case "$DISTRO_ID" in
      ubuntu|debian)   log_info "$(t please_install "sudo apt install curl")" ;;
      centos|rhel|fedora|rocky|alma) log_info "$(t please_install "sudo yum install curl")" ;;
      arch|manjaro)    log_info "$(t please_install "sudo pacman -S curl")" ;;
      alpine)          log_info "$(t please_install "sudo apk add curl")" ;;
      *)               log_info "$(t please_install "curl")" ;;
    esac
    return 1
  fi

  local script_url="https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh"
  local tmp_script
  tmp_script=$(mktemp /tmp/akdns-unlock-check.XXXXXX) || { log_error "$(t mktemp_fail)"; return 1; }

  # 确保退出时清理临时文件
  trap 'rm -f "$tmp_script"' RETURN

  log_warn "$(t unlock_third_party_notice)"
  log_info "$(t downloading_unlock)"
  if ! curl -L -s --fail --connect-timeout 10 --max-time 30 "$script_url" -o "$tmp_script"; then
    log_error "$(t download_unlock_fail)"
    return 1
  fi

  # 验证下载内容非空
  if [[ ! -s "$tmp_script" ]]; then
    log_error "$(t download_empty)"
    return 1
  fi

  log_info "$(t injecting_unlock_context)"
  if ! inject_akdns_unlock_context "$tmp_script"; then
    log_error "$(t inject_unlock_context_fail)"
    return 1
  fi

  echo ""
  bash "$tmp_script" -M 4
  local exit_code=$?
  echo ""
  if [[ $exit_code -eq 0 ]]; then
    log_success "$(t unlock_done)"
  else
    log_warn "$(t unlock_exit_code "$exit_code")"
  fi

  echo ""
  printf '%b\n' "${BOLD}$(t next_step_title)${NC}"
  echo "  $(t unlock_next1)"
  echo "    $(t unlock_next1b)"
  echo "  $(t unlock_console "$CONSOLE_URL")"
}

# ============================================================
# 状态查看
# ============================================================

show_status() {
  echo ""
  printf '%b\n' "${BOLD}====== $(t status_title) ======${NC}"
  echo ""
  printf "  %-18s %s\n" "$(t st_distro)" "$DISTRO_NAME $DISTRO_VERSION"
  printf "  %-18s %s\n" "$(t st_distro_id)" "$DISTRO_ID"
  printf "  %-18s %s\n" "$(t st_init)" "$INIT_SYSTEM"
  printf "  %-18s %s\n" "$(t st_backend_temp)" "$DNS_BACKEND_TEMP"
  printf "  %-18s %s\n" "$(t st_backend_perm)" "$DNS_BACKEND_PERM"
  printf "  %-18s %s\n" "$(t st_cur_dns)" "$(get_current_dns)"
  printf "  %-18s %s\n" "$(t st_iface)" "$(get_primary_interface)"

  # 备份信息
  if [[ -d "$BACKUP_DIR" ]]; then
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    printf "  %-18s %s\n" "$(t st_backup_count)" "$backup_count"
    if (( backup_count > 0 )); then
      local latest
      latest=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)
      if [[ -f "$latest/metadata.txt" ]]; then
        local ts
        ts=$(grep '^timestamp=' "$latest/metadata.txt" | cut -d= -f2-)
        printf "  %-18s %s\n" "$(t st_last_backup)" "$ts"
      fi
    fi
  else
    printf "  %-18s %s\n" "$(t st_backup_count)" "$(t st_backup_count_none)"
  fi

  # 缓存的测速结果
  if [[ -n "$BEST_DNS" ]]; then
    printf "  %-18s %s\n" "$(t st_best_cached)" "$BEST_DNS"
  fi

  # 当前 resolv.conf 是否已强制 TCP
  if grep -q '^options use-vc' /etc/resolv.conf 2>/dev/null; then
    printf "  %-18s %s\n" "$(t st_dns_transport)" "TCP (options use-vc)"
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
  printf '%b\n' " ${BOLD}AKDNS v${VERSION}${NC} - $(t banner_subtitle)"
  echo " ========================================="
  printf '%b\n' " $(t banner_system) : ${GREEN}$DISTRO_NAME $DISTRO_VERSION${NC}"
  echo " init : $INIT_SYSTEM"
  echo " $(t banner_cur_backend) : $DNS_BACKEND_PERM"
  echo " $(t banner_cur_dns) : $(get_current_dns)"
  printf '%b\n' " $(t banner_takeover_target) : ${GREEN}$(t banner_takeover_value)${NC}"
  echo " ========================================="
}

show_menu() {
  echo ""
  printf '%b\n' " ${BOLD}$(t recommend_flow)${NC}"
  echo ""
  printf '%b\n' " ${BOLD}$(t menu_choose)${NC}"
  echo ""
  printf '%b\n' "  ${GREEN}1)${NC} $(t m_unlock) ${CYAN}$(t m_unlock_hint)${NC}"
  printf '%b\n' "  ${GREEN}2)${NC} $(t m_speed) ${CYAN}$(t m_speed_hint)${NC}"
  printf '%b\n' "  ${GREEN}3)${NC} $(t m_setdns) ${CYAN}$(t m_setdns_hint)${NC}"
  printf '%b\n' "  ${GREEN}4)${NC} $(t m_oneclick) ${CYAN}$(t m_oneclick_hint)${NC}"
  echo ""
  printf '%b\n' "  ${GREEN}5)${NC} $(t m_temp)"
  printf '%b\n' "  ${GREEN}6)${NC} $(t m_backup)"
  printf '%b\n' "  ${GREEN}7)${NC} $(t m_restore)"
  printf '%b\n' "  ${GREEN}8)${NC} $(t m_status)"
  printf '%b\n' "  ${CYAN}L)${NC} $(t m_lang)"
  printf '%b\n' "  ${RED}0)${NC} $(t m_exit)"
  echo ""
}

# ============================================================
# 主入口
# ============================================================

main() {
  # 预解析 --lang，使 --help / 菜单使用正确语言
  local cli_lang=""
  local -a rest=()
  while (( $# )); do
    case "$1" in
      --lang=*) cli_lang="${1#--lang=}"; shift ;;
      --lang|-l) cli_lang="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  if (( ${#rest[@]} )); then set -- "${rest[@]}"; else set --; fi

  # 语言：自动检测 + CLI 覆盖
  detect_language
  case "$cli_lang" in zh|en) UI_LANG="$cli_lang" ;; esac

  # 处理命令行参数
  case "${1:-}" in
    --help|-h)
      echo "$(t help_title "$VERSION")"
      echo ""
      echo "$(t help_desc1)"
      echo "$(t help_desc2)"
      echo "$(t help_desc3)"
      echo ""
      echo "$(t help_usage "$(basename "$0")")"
      echo ""
      echo "$(t help_options)"
      printf '  %-18s %s\n' "--help, -h"     "$(t help_opt_help)"
      printf '  %-18s %s\n' "--version, -v"  "$(t help_opt_version)"
      printf '  %-18s %s\n' "--lang <zh|en>" "$(t help_opt_lang)"
      echo ""
      echo "$(t help_interactive)"
      echo "$(t help_backup_note)"
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
      echo "$(t unknown_arg "$1")"
      echo "$(t see_help)"
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
      exec < /dev/tty || { log_error "$(t no_tty_pipe)"; exit 1; }
    else
      log_error "$(t no_tty)"
      log_info "$(t run_directly)"
      exit 1
    fi
  fi

  while true; do
    clear
    show_banner
    show_menu
    local choice
    read -r -p " $(t menu_prompt)" choice
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
      L|l) choose_language ;;
      0)
        clear
        log_info "$(t goodbye)"
        exit 0
        ;;
      *)
        log_warn "$(t invalid_choice)"
        ;;
    esac
    press_enter
  done
}

main "$@"
