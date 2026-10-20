"""Submodule stub matching python-ldap's ldap.filter import path."""


def escape_filter_chars(assertion_value, quote_mode='always'):
    replacement = [('\\', '\\5c'), ('*', '\\2a'), ('(', '\\28'), (')', '\\29'), ('\x00', '\\00')]
    text = assertion_value if isinstance(assertion_value, str) else assertion_value.decode()
    for char, escaped in replacement:
        text = text.replace(char, escaped)
    return text
