#!/usr/bin/env python3
"""Ensure Proxmox host firewall rules exist via pvesh. Idempotent."""
import json
import subprocess

NODE = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()

DESIRED = [
    {'proto': 'tcp', 'source': '192.168.1.0/24', 'dport': '2222'},
    {'proto': 'tcp', 'source': '10.10.10.0/24',  'dport': '2222'},
    {'proto': 'tcp', 'source': '192.168.1.0/24', 'dport': '8006'},
    {'proto': 'tcp', 'source': '10.10.10.0/24',  'dport': '8006'},
    {'proto': 'tcp', 'source': '10.10.1.3',      'dport': '8006'},
    {'proto': 'tcp', 'source': '192.168.1.0/24', 'dport': '3128'},
    {'proto': 'udp', 'source': '10.10.0.0/16',   'dport': '53'},
    {'proto': 'tcp', 'source': '10.10.0.0/16',   'dport': '53'},
    {'proto': 'udp',                              'dport': '51820'},
    {'proto': 'icmp'},
]


def pvesh(*args):
    return subprocess.run(['pvesh', *args], capture_output=True, text=True)


def get_rules():
    r = pvesh('get', f'/nodes/{NODE}/firewall/rules', '--output-format', 'json')
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return []


def matches(current, desired):
    return all(str(current.get(k, '')) == str(v) for k, v in desired.items())


endpoint = f'/nodes/{NODE}/firewall/rules'
current = get_rules()
changed = False

for rule in DESIRED:
    if not any(matches(c, rule) for c in current):
        args = ['create', endpoint, '--action', 'ACCEPT', '--type', 'in', '--enable', '1']
        for k, v in rule.items():
            args += [f'--{k}', str(v)]
        pvesh(*args)
        changed = True

print('changed' if changed else 'ok')
