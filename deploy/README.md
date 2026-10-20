# Spug 4.x 源码部署（Linux 服务器）

本目录是把**你自己改过的源码**部署到一台干净的 Linux 服务器上的脚本和配置。
和 `docs/install.sh` 的区别：那份从 gitee 拉上游代码、再从 cdn.spug.cc 下载官方前端产物；
这里传的是本地源码，前端在 Windows 上 build 完一起上传，**服务器不需要装 Node**。

## 前置条件

- 一台 Linux 服务器：Debian 12 / Ubuntu 22.04 / CentOS 8 / Rocky / AlmaLinux，root 可登录
- Python 3.8 及以上（脚本会自动找；CentOS 8 只有 3.6 时会自动 `yum install python39`）
- MariaDB ≥10.4 或 MySQL ≥8（Django 4.2 硬性要求；CentOS 8 自带的 10.3 会被脚本换成官方仓库的 10.11）
- Redis ≥5.0（`BZPOPMIN`，见下方常见问题）
- 服务器能访问 pypi 镜像（默认清华源）
- 本机（Windows）能 ssh/scp 到服务器

## 部署步骤

```powershell
# 0. 本机：把公钥装到服务器（只需一次，之后 ssh/scp 不再问密码）
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@<服务器IP> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

# 1. 本机：构建前端 + 打包源码 + 上传到服务器 /data/spug，并执行安装脚本
powershell -ExecutionPolicy Bypass -File deploy\upload-source.ps1 -Server <服务器IP> -Install
```

没有 `~\.ssh\id_ed25519` 时先 `ssh-keygen -t ed25519 -N '""' -f $env:USERPROFILE\.ssh\id_ed25519`。
阿里云 ECS 也可以在控制台绑定密钥对，效果一样。

脚本会依次完成：装系统依赖 → 校验 Redis ≥5 → 建 MariaDB 库和用户 → 建 venv 装 Python 依赖
→ 生成 `spug/overrides.py`（`DEBUG=False`、随机 `SECRET_KEY`、MySQL 连接）→ `manage.py updatedb`
建表 → 创建 admin 账号 → 渲染 supervisor 与 nginx 配置 → 启动服务。

结束时屏幕会打印访问地址、管理员密码和数据库口令，**当场记下来**，脚本不会重复输出。

已经上传过源码、只想重跑安装：

```bash
bash /data/spug/deploy/install-spug.sh
```

只想改代码不重装依赖：

```powershell
powershell -ExecutionPolicy Bypass -File deploy\upload-source.ps1 -Server <IP> -SkipBuild
ssh root@<IP> "supervisorctl restart all"
```

## 进程模型

supervisor 拉起五个进程（配置来自仓库自带的 `spug_api/tools/supervisor-spug.ini`），nginx 在最前面分流：

| 进程 | 命令 | 监听 | 作用 |
| --- | --- | --- | --- |
| spug-api | `gunicorn -b 127.0.0.1:9001 -w 2 --threads 8 spug.wsgi` | 9001 | 普通 HTTP 接口 |
| spug-ws | `daphne -p 9002 spug.asgi:application` | 9002 | WebSocket：在线终端、实时通知、日志流 |
| spug-worker | `python manage.py runworker` | — | 消费 exec/monitor/schedule 三个 redis 队列 |
| spug-monitor | `python manage.py runmonitor` | — | 监控项探测循环 |
| spug-scheduler | `python manage.py runscheduler` | — | 任务计划调度循环 |
| nginx | 静态 + 反代 | 80 | `/api/`→9001，`/api/ws/`→9002，其余回 `index.html` |

接口层不带 `/api` 前缀，所以 nginx 两处 location 都先 `rewrite ^/api(.*) $1 break;` 再转发。

## 部署后验证

```bash
supervisorctl status            # 五个进程都应是 RUNNING
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/api/account/login/   # 405/200 都算通
tail -20 /data/spug/spug_api/logs/api.log
```

浏览器打开 `http://<服务器IP>/`，登录后重点看三处：
工作台能加载、右上角通知图标不报错、主机管理里能打开一台主机的**在线终端**（这条链路
走 nginx→daphne→redis→paramiko，最容易出问题）。

## 日常启停（在本机 Git Bash 里）

`spug-ctl.sh` 把本地开发栈和服务器上的 Spug 进程收在一个入口，不带参数就是看两边状态：

```bash
bash deploy/spug-ctl.sh                      # = status：本地 :8000/:3000 + 服务器五进程
bash deploy/spug-ctl.sh up        # 两边都起
bash deploy/spug-ctl.sh down      # 两边都停
bash deploy/spug-ctl.sh local down           # 只停本地（内部调用 tools/dev-stop.sh）
bash deploy/spug-ctl.sh server down          # 只停服务器五个进程，nginx/MariaDB/Redis 不动
bash deploy/spug-ctl.sh server restart spug-api   # 上传新代码后重启单个进程
bash deploy/spug-ctl.sh server logs api      # 末尾 40 行 + Traceback 计数
bash deploy/spug-ctl.sh server check         # 从本机验公网：首页 200 / api 401 / ws 101
SPUG_SERVER=1.2.3.4 bash deploy/spug-ctl.sh server status   # 换机器
```

它只启停进程，**不会关闭 ECS 实例**（那要去阿里云控制台，且实例是 EIP，停机不会改变 `8.138.44.106`）。
`server check` 的三项就是"部署后验证"里那三条，随时可以单独跑。

## 常见问题

**`updatedb` 报 `MariaDB 10.4 or later is required (found 10.3.28)`**
CentOS 8 / RHEL 8 的 AppStream 只给 MariaDB 10.3，Django 4.2 会直接拒。脚本已自动处理：
`dnf module disable mariadb` + `dnf swap mariadb-server MariaDB-server`（官方仓库原地替换，datadir 不动）。
注意这台 dnf（4.2.17）没有 `module switch-to`，而且 `gpgkey` 必须用 `RPM-GPG-KEY-MariaDB`，
用 `mariadb_gpg.txt` 会被镜像重定向成 404、事务在验签阶段悄悄中止。

**WebSocket 连不上 / 在线终端打不开**
`redis-cli info server | grep redis_version` 必须是 5.0 以上。channels_redis 4.x 用 `BZPOPMIN`
收消息，Redis 5.0 才有；版本不够时每个 WS 连接握手后立刻异常断开（`logs/ws.log` 里能看到
`unknown command 'BZPOPMIN'`）。安装脚本已经提前挡住了这一条。

**页面能开但接口 502**
`supervisorctl status` 看 spug-api 是否 RUNNING，再 `tail logs/api.log`。
多数是 `spug/overrides.py` 里数据库口令和实际 MySQL 用户密码不一致。

**改了 overrides.py 不生效**
`supervisorctl restart all`。这个文件只在 settings 加载时被 `from spug.overrides import *` 读一次。

**上传后页面还是旧的**
前端是 build 产物，必须重新 `npm run build` 再上传（去掉 `-SkipBuild`），只重启后端不会变。

**本机 `npm run build` 报 `Unable to generate service worker from template. 'assignWith is not defined'`**
不是本项目的问题：`react-scripts@3.4.3 → workbox-build@4.3.1 → lodash.template@^4.4.0`，
而 npm 会解析到重发布过的 `lodash.template@4.18.0`，它内部引用了未定义的 `assignWith`。
临时修法是就地装回可用版本，不动 `package.json`：

```powershell
cd spug_web
npm install lodash.template@4.5.0 --no-save --no-package-lock
```

`--no-save` 意味着重装 `node_modules` 后会复发。要一次性修好，在 `spug_web/package.json` 里加：

```json
"overrides": { "lodash.template": "4.5.0" }
```

然后重新 `npm install`。

**本机开发环境**
Windows 上开发用 `powershell -ExecutionPolicy Bypass -File spug_api\tools\dev-start.ps1` 启动，
`bash spug_api/tools/dev-stop.sh` 停止；本地 `DEBUG=True` 时 channel layer 会退化成进程内实现
（因为本机 Redis 是 3.0.504），这条覆盖只在开发模式生效，不影响服务器。

## 安全提示

- 首次登录后立刻改掉随机生成的 admin 密码
- MariaDB 与 Redis 都只监听 127.0.0.1，不要把 3306/6379 暴露到公网
- 对外只提供 80/443；要 HTTPS 就再套一层证书，nginx 的 `/api/ws/` 段保持 `Upgrade` 头不变
