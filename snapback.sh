#!/usr/bin/env bash
# snapback — Debian 整机备份到 Google Drive(restic + rclone),一键定时备份 / 一键恢复
#
#   bash snapback.sh install     首次安装:装依赖、授权 Google Drive、建仓库、装每日定时任务
#   snapback backup              立即备份一次
#   snapback list                列出所有快照
#   snapback restore             交互式恢复(恢复到目录 / 恢复某个路径 / 整机恢复)
#   snapback status              查看定时任务、上次结果、仓库占用
#   snapback panel               (可选)安装 Backrest 网页面板,只监听 127.0.0.1:9898
#   snapback uninstall           移除定时任务和命令(保留配置与密码)

set -Eeuo pipefail
umask 077

CONF_DIR=/etc/snapback
CONF=$CONF_DIR/config
PASS_FILE=$CONF_DIR/password
STATUS_FILE=$CONF_DIR/last_status
DUMP_DIR=/var/backups/snapback
STAGE_DIR=/var/tmp/snapback-stage
LOG=/var/log/snapback.log
SELF=/usr/local/sbin/snapback

export RCLONE_CONFIG=$CONF_DIR/rclone.conf
export RESTIC_CACHE_DIR=/var/cache/restic

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_bld=$'\e[1m'; c_off=$'\e[0m'
info() { echo "${c_grn}==>${c_off} $*" >&2; }
warn() { echo "${c_yel}警告:${c_off} $*" >&2; }
die()  { echo "${c_red}错误:${c_off} $*" >&2; exit 1; }

ask() {
  local q=$1 def=${2-} ans
  if [[ -n $def ]]; then read -r -p "$q [$def]: " ans </dev/tty; else read -r -p "$q: " ans </dev/tty; fi
  echo "${ans:-$def}"
}

confirm() { [[ $(ask "$1 (y/N)" n) =~ ^[Yy]$ ]]; }

need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行(sudo -i 后再执行)"; }

load_conf() {
  [[ -f $CONF ]] || die "还没安装,先运行:bash snapback.sh install"
  # shellcheck source=/dev/null
  source "$CONF"
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

# ---------------------------------------------------------------- install

install_deps() {
  info "安装依赖(restic、rclone、rsync)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq restic rclone rsync bzip2 curl ca-certificates >/dev/null
  restic self-update >/dev/null 2>&1 || true
  mkdir -p -m 700 "$CONF_DIR" "$RESTIC_CACHE_DIR"
}

setup_gdrive() {
  if [[ -f $RCLONE_CONFIG ]] && rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1; then
    info "Google Drive 已授权,跳过"
    return
  fi

  echo >&2
  echo "用自己的 Google OAuth 客户端(推荐,不和别人共用配额);留空则用 rclone 自带的公共客户端" >&2
  local cid csec opts
  cid=$(ask "Client ID(xxx.apps.googleusercontent.com,可留空)")
  if [[ -n $cid ]]; then
    read -r -s -p "Client Secret: " csec </dev/tty; echo >&2
    [[ -n $csec ]] || die "填了 Client ID 就必须填 Client Secret"
    opts=$(printf '{"client_id":"%s","client_secret":"%s","scope":"drive.file"}' "$cid" "$csec")
  else
    opts='{"scope":"drive.file"}'
  fi
  local blob
  blob=$(printf '%s' "$opts" | base64 -w0 | tr -d '=')

  cat >&2 <<EOF

${c_bld}授权 Google Drive${c_off}(权限范围 drive.file:只能访问备份程序自己创建的文件)
服务器没有浏览器,需要在你自己的电脑上完成一次授权:
  1. 电脑上装好 rclone(Mac:brew install rclone)
  2. 电脑终端运行下面这一整行:
     ${c_bld}rclone authorize "drive" "$blob"${c_off}
  3. 浏览器里登录 Google 并点「允许」(自建客户端会提示「未经验证的应用」,点「继续」)
  4. 终端会在 "Paste the following" 和 "<---End paste" 之间输出一行 {"access_token":...}
     把这一整行复制粘贴到下面

EOF
  local token
  token=$(ask "粘贴 token JSON")
  [[ $token == \{*\} ]] || die "看起来不是 token JSON(应以 { 开头、} 结尾)"
  {
    echo "[gdrive]"
    echo "type = drive"
    echo "scope = drive.file"
    if [[ -n $cid ]]; then
      echo "client_id = $cid"
      echo "client_secret = $csec"
    fi
    echo "token = $token"
  } >"$RCLONE_CONFIG"
  rclone lsd gdrive: --max-depth 1 >/dev/null || die "连不上 Google Drive,token 可能无效,重新运行 install 再试"
  info "Google Drive 授权成功"
}

write_config() {
  local repo=$1 schedule=$2
  cat >"$CONF" <<EOF
# snapback 配置,改完立即生效(定时时间改了要重新运行 snapback install)
RESTIC_REPOSITORY="$repo"
RESTIC_PASSWORD_FILE="$PASS_FILE"

# 备份哪些路径(空格分隔)
BACKUP_PATHS="/"
# 排除哪些路径
EXCLUDES="/proc /sys /dev /run /tmp /mnt /media /lost+found /swapfile /var/tmp /var/cache/apt/archives /var/lib/docker/overlay2/*/merged $RESTIC_CACHE_DIR"

# 保留策略
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# 每天几点备份(systemd OnCalendar 格式)
SCHEDULE="$schedule"

# 备份前自动导出 MySQL/MariaDB/PostgreSQL(yes/no)
DUMP_DB=yes
EOF
}

install_timer() {
  cat >/etc/systemd/system/snapback.service <<EOF
[Unit]
Description=snapback backup to Google Drive
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF backup
Nice=10
IOSchedulingClass=idle
EOF
  cat >/etc/systemd/system/snapback.timer <<EOF
[Unit]
Description=snapback daily backup

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now snapback.timer >/dev/null
}

cmd_install() {
  need_root
  [[ -f /etc/debian_version ]] || die "只支持 Debian / Ubuntu"

  local src
  src=$(readlink -f "$0")
  [[ -f $src && $src != "$SELF" ]] && install -m 755 "$src" "$SELF"

  install_deps
  setup_gdrive

  echo >&2
  echo "  1) 新建备份仓库(这台机器第一次用)" >&2
  echo "  2) 连接已有仓库(新机器上恢复旧机器的备份)" >&2
  local mode repo
  mode=$(ask "选择" 1)
  repo="rclone:gdrive:snapback/$(ask "Google Drive 里的仓库目录名" "$(hostname)")"

  if [[ $mode == 2 ]]; then
    local pw
    read -r -s -p "输入旧仓库的密码: " pw </dev/tty; echo >&2
    printf '%s' "$pw" >"$PASS_FILE"
  elif [[ ! -s $PASS_FILE ]]; then
    head -c 24 /dev/urandom | base64 | tr -d '\n' >"$PASS_FILE"
  fi

  local hh schedule
  hh=$(ask "每天几点备份(0-23)" 3)
  schedule="*-*-* $(printf '%02d' "$hh"):00:00"
  [[ -f $CONF ]] && cp "$CONF" "$CONF.bak"
  write_config "$repo" "$schedule"
  load_conf

  if restic cat config >/dev/null 2>&1; then
    info "仓库已存在,已连接:$repo"
  elif [[ $mode == 2 ]]; then
    die "找不到仓库或密码不对:$repo"
  else
    info "初始化仓库:$repo"
    restic init >/dev/null
  fi

  install_timer
  info "定时任务已启用:每天 $(printf '%02d' "$hh"):00 左右自动备份"

  cat >&2 <<EOF

${c_bld}${c_yel}======== 重要:请把仓库密码抄到密码管理器 ========${c_off}
  仓库:$repo
  密码:${c_bld}$(cat "$PASS_FILE")${c_off}
  机器坏了时,只有靠这个密码 + Google 账号才能恢复。密码丢了备份就打不开。
${c_yel}=================================================${c_off}

常用命令:
  snapback backup     立即备份
  snapback list       查看快照
  snapback restore    恢复
  snapback status     查看状态
  配置文件:$CONF
EOF
  if [[ $mode != 2 ]] && confirm "现在就做第一次备份吗?"; then
    cmd_backup
  fi
}

# ---------------------------------------------------------------- backup

dump_databases() {
  rm -rf "$DUMP_DIR"
  mkdir -p -m 700 "$DUMP_DIR"
  [[ ${DUMP_DB:-yes} == yes ]] || return 0

  if command -v mysqldump >/dev/null && { systemctl is-active -q mariadb || systemctl is-active -q mysql; } 2>/dev/null; then
    info "导出 MySQL/MariaDB"
    mysqldump --all-databases --single-transaction --routines --events --triggers >"$DUMP_DIR/mysql-all.sql" \
      || warn "MySQL 导出失败(root 可能需要密码,可在 /root/.my.cnf 里配置)"
  fi
  if command -v pg_dumpall >/dev/null && systemctl is-active -q postgresql 2>/dev/null; then
    info "导出 PostgreSQL"
    runuser -u postgres -- pg_dumpall >"$DUMP_DIR/postgres-all.sql" || warn "PostgreSQL 导出失败"
  fi
}

cmd_backup() {
  need_root
  load_conf
  exec > >(tee -a "$LOG") 2>&1
  info "$(date '+%F %T') 开始备份 → $RESTIC_REPOSITORY"

  dump_databases

  local ex=() e rc=0
  set -f  # 排除规则里的 * 交给 restic,不让 shell 展开
  for e in $EXCLUDES; do ex+=(--exclude "$e"); done
  set +f
  # shellcheck disable=SC2086
  restic backup $BACKUP_PATHS "${ex[@]}" --exclude-caches --tag snapback || rc=$?

  if [[ $rc -eq 3 ]]; then
    warn "有部分文件读不到,快照已生成但不完整(详见上方输出)"
  elif [[ $rc -ne 0 ]]; then
    echo "FAIL $(date '+%F %T') restic 退出码 $rc" >"$STATUS_FILE"
    die "备份失败(退出码 $rc)"
  fi

  info "清理旧快照(保留 ${KEEP_DAILY} 天 / ${KEEP_WEEKLY} 周 / ${KEEP_MONTHLY} 月)"
  restic forget --tag snapback --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" --prune --max-unused 10% >/dev/null || warn "清理旧快照失败,下次会重试"

  echo "OK $(date '+%F %T')" >"$STATUS_FILE"
  info "$(date '+%F %T') 备份完成"
}

# ---------------------------------------------------------------- restore

stop_services() {
  local s
  for s in docker mariadb mysql postgresql nginx apache2; do
    systemctl is-active -q "$s" 2>/dev/null && { info "停止 $s"; systemctl stop "$s"; }
  done
  return 0
}

restore_full() {
  local snap=$1 need avail

  need=$(restic stats "$snap" --mode restore-size --json | grep -o '"total_size":[0-9]*' | cut -d: -f2)
  mkdir -p "$STAGE_DIR"
  avail=$(( $(df --output=avail -k "$STAGE_DIR" | tail -1) * 1024 ))
  info "快照大小约 $((need / 1024 / 1024)) MB,可用空间 $((avail / 1024 / 1024)) MB"
  (( avail > need * 11 / 10 )) || die "磁盘空间不够先解压快照(需要约 1.1 倍快照大小)"

  cat >&2 <<EOF

${c_red}${c_bld}整机恢复会覆盖当前系统${c_off}(保留这台机器自己的磁盘挂载、网络配置、引导程序和 snapback 配置)。
建议在一台刚装好的、和原来同版本的 Debian 上做。
EOF
  [[ $(ask "确认请输入大写 YES") == YES ]] || die "已取消"

  info "下载快照到临时目录 $STAGE_DIR"
  restic restore "$snap" --target "$STAGE_DIR"

  local old_ver new_ver
  old_ver=$(cut -d. -f1 "$STAGE_DIR/etc/debian_version" 2>/dev/null || echo "?")
  new_ver=$(cut -d. -f1 /etc/debian_version)
  if [[ $old_ver != "$new_ver" ]]; then
    warn "备份里是 Debian $old_ver,当前是 Debian $new_ver,版本不同整机恢复很可能起不来"
    confirm "仍然继续?" || die "已取消(临时文件在 $STAGE_DIR)"
  fi

  stop_services
  info "写回系统文件"
  local rc=0
  rsync -aAXH --numeric-ids --info=progress2 \
    --exclude=/etc/fstab --exclude=/etc/crypttab --exclude=/boot/grub --exclude=/boot/efi \
    --exclude=/etc/network/interfaces --exclude=/etc/network/interfaces.d \
    --exclude=/etc/netplan --exclude=/etc/systemd/network --exclude=/etc/resolv.conf \
    --exclude=/etc/cloud --exclude="$CONF_DIR" --exclude="$SELF" \
    "$STAGE_DIR"/ / || rc=$?
  case $rc in
    0) ;;
    23|24) warn "有少量文件没能写回(rsync 退出码 $rc),继续完成引导修复" ;;
    *) die "写回失败(rsync 退出码 $rc),先不要重启;临时文件在 $STAGE_DIR" ;;
  esac

  info "重建 initramfs 和 grub 引导菜单"
  update-initramfs -u -k all >/dev/null 2>&1 || warn "update-initramfs 失败"
  update-grub >/dev/null 2>&1 || warn "update-grub 失败"
  rm -rf "$STAGE_DIR"

  cat >&2 <<EOF

${c_grn}${c_bld}整机恢复完成,请重启:reboot${c_off}
重启后如果数据库起不来或数据不对,用备份时导出的 SQL 重新导入:
  MySQL/MariaDB: mysql < $DUMP_DIR/mysql-all.sql
  PostgreSQL:    runuser -u postgres -- psql -f $DUMP_DIR/postgres-all.sql
EOF
}

cmd_restore() {
  need_root
  load_conf
  restic snapshots
  local snap mode
  snap=$(ask "恢复哪个快照(填 ID)" latest)

  cat >&2 <<EOF

  1) 恢复到单独目录(安全,不动现有系统,自己挑文件拷回去)
  2) 恢复某个路径到原位置(比如 /etc/nginx 或 /var/www,会覆盖同名文件)
  3) 整机恢复(新机器 / 系统坏了时用)
EOF
  mode=$(ask "选择" 1)
  case $mode in
    1)
      local dir
      dir=$(ask "恢复到哪个目录" "/root/snapback-restore")
      restic restore "$snap" --target "$dir"
      info "已恢复到 $dir"
      ;;
    2)
      local path
      path=$(ask "要恢复的路径(绝对路径)")
      [[ $path == /* ]] || die "请填绝对路径"
      confirm "将用快照里的 $path 覆盖当前文件,确认?" || die "已取消"
      restic restore "$snap" --target / --include "$path"
      info "已恢复 $path"
      ;;
    3) restore_full "$snap" ;;
    *) die "无效选择" ;;
  esac
}

# ---------------------------------------------------------------- misc

cmd_list() { need_root; load_conf; restic snapshots; }

cmd_status() {
  need_root
  load_conf
  echo "仓库:     $RESTIC_REPOSITORY"
  echo "上次备份: $(cat "$STATUS_FILE" 2>/dev/null || echo '还没有')"
  echo "下次备份: $(systemctl list-timers snapback.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
  echo "日志:     $LOG(或 journalctl -u snapback)"
  echo
  restic stats --mode raw-data 2>/dev/null | grep -E 'Total Size|Snapshots' || true
}

cmd_panel() {
  need_root
  load_conf
  local arch
  case $(uname -m) in
    x86_64) arch=x86_64 ;;
    aarch64) arch=arm64 ;;
    *) die "不支持的架构 $(uname -m)" ;;
  esac
  info "下载 Backrest"
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/garethgeorge/backrest/releases/latest/download/backrest_Linux_${arch}.tar.gz" | tar -xz -C "$tmp"
  install -m 755 "$tmp/backrest" /usr/local/bin/backrest
  rm -rf "$tmp"

  cat >/etc/systemd/system/backrest.service <<EOF
[Unit]
Description=Backrest web UI
After=network-online.target

[Service]
Environment=BACKREST_PORT=127.0.0.1:9898
Environment=RCLONE_CONFIG=$RCLONE_CONFIG
Environment=HOME=/root
ExecStart=/usr/local/bin/backrest
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now backrest >/dev/null

  cat >&2 <<EOF

${c_grn}面板已启动${c_off},只监听本机 127.0.0.1:9898,不暴露到公网。
在你自己的电脑上运行:
  ssh -L 9898:localhost:9898 root@<服务器地址>
然后浏览器打开 http://localhost:9898 ,首次进入设置面板登录账号,再点「Add Repo」:
  Repository URI: $RESTIC_REPOSITORY
  Password:       $(cat "$PASS_FILE")
定时备份已由 snapback 负责,面板里只用来浏览快照、下载/恢复文件,不必再建 Plan。
EOF
}

cmd_uninstall() {
  need_root
  systemctl disable --now snapback.timer 2>/dev/null || true
  rm -f /etc/systemd/system/snapback.{service,timer} "$SELF"
  systemctl daemon-reload
  info "已移除定时任务和 snapback 命令。配置和密码仍在 $CONF_DIR,Google Drive 上的备份没有动。"
}

case ${1-} in
  install)   cmd_install ;;
  backup)    cmd_backup ;;
  restore)   cmd_restore ;;
  list)      cmd_list ;;
  status)    cmd_status ;;
  panel)     cmd_panel ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
