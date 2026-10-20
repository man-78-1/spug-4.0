#!/usr/bin/env bash
# Spug 一键启停：本地开发栈 + 答辩服务器上的 Spug 进程
#
#   bash deploy/spug-ctl.sh status            # 两边状态（不带参数默认就是它）
#   bash deploy/spug-ctl.sh up                # 两边都起
#   bash deploy/spug-ctl.sh down              # 两边都停
#   bash deploy/spug-ctl.sh local up|down|status
#   bash deploy/spug-ctl.sh server up|down|status|restart|logs [api|ws|worker|scheduler|monitor]
#   bash deploy/spug-ctl.sh server check      # 从本机探公网链路：首页 / /api / WebSocket 握手
#
# 服务器可用 SPUG_SERVER 覆盖默认地址：SPUG_SERVER=1.2.3.4 bash deploy/spug-ctl.sh server status
# 注意：这里只启停 Spug 自己的进程，服务器上的 nginx / MariaDB / Redis 保持运行；
#       关闭 ECS 实例本身要去阿里云控制台，脚本做不到，也不该顺手做。

SERVER=${SPUG_SERVER:-8.138.44.106}
SPUG_DIR=${SPUG_DIR:-/data/spug}
API="${SERVER_USER:-root}@${SERVER}"
LOGS="$SPUG_DIR/spug_api/logs"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$API")

Repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
Api="$Repo/spug_api"

say() { printf '[spug-ctl] %s\n' "$*"; }
die() { printf '[spug-ctl] 错误：%s\n' "$*" >&2; exit 1; }

# ---------- 本地 ----------
port_listening() { netstat -ano 2>/dev/null | grep LISTENING | grep -Eq ":$1[[:space:]]"; }

local_status() {
    local up=0
    for p in 8000 3000; do
        if port_listening "$p"; then say "本地 :$p 在监听"; up=$((up + 1)); else say "本地 :$p 未监听"; fi
    done
    [ "$up" = 2 ] && say "本地开发栈：运行中（入口 http://127.0.0.1:3000，admin/admin123）" \
                  || say "本地开发栈：未完全启动（api 与前端要分别在跑）"
}

local_up() {
    [ -d "$Api" ] || die "找不到 $Api"
    (cd "$Api" && bash tools/dev-start.sh)
    say "本地已提交启动；前端首次编译要 1-2 分钟，用 'local status' 复查 :3000"
}

local_down() { (cd "$Api" && bash tools/dev-stop.sh); local_status; }

# ---------- 服务器 ----------
server_run() {
    local out err noise errf rc
    errf=$(mktemp)
    out=$("${SSH[@]}" "$@" 2>"$errf"); rc=$?
    err=$(grep -vE 'post-quantum|store now|may need to be upgraded|^[[:space:]]*$' "$errf")
    rm -f "$errf"
    # 只认 ssh 自己的 255（连不上/认证失败）；supervisorctl、grep -c 在"有停止项/零命中"时
    # 本来就会返回非 0，不能拿它们的退出码当连接故障
    if [ "$rc" = 255 ]; then
        die "连不上 $API（ssh 退出码 255）—— 去阿里云控制台确认实例是否在运行、安全组是否放行 22"
    fi
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    printf '%s\n' "$out"
}

server_status() { server_run "supervisorctl status"; }
server_up()     { server_run "supervisorctl start all && sleep 2 && supervisorctl status"; }
server_down()   {
    server_run "supervisorctl stop all && supervisorctl status"
    say "只停了 Spug 五个进程；nginx/MariaDB/Redis 仍在跑。要关整台实例请在控制台操作。"
}
server_restart() {
    local target=${1:-all}
    server_run "supervisorctl restart $target && sleep 1 && supervisorctl status $target"
}
server_logs() {
    local name=${1:-api}
    case "$name" in api|ws|worker|scheduler|monitor) ;; *) die "日志名只能是 api/ws/worker/scheduler/monitor" ;; esac
    server_run "tail -n 40 $LOGS/$name.log; echo '--- Traceback 计数 ---'; grep -c Traceback $LOGS/$name.log"
}

# 从本机验证公网链路：nginx 静态页、api 鉴权、daphne 的 WebSocket 握手
server_check() {
    local code key
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$SERVER/" || echo 超时)
    say "首页 http://$SERVER/ -> $code（期望 200）"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$SERVER/api/config/basic/" || echo 超时)
    say "接口 /api/config/basic/ -> $code（期望 401，说明 nginx→gunicorn→Django 通了且鉴权在视图之前）"
    key=$(head -c16 /dev/urandom | base64)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
              -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
              -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $key" \
              "http://$SERVER/api/ws/notify/" || echo 超时)
    say "WebSocket /api/ws/notify/ -> $code（期望 101）"
}

# ---------- 入口 ----------
case "${1:-status}" in
    up)     local_up;   server_up ;;
    down)   local_down; server_down ;;
    status) local_status; say '--- 服务器 ---'; server_status ;;
    local)  case "${2:-status}" in
                up) local_up ;; down) local_down ;; status) local_status ;;
                *) die "local 子命令：up|down|status" ;;
            esac ;;
    server) shift; case "${1:-status}" in
                up) server_up ;; down) server_down ;; status) server_status ;;
                restart) server_restart "${2:-all}" ;;
                logs) server_logs "${2:-api}" ;;
                check) server_check ;;
                *) die "server 子命令：up|down|status|restart|logs|check" ;;
            esac ;;
    *) die "用法：bash deploy/spug-ctl.sh [up|down|status|local ...|server ...]" ;;
esac
