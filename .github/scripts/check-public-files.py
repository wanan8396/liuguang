"""Read the Git index and reject local state or credential material before publishing."""
import json
import re
import subprocess
import sys
from pathlib import PurePosixPath

names = subprocess.check_output(['git', 'ls-files', '--cached', '-z']).decode('utf-8').split('\0')
forbidden_dirs = {'.upstream', '.baseline', 'build', '.dart_tool', '.gradle', '.kotlin', 'artifacts', 'secrets', 'credentials'}
forbidden_files = {'local.properties', 'key.properties', 'RECOVERY-CT.md', '.env'}
forbidden_suffixes = {'.jks', '.keystore', '.p12', '.pfx', '.pem', '.key', '.log', '.apk', '.aab'}
patterns = {
    'github-token': re.compile(r'(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----(?:\s|\\n){1,16}[A-Za-z0-9+/=]{32,}'),
    'aws-key': re.compile(r'AKIA[0-9A-Z]{16}'),
    'machine-path': re.compile(r'[CD]:[\\/](?:Users|Tools)[\\/]'),
}
issues = []
files = [name for name in names if name]
for name in files:
    path = PurePosixPath(name)
    if (any(part in forbidden_dirs for part in path.parts) or path.name in forbidden_files
            or path.suffix.lower() in forbidden_suffixes or path.name.startswith('.env.')):
        issues.append({'path': name, 'type': 'excluded-file'})
        continue
    if path.suffix.lower() in {'.jar', '.so', '.png', '.jpg'}:
        continue
    content = subprocess.check_output(['git', 'show', ':' + name])
    try:
        text = content.decode('utf-8')
    except UnicodeDecodeError:
        continue
    for label, pattern in patterns.items():
        for match in pattern.finditer(text):
            issues.append({'path': name, 'line': text.count('\n', 0, match.start()) + 1, 'type': label})
print(json.dumps({'checkedFiles': len(files), 'issues': issues}, ensure_ascii=False, indent=2))
sys.exit(1 if issues else 0)
