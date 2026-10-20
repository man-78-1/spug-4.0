"""Local development stub for python-ldap.

python-ldap has no Windows wheels and requires MSVC Build Tools plus OpenLDAP to
compile. Spug only touches this module when LDAP login is actually configured,
so this stub satisfies the top-level imports in libs/ldap.py and reports a clear
error instead of a build failure.

Install into site-packages via tools/install_ldap_stub.py.
"""

LDAPError = type('LDAPError', (Exception,), {'args': ({'desc': 'LDAP is not available in this build (python-ldap stub)'},)})

OPT_TIMEOUT = 17
OPT_NETWORK_TIMEOUT = 20469
SCOPE_BASE = 0
SCOPE_ONELEVEL = 1
SCOPE_SUBTREE = 2
SCOPE_CHILDREN = 4


class _StubConnection:
    def set_option(self, *args, **kwargs):
        pass

    def simple_bind_s(self, *args, **kwargs):
        raise LDAPError()

    def initialize(self, *args, **kwargs):
        raise LDAPError()

    def search(self, *args, **kwargs):
        raise LDAPError()

    def search_s(self, *args, **kwargs):
        raise LDAPError()

    def result(self, *args, **kwargs):
        raise LDAPError()

    def unbind_s(self, *args, **kwargs):
        pass


def initialize(uri, bytes_mode=True, **kwargs):
    return _StubConnection()


def escape_filter_chars(assertion_value, quote_mode='always'):
    return assertion_value
