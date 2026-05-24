#!/usr/bin/env bash
# lxd-nat-manager-v1.0.sh
# 中文 LXD NAT 小鸡管理脚本
# 适用：Debian/Ubuntu 母鸡，LXD/LXC NAT 容器，小型隔离环境。
# 原则：先检测、少破坏、危险操作二次确认。

set -o pipefail

SCRIPT_VERSION="v1.0"
SCRIPT_NAME="lxd-nat-manager"
INSTALL_PATH="/usr/local/bin/lxdnat"
STATE_DIR="/etc/lxd-nat-manager"
STATE_FILE="${STATE_DIR}/containers.db"
DEFAULT_IMAGE="images:debian/11"
DEFAULT_SYSTEM="debian11"
DEFAULT_NET="lxdbr0"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERR]${RESET} $*"; }

pause() {
  echo
  read -r -p "按 Enter 返回菜单..." _
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

safe_mkdir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  touch "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt 输入 YES 确认：" answer
  [ "$answer" = "YES" ]
}

valid_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]]
}

valid_num() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

normalize_mbps() {
  local v="$1"
  if [ -z "$v" ]; then
    echo "0"
  elif [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo "INVALID"
  fi
}

system_to_image() {
  local sys
  sys="$(echo "${1:-$DEFAULT_SYSTEM}" | tr '[:upper:]' '[:lower:]' | tr -d ' ._-')"
  case "$sys" in
    ""|debian11|debianbullseye) echo "images:debian/11" ;;
    debian12|debianbookworm) echo "images:debian/12" ;;
    debian13|debiantrixie) echo "images:debian/13" ;;
    ubuntu20|ubuntu2004|ubuntu20lts|focal) echo "images:ubuntu/20.04" ;;
    ubuntu22|ubuntu2204|ubuntu22lts|jammy) echo "images:ubuntu/22.04" ;;
    ubuntu24|ubuntu2404|ubuntu24lts|noble) echo "images:ubuntu/24.04" ;;
    almalinux8) echo "images:almalinux/8" ;;
    almalinux9) echo "images:almalinux/9" ;;
    rockylinux8|rocky8) echo "images:rockylinux/8" ;;
    rockylinux9|rocky9) echo "images:rockylinux/9" ;;
    alpine318|alpine3.18) echo "images:alpine/3.18" ;;
    alpine319|alpine3.19) echo "images:alpine/3.19" ;;
    alpine320|alpine3.20) echo "images:alpine/3.20" ;;
    *) echo "$1" ;;
  esac
}

show_header() {
  clear 2>/dev/null || true
  echo "============================================================"
  echo " LXD NAT 小鸡管理脚本 ${SCRIPT_VERSION}"
  echo " 命令别名：lxdnat    默认系统：Debian 11"
  echo "============================================================"
}

precheck_readonly() {
  show_header
  echo "---------------------只读环境检查---------------------"
  echo "系统信息："
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    echo "  OS: ${PRETTY_NAME:-unknown}"
  fi
  echo "  Kernel: $(uname -r)"
  echo
  echo "LXD/LXC："
  if cmd_exists lxc; then
    echo "  lxc: $(lxc --version 2>/dev/null || echo unknown)"
  else
    echo "  lxc: 未安装"
  fi
  if cmd_exists snap; then
    echo "  snap: $(snap version 2>/dev/null | head -n 1 || echo installed)"
    snap list lxd 2>/dev/null || true
  else
    echo "  snap: 未安装"
  fi
  echo
  echo "网络监听："
  ss -lntup 2>/dev/null | head -n 30 || true
  echo
  echo "LXD 网络："
  if cmd_exists lxc; then
    lxc network list 2>/dev/null || true
  fi
  echo
  echo "LXD 存储："
  if cmd_exists lxc; then
    lxc storage list 2>/dev/null || true
  fi
  echo "--------------------------------------------------------"
  pause
}

install_snapd_if_needed() {
  if cmd_exists snap; then
    return 0
  fi
  info "未检测到 snap，准备安装 snapd。"
  if cmd_exists apt-get; then
    apt-get update
    apt-get install -y snapd ca-certificates curl
    systemctl enable --now snapd.socket 2>/dev/null || true
    systemctl enable --now snapd 2>/dev/null || true
    sleep 2
  else
    err "当前系统未检测到 apt-get，脚本暂不自动安装 snapd。"
    return 1
  fi
}

install_lxd_if_needed() {
  if cmd_exists lxc && lxc --version >/dev/null 2>&1; then
    ok "已检测到 lxc 命令。"
    return 0
  fi
  install_snapd_if_needed || return 1
  info "准备通过 snap 安装 LXD。"
  snap install lxd || {
    err "snap install lxd 失败。"
    return 1
  }
  if [ -x /snap/bin/lxc ] && ! cmd_exists lxc; then
    ln -sf /snap/bin/lxc /usr/local/bin/lxc 2>/dev/null || true
  fi
  ok "LXD 安装完成。"
}

is_lxd_initialized() {
  cmd_exists lxc || return 1
  lxc info >/dev/null 2>&1 || return 1
  lxc network show "$DEFAULT_NET" >/dev/null 2>&1 || return 1
  lxc storage list --format csv 2>/dev/null | grep -q . || return 1
  return 0
}

quick_init_lxd() {
  show_header
  echo "---------------------快速初始化 LXD---------------------"
  warn "本步骤会在未初始化时执行 lxd init --auto，创建默认 NAT 网桥 lxdbr0 和默认存储池。"
  warn "如果你已有复杂 LXD 生产环境，请先退出并手动确认配置。"
  echo
  read -r -p "是否继续快速初始化？[y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) warn "已取消。"; pause; return ;;
  esac

  install_lxd_if_needed || { pause; return; }

  if is_lxd_initialized; then
    ok "LXD 看起来已经初始化，无需重复初始化。"
  else
    info "开始执行 lxd init --auto。"
    lxd init --auto || {
      err "lxd init --auto 失败，请手动执行 lxd init 查看原因。"
      pause
      return
    }
    ok "LXD 初始化完成。"
  fi

  if lxc network show "$DEFAULT_NET" >/dev/null 2>&1; then
    ok "检测到默认 NAT 网桥：${DEFAULT_NET}"
  else
    warn "未检测到 ${DEFAULT_NET}。如果你使用自定义网桥，创建容器时可能需要手动调整。"
  fi

  safe_mkdir
  install_alias_silent
  echo
  lxc network list 2>/dev/null || true
  echo
  lxc storage list 2>/dev/null || true
  pause
}

install_alias_silent() {
  if [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null || true
  fi
}

install_alias() {
  show_header
  safe_mkdir
  if cp -f "$0" "$INSTALL_PATH" && chmod +x "$INSTALL_PATH"; then
    ok "已安装管理命令：${INSTALL_PATH}"
    ok "以后可直接输入：lxdnat"
  else
    err "安装管理命令失败。"
  fi
  pause
}

port_in_use_tcp() {
  local p="$1"
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"
}

port_in_use_udp() {
  local p="$1"
  ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"
}

check_port_range_free() {
  local start="$1" end="$2" proto="$3" p used=0
  [ "$start" = "0" ] && [ "$end" = "0" ] && return 0
  for ((p=start; p<=end; p++)); do
    if [ "$proto" = "tcp" ]; then
      if port_in_use_tcp "$p"; then echo "$p"; used=1; fi
    else
      if port_in_use_udp "$p"; then echo "$p"; used=1; fi
    fi
  done
  return "$used"
}

validate_create_args() {
  local name="$1" cpu="$2" mem="$3" disk="$4" sshport="$5" startport="$6" endport="$7" down="$8" up="$9" ipv6="${10}"

  valid_name "$name" || { err "容器名称不合法，只能使用字母、数字、点、下划线、短横线。"; return 1; }
  valid_num "$cpu" && [ "$cpu" -ge 1 ] || { err "CPU 核数必须是 >=1 的数字。"; return 1; }
  valid_num "$mem" && [ "$mem" -ge 64 ] || { err "内存大小必须是 >=64 的数字，单位 MB。"; return 1; }
  valid_num "$disk" && [ "$disk" -ge 1 ] || { err "硬盘大小必须是 >=1 的数字，单位 GB。"; return 1; }
  valid_num "$sshport" && [ "$sshport" -ge 1 ] && [ "$sshport" -le 65535 ] || { err "SSH 端口必须是 1-65535。"; return 1; }
  valid_num "$startport" && valid_num "$endport" || { err "外网起止端口必须是数字。"; return 1; }
  if { [ "$startport" = "0" ] && [ "$endport" != "0" ]; } || { [ "$startport" != "0" ] && [ "$endport" = "0" ]; }; then
    err "外网端口区间要么都填 0，要么都填有效端口。"
    return 1
  fi
  if [ "$startport" != "0" ]; then
    [ "$startport" -ge 1 ] && [ "$endport" -le 65535 ] && [ "$startport" -le "$endport" ] || { err "外网端口区间不合法。"; return 1; }
  fi
  [ "$down" != "INVALID" ] && [ "$up" != "INVALID" ] || { err "上下行限速必须是数字，单位 Mbps；0 表示不限制。"; return 1; }
  [[ "$ipv6" =~ ^[YyNn]$ ]] || { err "是否启用 IPv6 只能填写 Y 或 N。"; return 1; }
  if lxc list --format csv -c n 2>/dev/null | grep -Fxq "$name"; then
    err "容器 ${name} 已存在。"
    return 1
  fi
  if port_in_use_tcp "$sshport"; then
    err "宿主机 TCP ${sshport} 已被占用。"
    return 1
  fi
  if [ "$startport" != "0" ]; then
    if [ "$sshport" -ge "$startport" ] && [ "$sshport" -le "$endport" ]; then
      err "SSH 端口不能落在业务端口区间内。"
      return 1
    fi
    local bad_tcp bad_udp
    bad_tcp="$(check_port_range_free "$startport" "$endport" tcp | tr '\n' ' ')"
    bad_udp="$(check_port_range_free "$startport" "$endport" udp | tr '\n' ' ')"
    if [ -n "$bad_tcp" ]; then
      err "以下 TCP 业务端口已占用：$bad_tcp"
      return 1
    fi
    if [ -n "$bad_udp" ]; then
      warn "以下 UDP 端口已被监听，可能冲突：$bad_udp"
      read -r -p "是否继续？[y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || return 1
    fi
  fi
  return 0
}

random_password() {
  tr -dc 'A-Za-z0-9_@%+=' </dev/urandom | head -c 18
  echo
}

wait_container_ready() {
  local name="$1" i
  for i in $(seq 1 60); do
    if lxc exec "$name" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

install_ssh_in_container() {
  local name="$1" rootpass="$2"
  info "正在容器 ${name} 内安装和配置 SSH。"

  lxc exec "$name" -- sh -c '
    set -e
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y openssh-server sudo curl ca-certificates
      mkdir -p /run/sshd
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y openssh-server sudo curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
      yum install -y openssh-server sudo curl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache openssh sudo curl ca-certificates
      ssh-keygen -A || true
    else
      echo "不支持的容器包管理器" >&2
      exit 1
    fi
  ' || return 1

  printf 'root:%s\n' "$rootpass" | lxc exec "$name" -- chpasswd || return 1

  lxc exec "$name" -- sh -c '
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-lxdnat.conf <<SSHEOF
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
SSHEOF
    if [ -f /etc/ssh/sshd_config ]; then
      sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/g" /etc/ssh/sshd_config || true
      sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/g" /etc/ssh/sshd_config || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
      rc-update add sshd default 2>/dev/null || true
      rc-service sshd restart 2>/dev/null || true
    else
      service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
    fi
  ' || return 1

  ok "SSH 配置完成。"
}

apply_resources() {
  local name="$1" cpu="$2" mem="$3" disk="$4" down="$5" up="$6" ipv6="$7"

  info "设置资源限制：CPU=${cpu}核 内存=${mem}MB 硬盘=${disk}GB"
  lxc config set "$name" limits.cpu "$cpu" || warn "CPU 限制设置失败。"
  lxc config set "$name" limits.memory "${mem}MB" || warn "内存限制设置失败。"
  lxc config set "$name" boot.autostart true || true
  lxc config device override "$name" root size="${disk}GB" >/dev/null 2>&1 || warn "硬盘限制设置失败，当前存储后端可能不支持 quota。"

  if [ "$down" != "0" ] || [ "$up" != "0" ]; then
    info "设置网速限制：下载=${down}Mbps 上传=${up}Mbps"
    lxc config device override "$name" eth0 >/dev/null 2>&1 || true
    [ "$down" != "0" ] && lxc config device set "$name" eth0 limits.ingress "${down}Mbit" >/dev/null 2>&1 || true
    [ "$up" != "0" ] && lxc config device set "$name" eth0 limits.egress "${up}Mbit" >/dev/null 2>&1 || true
  fi

  if [[ "$ipv6" =~ ^[Nn]$ ]]; then
    info "尝试在容器内关闭 IPv6。"
    lxc exec "$name" -- sh -c '
      cat >/etc/sysctl.d/99-disable-ipv6.conf <<EOFV6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOFV6
      sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true
    ' >/dev/null 2>&1 || true
  fi
}

add_proxy_devices() {
  local name="$1" sshport="$2" startport="$3" endport="$4"
  info "添加 SSH 端口映射：宿主机 ${sshport} -> 容器 22/TCP"
  lxc config device add "$name" lmgr_ssh proxy listen="tcp:0.0.0.0:${sshport}" connect="tcp:127.0.0.1:22" || return 1

  if [ "$startport" != "0" ] && [ "$endport" != "0" ]; then
    info "添加业务端口映射：${startport}-${endport}/TCP + UDP，同端口转发。"
    lxc config device add "$name" lmgr_tcp proxy listen="tcp:0.0.0.0:${startport}-${endport}" connect="tcp:127.0.0.1:${startport}-${endport}" || return 1
    lxc config device add "$name" lmgr_udp proxy listen="udp:0.0.0.0:${startport}-${endport}" connect="udp:127.0.0.1:${startport}-${endport}" || warn "UDP 端口映射失败，TCP 已保留。"
  fi
}

remove_managed_proxy_devices() {
  local name="$1"
  for dev in lmgr_ssh lmgr_tcp lmgr_udp; do
    if lxc config device show "$name" 2>/dev/null | grep -q "^${dev}:"; then
      lxc config device remove "$name" "$dev" >/dev/null 2>&1 || true
    fi
  done
}

record_container() {
  local name="$1" cpu="$2" mem="$3" disk="$4" sshport="$5" startport="$6" endport="$7" down="$8" up="$9" ipv6="${10}" image="${11}"
  safe_mkdir
  grep -v "^${name}|" "$STATE_FILE" 2>/dev/null >"${STATE_FILE}.tmp" || true
  mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "${name}|cpu=${cpu}|mem=${mem}MB|disk=${disk}GB|ssh=${sshport}|ports=${startport}-${endport}|down=${down}Mbps|up=${up}Mbps|ipv6=${ipv6}|image=${image}|created=$(date '+%F %T')" >>"$STATE_FILE"
}

create_container() {
  show_header
  echo "---------------------创建 NAT 小鸡---------------------"
  install_lxd_if_needed || { pause; return; }
  if ! is_lxd_initialized; then
    warn "LXD 尚未初始化，请先执行菜单 1 快速初始化。"
    pause
    return
  fi

  local name cpu mem disk sshport startport endport down up ipv6 sys image rootpass
  read -r -p "容器名称：" name
  read -r -p "CPU核数 [1]：" cpu; cpu="${cpu:-1}"
  read -r -p "内存大小MB [256]：" mem; mem="${mem:-256}"
  read -r -p "硬盘大小GB [2]：" disk; disk="${disk:-2}"
  read -r -p "SSH宿主机端口：" sshport
  read -r -p "外网起端口，0表示不映射业务端口 [0]：" startport; startport="${startport:-0}"
  read -r -p "外网止端口，0表示不映射业务端口 [0]：" endport; endport="${endport:-0}"
  read -r -p "下载速度Mbps，0表示不限制 [0]：" down; down="$(normalize_mbps "$down")"
  read -r -p "上传速度Mbps，0表示不限制 [0]：" up; up="$(normalize_mbps "$up")"
  read -r -p "是否启用IPv6(Y/N) [N]：" ipv6; ipv6="${ipv6:-N}"
  read -r -p "系统，留空则为debian11 [debian11]：" sys; sys="${sys:-$DEFAULT_SYSTEM}"
  image="$(system_to_image "$sys")"
  echo
  read -r -s -p "root密码，留空自动生成：" rootpass
  echo
  if [ -z "$rootpass" ]; then
    rootpass="$(random_password)"
  fi

  validate_create_args "$name" "$cpu" "$mem" "$disk" "$sshport" "$startport" "$endport" "$down" "$up" "$ipv6" || { pause; return; }

  echo
  echo "即将创建："
  echo "  名称：$name"
  echo "  镜像：$image"
  echo "  CPU/内存/硬盘：${cpu}核 / ${mem}MB / ${disk}GB"
  echo "  SSH：宿主机:${sshport} -> 容器:22"
  echo "  业务端口：${startport}-${endport}"
  echo "  限速：下载 ${down}Mbps / 上传 ${up}Mbps"
  echo "  IPv6：$ipv6"
  echo
  confirm "确认创建容器 ${name}？" || { warn "已取消。"; pause; return; }

  info "拉取镜像并创建容器，首次可能较慢。"
  lxc launch "$image" "$name" || {
    err "容器创建失败。请检查镜像名、网络、存储池。"
    pause
    return
  }

  if ! wait_container_ready "$name"; then
    warn "容器已创建，但暂时无法 exec。请稍后手动检查：lxc info ${name}"
  fi

  apply_resources "$name" "$cpu" "$mem" "$disk" "$down" "$up" "$ipv6"
  install_ssh_in_container "$name" "$rootpass" || warn "SSH 自动安装失败，你仍可使用 lxc exec ${name} -- bash 进入手动修复。"
  add_proxy_devices "$name" "$sshport" "$startport" "$endport" || warn "端口映射添加失败，请查看容器设备配置。"
  record_container "$name" "$cpu" "$mem" "$disk" "$sshport" "$startport" "$endport" "$down" "$up" "$ipv6" "$image"

  echo
  ok "创建完成。"
  echo "SSH 登录：ssh root@宿主机IP -p ${sshport}"
  echo "root 密码：${rootpass}"
  echo
  warn "请保存好 root 密码；脚本不会明文持久保存密码。"
  pause
}

list_containers() {
  show_header
  echo "---------------------小鸡列表---------------------"
  if ! cmd_exists lxc; then
    err "未安装 lxc。"
    pause
    return
  fi
  lxc list
  echo
  if [ -s "$STATE_FILE" ]; then
    echo "---------------------脚本创建记录---------------------"
    cat "$STATE_FILE"
  fi
  pause
}

select_container() {
  local prompt="${1:-请输入容器名称：}" name
  read -r -p "$prompt" name
  if [ -z "$name" ]; then
    err "容器名称不能为空。"
    return 1
  fi
  if ! lxc list --format csv -c n 2>/dev/null | grep -Fxq "$name"; then
    err "容器不存在：$name"
    return 1
  fi
  echo "$name"
}

show_container_info() {
  show_header
  echo "---------------------查看小鸡信息---------------------"
  local name
  name="$(select_container)" || { pause; return; }
  echo
  lxc info "$name" || true
  echo
  echo "---------------------资源配置---------------------"
  lxc config show "$name" --expanded 2>/dev/null | sed -n '/^config:/,/^devices:/p' || true
  echo
  echo "---------------------设备/端口映射---------------------"
  lxc config device show "$name" || true
  echo
  echo "---------------------容器内 IP---------------------"
  lxc list "$name" -c ns4tS
  pause
}

start_container() {
  show_header
  local name
  name="$(select_container "要启动的容器名称：")" || { pause; return; }
  lxc start "$name" && ok "已启动：$name" || err "启动失败：$name"
  pause
}

stop_container() {
  show_header
  local name
  name="$(select_container "要停止的容器名称：")" || { pause; return; }
  warn "停止容器会中断该小鸡内的服务。"
  confirm "确认停止 ${name}？" || { warn "已取消。"; pause; return; }
  lxc stop "$name" --timeout 30 || lxc stop "$name" --force
  ok "已停止：$name"
  pause
}

restart_container() {
  show_header
  local name
  name="$(select_container "要重启的容器名称：")" || { pause; return; }
  warn "重启容器会短暂中断该小鸡内的服务。"
  confirm "确认重启 ${name}？" || { warn "已取消。"; pause; return; }
  lxc restart "$name" && ok "已重启：$name" || err "重启失败：$name"
  pause
}

delete_container() {
  show_header
  local name
  name="$(select_container "要销毁的容器名称：")" || { pause; return; }
  warn "危险操作：销毁容器会删除该小鸡系统和数据。"
  warn "建议先确认无重要数据，或先手动快照/备份。"
  confirm "确认永久销毁 ${name}？" || { warn "已取消。"; pause; return; }
  lxc delete "$name" --force && {
    safe_mkdir
    grep -v "^${name}|" "$STATE_FILE" 2>/dev/null >"${STATE_FILE}.tmp" || true
    mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
    ok "已销毁：$name"
  } || err "销毁失败：$name"
  pause
}

enter_container() {
  show_header
  local name
  name="$(select_container "要进入的容器名称：")" || { pause; return; }
  info "退出容器请输入 exit。"
  lxc exec "$name" -- bash || lxc exec "$name" -- sh
  pause
}

reconfigure_ports() {
  show_header
  echo "---------------------重配端口映射---------------------"
  local name sshport startport endport
  name="$(select_container "要重配端口的容器名称：")" || { pause; return; }
  read -r -p "新的 SSH 宿主机端口：" sshport
  read -r -p "新的外网起端口，0表示不映射业务端口 [0]：" startport; startport="${startport:-0}"
  read -r -p "新的外网止端口，0表示不映射业务端口 [0]：" endport; endport="${endport:-0}"

  valid_num "$sshport" && [ "$sshport" -ge 1 ] && [ "$sshport" -le 65535 ] || { err "SSH端口不合法。"; pause; return; }
  valid_num "$startport" && valid_num "$endport" || { err "业务端口必须是数字。"; pause; return; }
  if [ "$startport" != "0" ]; then
    [ "$startport" -ge 1 ] && [ "$endport" -le 65535 ] && [ "$startport" -le "$endport" ] || { err "业务端口区间不合法。"; pause; return; }
  fi

  warn "会删除脚本管理的旧端口映射 lmgr_ssh/lmgr_tcp/lmgr_udp，然后添加新映射。"
  confirm "确认重配 ${name} 的端口？" || { warn "已取消。"; pause; return; }
  remove_managed_proxy_devices "$name"
  add_proxy_devices "$name" "$sshport" "$startport" "$endport" && ok "端口映射已更新。" || err "端口映射更新失败。"
  pause
}

modify_resources() {
  show_header
  echo "---------------------修改资源限制---------------------"
  local name cpu mem disk down up ipv6
  name="$(select_container "要修改资源的容器名称：")" || { pause; return; }
  read -r -p "CPU核数，留空不改：" cpu
  read -r -p "内存MB，留空不改：" mem
  read -r -p "硬盘GB，留空不改：" disk
  read -r -p "下载速度Mbps，0不限，留空不改：" down
  read -r -p "上传速度Mbps，0不限，留空不改：" up
  read -r -p "IPv6 Y/N，留空不改：" ipv6

  [ -n "$cpu" ] && { valid_num "$cpu" && lxc config set "$name" limits.cpu "$cpu" || warn "CPU 设置失败。"; }
  [ -n "$mem" ] && { valid_num "$mem" && lxc config set "$name" limits.memory "${mem}MB" || warn "内存设置失败。"; }
  [ -n "$disk" ] && { valid_num "$disk" && lxc config device override "$name" root size="${disk}GB" || warn "硬盘设置失败。"; }
  if [ -n "$down" ] || [ -n "$up" ]; then
    lxc config device override "$name" eth0 >/dev/null 2>&1 || true
    [ -n "$down" ] && { down="$(normalize_mbps "$down")"; [ "$down" != "INVALID" ] && lxc config device set "$name" eth0 limits.ingress "${down}Mbit" || warn "下载限速设置失败。"; }
    [ -n "$up" ] && { up="$(normalize_mbps "$up")"; [ "$up" != "INVALID" ] && lxc config device set "$name" eth0 limits.egress "${up}Mbit" || warn "上传限速设置失败。"; }
  fi
  if [[ "$ipv6" =~ ^[Nn]$ ]]; then
    lxc exec "$name" -- sh -c 'echo net.ipv6.conf.all.disable_ipv6=1 >/etc/sysctl.d/99-disable-ipv6.conf; sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
  fi
  ok "资源修改流程结束。"
  pause
}

snapshot_container() {
  show_header
  local name snap
  name="$(select_container "要快照的容器名称：")" || { pause; return; }
  snap="snap-$(date +%Y%m%d-%H%M%S)"
  lxc snapshot "$name" "$snap" && ok "已创建快照：${name}/${snap}" || err "快照失败。"
  pause
}

show_logs_and_diag() {
  show_header
  echo "---------------------诊断信息---------------------"
  echo "LXD 版本："
  lxc --version 2>/dev/null || true
  echo
  echo "LXD 信息："
  lxc info 2>/dev/null | head -n 80 || true
  echo
  echo "实例列表："
  lxc list 2>/dev/null || true
  echo
  echo "端口监听："
  ss -lntup 2>/dev/null | head -n 80 || true
  echo
  echo "最近 LXD 日志："
  journalctl -u snap.lxd.daemon --no-pager -n 80 2>/dev/null || journalctl -u lxd --no-pager -n 80 2>/dev/null || true
  pause
}

print_ssh_info() {
  show_header
  local name
  name="$(select_container "要查看 SSH 信息的容器名称：")" || { pause; return; }
  echo "---------------------SSH 信息---------------------"
  lxc config device show "$name" | awk '
    /^lmgr_ssh:/ {inssh=1; next}
    /^[a-zA-Z0-9_-]+:/ && inssh {inssh=0}
    inssh && /listen:/ {print}
  '
  echo
  echo "如果 listen 显示 tcp:0.0.0.0:25035，则连接方式："
  echo "  ssh root@宿主机IP -p 25035"
  echo
  warn "root 密码只在创建时显示；忘记后可用菜单 14 重置。"
  pause
}

reset_root_password() {
  show_header
  local name pass
  name="$(select_container "要重置 root 密码的容器名称：")" || { pause; return; }
  read -r -s -p "新 root 密码，留空自动生成：" pass
  echo
  [ -z "$pass" ] && pass="$(random_password)"
  printf 'root:%s\n' "$pass" | lxc exec "$name" -- chpasswd && {
    ok "root 密码已重置。"
    echo "新密码：$pass"
  } || err "重置失败。"
  pause
}

remove_alias() {
  show_header
  warn "这里只删除管理命令 ${INSTALL_PATH}，不会删除 LXD，也不会删除任何容器。"
  confirm "确认删除管理命令？" || { warn "已取消。"; pause; return; }
  rm -f "$INSTALL_PATH" && ok "已删除 ${INSTALL_PATH}" || err "删除失败。"
  pause
}

menu() {
  need_root
  safe_mkdir
  while true; do
    show_header
    echo "  1) 快速初始化 LXD 环境"
    echo "  2) 创建 NAT 小鸡"
    echo "  3) 查看小鸡列表"
    echo "  4) 查看小鸡详细信息"
    echo "  5) 启动小鸡"
    echo "  6) 停止小鸡"
    echo "  7) 重启小鸡"
    echo "  8) 进入小鸡 Shell"
    echo "  9) 销毁小鸡"
    echo " 10) 重配端口映射"
    echo " 11) 修改资源限制"
    echo " 12) 创建快照"
    echo " 13) 查看诊断/日志"
    echo " 14) 重置小鸡 root 密码"
    echo " 15) 显示 SSH 连接信息"
    echo " 16) 只读环境检查"
    echo " 17) 安装/修复 lxdnat 管理命令"
    echo " 18) 删除 lxdnat 管理命令"
    echo "  0) 退出"
    echo "------------------------------------------------------------"
    read -r -p "请输入选项 [0-18]：" choice
    case "$choice" in
      1) quick_init_lxd ;;
      2) create_container ;;
      3) list_containers ;;
      4) show_container_info ;;
      5) start_container ;;
      6) stop_container ;;
      7) restart_container ;;
      8) enter_container ;;
      9) delete_container ;;
      10) reconfigure_ports ;;
      11) modify_resources ;;
      12) snapshot_container ;;
      13) show_logs_and_diag ;;
      14) reset_root_password ;;
      15) print_ssh_info ;;
      16) precheck_readonly ;;
      17) install_alias ;;
      18) remove_alias ;;
      0) exit 0 ;;
      *) warn "无效选项。"; sleep 1 ;;
    esac
  done
}

menu "$@"
