# Copyright: (c) OpenSpug Organization. https://github.com/openspug/spug
# Copyright: (c) <spug.dev@gmail.com>
# Released under the AGPL-3.0 License.
from django_redis import get_redis_connection
from django.conf import settings
from django.db import close_old_connections
from libs.utils import AttrDict
from apps.config.utils import compose_configs
from apps.deploy.models import DeployRequest
from apps.deploy.helper import Helper, SpugError
from apps.deploy.ext1 import ext1_deploy
from apps.deploy.ext2 import ext2_deploy
from threading import Event, Thread
import json
import uuid

REPOS_DIR = settings.REPOS_DIR
ALIVE_TTL = 60
ALIVE_INTERVAL = 20


def alive_key(request_id):
    return f'{settings.REQUEST_KEY}:alive:{request_id}'


def check_hosts(host_ids, allowed_host_ids):
    """校验提交的主机全部落在允许范围内。

    前端的主机选择器只是把可选项限制在范围内，直接调用接口仍可提交任意主机；
    发布会在选中的主机上执行命令，所以服务端必须再校验一次。
    """
    if not isinstance(host_ids, list):
        return False
    try:
        allowed = {int(x) for x in allowed_host_ids}
    except (TypeError, ValueError):
        return False
    for host_id in host_ids:
        if isinstance(host_id, bool) or not isinstance(host_id, int):
            return False
        if host_id not in allowed:
            return False
    return True


def _keep_alive(rds, key, stop):
    while not stop.wait(ALIVE_INTERVAL):
        rds.setex(key, ALIVE_TTL, 1)


def sync_interrupted(requests):
    """把执行线程已经消失的发布中申请收敛为发布异常。

    deploy 的执行线程在 API 进程内，进程重启会让线程无声消失而状态停在发布中。
    执行期间每 ALIVE_INTERVAL 秒刷新一次带 ALIVE_TTL 过期的存活键，读到的发布中
    申请没有存活键即说明执行线程已经不在了（含升级前遗留的无键记录）。
    """
    running = [x for x in requests if x.status == '2']
    if not running:
        return
    rds = get_redis_connection()
    for item in running:
        if rds.exists(alive_key(item.id)):
            continue
        if DeployRequest.objects.filter(pk=item.id, status='2').update(status='-3'):
            item.status = '-3'


def dispatch_all(req):
    """Dispatch a deploy request for all its hosts, used by planned/webhook triggered deploys."""
    host_ids = json.loads(req.host_ids)
    with_local = False
    if req.deploy.extend == '1':
        if not req.repository_id:
            with_local = True
    else:
        if json.loads(req.deploy.extend_obj.server_actions):
            with_local = True
    dispatch(req, host_ids, with_local)


def dispatch(req, deploy_host_ids, with_local, language='zh'):
    rds = get_redis_connection()
    rds_key = req.deploy_key
    alive = alive_key(req.id)
    stop_keep_alive = Event()
    rds.setex(alive, ALIVE_TTL, 1)
    Thread(target=_keep_alive, args=(rds, alive, stop_keep_alive), daemon=True).start()
    helper = None

    try:
        keys = deploy_host_ids + ['local'] if with_local else deploy_host_ids
        helper = Helper.make(rds, rds_key, keys, language)
        api_token = uuid.uuid4().hex
        rds.setex(api_token, 60 * 60, f'{req.deploy.app_id},{req.deploy.env_id}')
        env = AttrDict(
            SPUG_APP_NAME=req.deploy.app.name,
            SPUG_APP_KEY=req.deploy.app.key,
            SPUG_APP_ID=str(req.deploy.app_id),
            SPUG_REQUEST_ID=str(req.id),
            SPUG_REQUEST_NAME=req.name,
            SPUG_DEPLOY_ID=str(req.deploy.id),
            SPUG_ENV_ID=str(req.deploy.env_id),
            SPUG_ENV_KEY=req.deploy.env.key,
            SPUG_VERSION=req.version,
            SPUG_BUILD_VERSION=req.spug_version,
            SPUG_DEPLOY_TYPE=req.type,
            SPUG_API_TOKEN=api_token,
            SPUG_REPOS_DIR=REPOS_DIR,
        )
        # append configs
        configs = compose_configs(req.deploy.app, req.deploy.env_id)
        configs_env = {f'_SPUG_{k.upper()}': v for k, v in configs.items()}
        env.update(configs_env)

        if req.deploy.extend == '1':
            ext1_deploy(req, helper, env)
        else:
            ext2_deploy(req, helper, env, with_local)
        req.status = '3'
    except Exception as e:
        req.status = '-3'
        if not isinstance(e, SpugError):
            raise e
    finally:
        stop_keep_alive.set()
        close_old_connections()
        request = DeployRequest.objects.get(pk=req.id)
        if helper is None:
            request.status = '-3'
            request.save()
        else:
            deploy_status = json.loads(request.deploy_status)
            deploy_status.update({str(k): v for k, v in helper.deploy_status.items()})
            values = [v for k, v in deploy_status.items() if k != 'local']
            if not values:  # no host-side actions, decide by the local task
                request.status = '3' if deploy_status.get('local') == '2' else '-3'
            elif all([x == '2' for x in values]):
                if len(values) == len(json.loads(request.host_ids)):
                    request.status = '3'
                else:
                    request.status = '4'
            else:
                request.status = '-3'
            request.repository = req.repository
            request.deploy_status = json.dumps(deploy_status)
            request.save()
            helper.clear()
        req.status = request.status
        rds.delete(alive)
        Helper.send_deploy_notify(req)
