# Copyright: (c) OpenSpug Organization. https://github.com/openspug/spug
# Copyright: (c) <spug.dev@gmail.com>
# Released under the AGPL-3.0 License.
from libs.ssh import AuthenticationException
from django.db import close_old_connections, transaction
from apps.host.models import Host
from apps.schedule.models import History, Task
from apps.schedule.utils import send_fail_notify
from libs.utils import wrap_python_command
import subprocess
import socket
import signal
import os
import time
import json


DEFAULT_TIMEOUT = 3600


def local_executor(command, timeout):
    code, out, now = 1, None, time.time()
    if os.name == 'nt':
        extra = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP}
    else:
        extra = {'start_new_session': True}
    task = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **extra)
    try:
        stdout, stderr = task.communicate(timeout=timeout)
        code = task.returncode
        out = (stdout + stderr).decode()
    except subprocess.TimeoutExpired:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(task.pid)], capture_output=True)
        else:
            try:
                os.killpg(task.pid, signal.SIGKILL)
            except OSError:
                pass
        task.communicate()
        code = 1
        out = f'timeout after {timeout} seconds'
    return code, round(time.time() - now, 3), out


def host_executor(host, command, timeout):
    code, out, now = 1, None, time.time()
    try:
        with host.get_ssh() as ssh:
            code, out = ssh.exec_command_raw(command, timeout=timeout)
    except AuthenticationException:
        out = 'ssh authentication fail'
    except socket.error as e:
        out = f'network error {e}'
    return code, round(time.time() - now, 3), out


def dispatch_job(host_id, interpreter, command, timeout=0):
    timeout = timeout if timeout > 0 else DEFAULT_TIMEOUT
    if interpreter == 'python':
        command = wrap_python_command(command)
    if host_id == 'local':
        code, duration, out = local_executor(command, timeout)
    else:
        host = Host.objects.filter(pk=host_id).first()
        if not host:
            code, duration, out = 1, 0, f'unknown host id for {host_id!r}'
        else:
            code, duration, out = host_executor(host, command, timeout)
    return code, duration, out


def schedule_worker_handler(job):
    history_id, host_id, interpreter, command, timeout = json.loads(job)
    code, duration, out = dispatch_job(host_id, interpreter, command, timeout)

    close_old_connections()
    with transaction.atomic():
        history = History.objects.select_for_update().get(pk=history_id)
        output = json.loads(history.output)
        output[str(host_id)] = [code, duration, out]
        history.output = json.dumps(output)
        if all(output.values()):
            history.status = '1' if sum(x[0] for x in output.values()) == 0 else '2'
        history.save()
    if history.status == '2':
        task = Task.objects.get(pk=history.task_id)
        send_fail_notify(task)
