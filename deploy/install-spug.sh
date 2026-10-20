#!/bin/bash
# Spug 4.x 源码部署脚本（在 Linux 服务器上以 root 执行）
#
# 与 docs/install.sh 的区别：那份从 gitee clone 上游代码并下载官方编译好的前端产物，
# 这里部署的是你自己改过的源码——前端在本地 build 完随源码一起传上来，服务器不需要装 Node。
#
#   bash /data/spug/deploy/install-spug.sh
#
# 可用环境变量：SPUG_DIR ADMIN_USER ADMIN_PASSWORD DB_PASSWORD ALLOWED_HOSTS PIP_INDEX

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SPUG_DIR=${SPUG_DIR:-/data/spug}
API=$SPUG_DIR/spug_api
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
DB_PASSWORD=${DB_PASSWORD:-}
ALLOWED_HOSTS=${ALLOWED_HOSTS:-127.0.0.1}
PIP_INDEX=${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple/}

log() { echo "[spug] $*"; }
die() { echo "[spug] 错误：$*" >&2; exit 1; }

# pipefail 之下 `tr ... </dev/urandom | head -c N` 会因为 head 提前关闭管道而让 tr 收到
# SIGPIPE（退出码 141）从而中断整个脚本，所以先取有限字节再过滤。
rand() {
    head -c 256 /dev/urandom | tr -dc "$1" | cut -c1-"$2"
}

# Django 4.2 要求 Python ≥3.8；CentOS 8 的 python3 是 3.6，必须额外装 python39 之类。
find_python() {
    local py
    for py in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
        command -v "$py" >/dev/null 2>&1 || continue
        "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null || continue
        PYTHON=$(command -v "$py")
        return 0
    done
    return 1
}

# Django 4.2 的 check_database_version_supported 会拒绝 MariaDB <10.4（CentOS 8 默认给的是
# 10.3.28，updatedb 直接抛 NotSupportedError）。MySQL 8.x 与 MariaDB 10.4+ / 11.x 都算合格。
db_ver_ok() {
    local maj min
    maj=${1%%.*}
    min=${1#*.}
    min=${min%%.*}
    case "$maj" in ''|*[!0-9]*) return 1 ;; esac
    [ "$maj" -ge 11 ] && return 0                              # MariaDB 11+
    [ "$maj" -eq 10 ] && [ "${min:-0}" -ge 4 ] && return 0     # MariaDB 10.4+
    [ "$maj" -eq 8 ] && return 0                               # MySQL 8.x
    return 1
}

db_version() {
    mysql -N -e 'SELECT VERSION()' 2>/dev/null | tr -d '\r' | sed 's/-.*//'
}

[ "$(id -u)" -eq 0 ] || die "请用 root 执行"
[ -f "$API/manage.py" ] || die "找不到 $API/manage.py，请先用 deploy/upload-source.ps1 把源码传到 $SPUG_DIR"
[ -d "$SPUG_DIR/spug_web/build" ] || die "找不到 $SPUG_DIR/spug_web/build，前端还没 build 或没上传"

# ---------- 1. 系统依赖 ----------
. /etc/os-release
case " $ID ${ID_LIKE:-} " in
    *debian*|*ubuntu*)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y git curl mariadb-server libmariadb-dev python3-dev python3-venv \
            gcc pkg-config libsasl2-dev libldap2-dev libssl-dev redis-server nginx supervisor \
            rsync sshfs iputils-ping
        MYSQL_CONF=/etc/mysql/conf.d/spug.cnf
        SUPERVISOR_CONF=/etc/supervisor/conf.d/spug.conf
        REDIS_SRV=redis-server
        SUPERVISOR_SRV=supervisor
        rm -f /etc/nginx/sites-enabled/default
        ;;
    *rhel*|*centos*|*fedora*)
        yum install -y epel-release || true
        # RHEL 8/9 的开发仓库 id 大小写不一致：EL9 叫 crb，EL8 叫 PowerTools
        (dnf config-manager --set-enabled crb \
            || dnf config-manager --set-enabled PowerTools \
            || dnf config-manager --set-enabled powertools) >/dev/null 2>&1 || true
        yum install -y git mariadb-server gcc pkgconfig openldap-devel \
            cyrus-sasl-devel openssl-devel redis nginx supervisor rsync mariadb-connector-c-devel
        command -v curl >/dev/null 2>&1 || yum install -y curl
        # 必装项之外单独装：CentOS 8 的 EPEL 没有 fuse-sshfs，混在一批里会让整条 yum 失败
        yum install -y iputils || true
        yum install -y fuse-sshfs || log "未装 fuse-sshfs（该系统仓库里没有），sshfs 挂载主机的功能不可用"
        # 系统 python3 达不到 3.8 时，用 AppStream 里的 python39 / python38
        if ! find_python; then
            log "系统没有 Python ≥3.8，安装 python39"
            yum install -y python39 python39-devel python39-pip python39-setuptools \
                || yum install -y python38 python38-devel python38-pip python38-setuptools
        fi
        MYSQL_CONF=/etc/my.cnf.d/spug.cnf
        SUPERVISOR_CONF=/etc/supervisord.d/spug.ini
        REDIS_SRV=redis
        SUPERVISOR_SRV=supervisord
        sed -i 's/ default_server//g' /etc/nginx/nginx.conf
        ;;
    *)
        die "暂不支持的系统：$ID"
        ;;
esac

# ---------- 2. Python 3.8+（Django 4.2 的最低要求）----------
find_python || die "未找到 Python 3.8 及以上版本"
log "使用 Python：$PYTHON（$($PYTHON --version 2>&1)）"

# ---------- 3. Redis：channel layer 的硬依赖 ----------
systemctl enable --now "$REDIS_SRV"
# channels_redis 4.x 靠 BZPOPMIN 收消息，Redis 5.0 才有；版本不够时每个 WebSocket
# 都会在握手之后立刻异常断开。在这里挡住，比部署完去浏览器里发现要好。
REDIS_VER=$(redis-cli info server | awk -F: '/^redis_version/{print $2}' | tr -d '\r')
[ "${REDIS_VER%%.*}" -ge 5 ] 2>/dev/null \
    || die "Redis 版本 $REDIS_VER 不支持 BZPOPMIN，需要 ≥5.0（Debian 12 / Ubuntu 22.04 / Rocky 9 自带即可）"
log "Redis 版本 $REDIS_VER"

# ---------- 4. 数据库（MariaDB，仅监听 127.0.0.1）----------
cat > "$MYSQL_CONF" <<'EOF'
[mysqld]
bind-address=127.0.0.1
EOF
systemctl enable --now mariadb

# 版本不够就原地升级到官方仓库的 10.11，否则后面的 updatedb 会撞上
# NotSupportedError: MariaDB 10.4 or later is required (found 10.3.28)。
# CentOS 8 的 dnf 4.2 没有 module switch-to，只能靠 module disable + dnf swap；
# swap 只换包不动 /var/lib/mysql，升级完补一次 mariadb-upgrade 整理系统表。
DB_VER=$(db_version)
if ! db_ver_ok "$DB_VER"; then
    case " $ID ${ID_LIKE:-} " in
        *rhel*|*centos*|*fedora*)
            log "MariaDB $DB_VER 低于 10.4，切换到官方仓库 10.11"
            cat > /etc/yum.repos.d/MariaDB.repo <<EOF
[mariadb-official]
name=MariaDB Official
baseurl=https://rpm.mariadb.org/10.11/rhel/${VERSION_ID%%.*}/\$basearch
gpgkey=https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
module_hotfixes=1
EOF
            dnf module disable -y mariadb >/dev/null 2>&1 || true
            dnf swap -y mariadb-server MariaDB-server
            systemctl enable --now mariadb
            (mariadb-upgrade 2>/dev/null || mysql_upgrade 2>/dev/null) || true
            ;;
        *)
            die "MariaDB $DB_VER 低于 10.4，请手动升级到 ≥10.4 或改用 MySQL 8"
            ;;
    esac
    DB_VER=$(db_version)
    db_ver_ok "$DB_VER" || die "升级后仍是 $DB_VER"
    log "MariaDB 已升级到 $DB_VER"
fi

# 重复执行时沿用 overrides.py 里已有的口令：口令改了而 overrides.py 没同步，接口就会 502
if [ -z "$DB_PASSWORD" ] && [ -f "$API/spug/overrides.py" ]; then
    DB_PASSWORD=$(sed -n "s/^[[:space:]]*'PASSWORD': '\([^']*\)',[[:space:]]*$/\1/p" "$API/spug/overrides.py" | head -1)
fi
[ -n "$DB_PASSWORD" ] || DB_PASSWORD=$(rand 'A-Za-z0-9' 18)
mysql -e "CREATE DATABASE IF NOT EXISTS spug DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'spug'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';"
# CREATE USER IF NOT EXISTS 不会改已存在用户的密码，重复执行时以本次生成的为准
mysql -e "ALTER USER 'spug'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL ON spug.* TO 'spug'@'127.0.0.1'; FLUSH PRIVILEGES;"

# ---------- 5. Python 依赖 ----------
cd "$API"
[ -d venv ] || "$PYTHON" -m venv venv
./venv/bin/pip install -U pip wheel -i "$PIP_INDEX"
# mysqlclient 单独装：它编译期需要 libmariadb-dev / mariadb-connector-c-devel
./venv/bin/pip install -r requirements.txt mysqlclient -i "$PIP_INDEX"

# ---------- 6. 生产配置 overrides.py ----------
# settings.py 末尾用 try/except 导入它，所以只在这里覆盖，不改源码
if [ ! -f spug/overrides.py ]; then
    SECRET_KEY=$(rand '!@#%^.a-zA-Z0-9' 50)
    cat > spug/overrides.py <<EOF
# 由 deploy/install-spug.sh 生成，升级时保留；自定义配置写在这里。
DEBUG = False
ALLOWED_HOSTS = ['${ALLOWED_HOSTS}', '127.0.0.1', 'localhost']
SECRET_KEY = '${SECRET_KEY}'

DATABASES = {
    'default': {
        'ATOMIC_REQUESTS': True,
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'spug',
        'USER': 'spug',
        'PASSWORD': '${DB_PASSWORD}',
        'HOST': '127.0.0.1',
        'OPTIONS': {
            'charset': 'utf8mb4',
            'sql_mode': 'STRICT_TRANS_TABLES',
        }
    }
}
EOF
    log "已生成 $API/spug/overrides.py"
else
    log "已存在 spug/overrides.py，保留不覆盖（数据库口令如需同步请自行改这个文件）"
fi

# ---------- 7. 目录与脚本 ----------
mkdir -p "$API/logs" "$API/storage/transfer" "$API/storage/deploy"
# settings.REPOS_DIR 由 BASE_DIR 往上两级推导，SPUG_DIR=/data/spug 时即 /data/repos
mkdir -p "$(cd "$API/../.." && pwd)/repos"
# 源码在 Windows 上编辑过时 .sh 会带 CRLF，Linux 下执行会报 bad interpreter
find "$API/tools" -name '*.sh' -exec sed -i 's/\r$//' {} +
chmod +x "$API"/tools/*.sh

# ---------- 8. 建表与管理员 ----------
./venv/bin/python manage.py updatedb
if ./venv/bin/python manage.py shell -c 'import sys; from apps.account.models import User; sys.exit(0 if User.objects.exists() else 1)' 2>/dev/null; then
    log "已存在账户，跳过创建"
    ADMIN_CREATED=0
else
    ADMIN_GENERATED=0
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(rand 'A-Za-z0-9' 14)
        ADMIN_GENERATED=1
    fi
    ./venv/bin/python manage.py user add -u "$ADMIN_USER" -p "$ADMIN_PASSWORD" -n 管理员 -s >/dev/null
    ADMIN_CREATED=1
fi

# ---------- 9. supervisor：五个常驻进程 ----------
# 直接复用仓库自带的 tools/supervisor-spug.ini（api / ws / worker / monitor / scheduler），
# 只把里面写死的 /data/spug 换成实际安装路径
sed "s#/data/spug#$SPUG_DIR#g" "$API/tools/supervisor-spug.ini" > "$SUPERVISOR_CONF"
systemctl enable "$SUPERVISOR_SRV"

# ---------- 10. nginx：静态资源 + 反代 ----------
sed "s#__SPUG_DIR__#$SPUG_DIR#g" "$SCRIPT_DIR/nginx-spug.conf.template" > /etc/nginx/conf.d/spug.conf
nginx -t
systemctl enable nginx
systemctl restart nginx
systemctl restart "$SUPERVISOR_SRV"

log "部署完成"
echo
echo "  访问地址：http://$(hostname -I | awk '{print $1}')/"
if [ "${ADMIN_CREATED:-0}" = "1" ]; then
    echo "  管理员：$ADMIN_USER / $ADMIN_PASSWORD"
    [ "${ADMIN_GENERATED:-0}" = "1" ] && echo "  （密码为本次随机生成，登录后请立即修改）"
fi
echo "  数据库口令：$DB_PASSWORD   （写在 spug/overrides.py，本脚本不会覆盖该文件）"
echo
echo "  配置文件：$API/spug/overrides.py"
echo "  进程日志：$API/logs/{api,ws,worker,monitor,scheduler}.log"
echo "  查看进程：supervisorctl status"
