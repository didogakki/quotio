#!/usr/bin/env python3
"""Root-only, narrow Cloudflared cache ingress deployment; no credential output."""
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

HOSTS = {'cliproxyapi-plus.gakki.one': 'plus', 'cliproxyapi-business.gakki.one': 'business'}
RESOURCES = '(codex-usage|codex-reset-credits|claude-usage|claude-profile|grok-usage|grok-settings)'


def updated_config(text):
    for host, pool in HOSTS.items():
        path = '^/quota-cache/v1/' + pool + '/' + RESOURCES + '$'
        pattern = re.compile(r'^(\s*)- hostname:\s*[\"\']?' + re.escape(host) + r'[\"\']?\s*$', re.M)
        matches = list(pattern.finditer(text))
        if not matches:
            raise ValueError('required hostname absent: ' + host)
        indent = matches[0].group(1).split('\n')[-1]
        block = (indent + '- hostname: ' + host + '\n' + indent + '  path: "' + path + '"\n'
                 + indent + '  service: http://127.0.0.1:8328\n')
        if block in text:
            continue
        if len(matches) != 1:
            raise ValueError('ambiguous existing hostname rules: ' + host)
        pos = matches[0].start()
        # Preserve preceding blank lines captured by \s*.
        while pos < len(text) and text[pos] == '\n':
            pos += 1
        text = text[:pos] + block + text[pos:]
    return text


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run explicitly with sudo; this script never collects a password.')
    path = Path('/etc/cloudflared/config.yml')
    if path.is_symlink() or not path.is_file():
        raise SystemExit('Refusing non-regular config path')
    original = path.read_text()
    updated = updated_config(original)
    if updated == original:
        print('Cache routes already configured; no changes.')
        return
    run('/usr/bin/systemctl', 'is-active', '--quiet', 'cloudflared.service')
    fd, name = tempfile.mkstemp(prefix='cache-ingress-', suffix='.yml', dir=path.parent)
    tmp = Path(name)
    backup = path.with_name('config.yml.before-quota-cache-' + time.strftime('%Y%m%d-%H%M%S'))
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(updated); f.flush(); os.fsync(f.fileno())
        run('/usr/local/bin/cloudflared', 'tunnel', '--config', str(tmp), 'ingress', 'validate')
        if path.read_text() != original or backup.exists():
            raise RuntimeError('Config changed concurrently or backup collision')
        shutil.copy2(path, backup)
        os.chmod(tmp, path.stat().st_mode & 0o777)
        os.chown(tmp, path.stat().st_uid, path.stat().st_gid)
        os.replace(tmp, path)
        try:
            run('/usr/bin/systemctl', 'restart', 'cloudflared.service')
            time.sleep(3)
            run('/usr/bin/systemctl', 'is-active', '--quiet', 'cloudflared.service')
        except Exception:
            shutil.copy2(backup, path)
            run('/usr/bin/systemctl', 'restart', 'cloudflared.service')
            raise RuntimeError('Deployment failed; original config restored') from None
        print('Cache ingress installed; original routes preserved. Backup: ' + str(backup))
    finally:
        if tmp.exists(): tmp.unlink()

if __name__ == '__main__':
    main()
