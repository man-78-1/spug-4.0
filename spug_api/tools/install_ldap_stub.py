"""Install the local python-ldap development stub into the active site-packages.

Run after creating the venv:  python tools/install_ldap_stub.py
"""
import shutil
import sysconfig
from pathlib import Path

STUB = Path(__file__).resolve().parent / 'ldap_stub' / 'ldap'
TARGET = Path(sysconfig.get_paths()['purelib']) / 'ldap'

if TARGET.exists():
    print(f'Skipped, real or stubbed ldap already present at {TARGET}')
else:
    shutil.copytree(STUB, TARGET)
    print(f'Installed ldap stub -> {TARGET}')
