'''Audit strace -f -yy path mutations, including child VMs/Python and dependency builds.
Not a sandbox. Reads, failed operations and special-device writes are reported separately.
Never trace execve/argv or data buffers. Fail on unparsed mutation/unfinished success.
Usage: python3 audit_writes.py TRACE CWD REPORT ALLOWED_ROOT ...
'''
import ast
import json
import os
import re
import sys
MUTATIONS = {
    'creat': [0], 'mkdir': [0], 'mkdirat': [1], 'rmdir': [0],
    'rename': [0, 1], 'renameat': [1, 3], 'renameat2': [1, 3],
    'unlink': [0], 'unlinkat': [1], 'chmod': [0], 'fchmod': [0], 'fchmodat': [1],
    'truncate': [0], 'ftruncate': [0], 'symlink': [1], 'symlinkat': [2],
    'link': [1], 'linkat': [3], 'mknod': [0], 'mknodat': [1],
    'utime': [0], 'utimes': [0], 'utimensat': [1], 'futimesat': [1],
    'chown': [0], 'lchown': [0], 'fchown': [0], 'fchownat': [1],
    'setxattr': [0], 'lsetxattr': [0], 'fsetxattr': [0],
    'removexattr': [0], 'lremovexattr': [0], 'fremovexattr': [0],
}
CALLS = ','.join(['open', 'openat', 'chdir', 'fchdir', 'clone', 'clone3', 'fork', 'vfork'] + list(MUTATIONS))
SPECIAL = {'/dev/null', '/dev/tty', '/dev/zero', '/dev/full'}

def split_args(text):
    parts, start, quote, escape, angle, depth = [], 0, False, False, 0, 0
    for i, c in enumerate(text):
        if quote:
            if escape: escape = False
            elif c == '\\': escape = True
            elif c == '"': quote = False
        elif c == '"': quote = True
        elif c == '<': angle += 1
        elif c == '>': angle -= 1
        elif not angle:
            if c in '([{': depth += 1
            elif c in ')]}': depth -= 1
            elif c == ',' and depth == 0:
                parts.append(text[start:i].strip()); start = i + 1
    parts.append(text[start:].strip())
    return parts

def annotation(arg):
    m = re.search(r'<(/.*?)>', arg)
    return m.group(1).split('<')[0].removesuffix(' (deleted)') if m else None

def operand(args, idx, cwd):
    arg = args[idx]
    if arg.startswith('"'):
        path = ast.literal_eval(arg)
        if not os.path.isabs(path):
            base = annotation(args[idx - 1]) if idx else None
            path = os.path.join(base or cwd, path)
        return os.path.normpath(path)
    path = annotation(arg)
    if path: return os.path.normpath(path)
    raise ValueError('unresolved mutation operand: ' + arg)

def within(path, roots):
    return any(path == root or path.startswith(root + '/') for root in roots)

def audit(lines, cwd, roots):
    pending, directories, writes, failed, errors, devices = {}, {}, set(), 0, [], set()
    mutations = 0
    for number, line in enumerate(lines, 1):
        match = re.match(r'\s*(\d+)\s+(.*)', line)
        if not match: continue
        pid, text = match.groups()
        if '<unfinished ...>' in text:
            pending[pid] = text.split('<unfinished ...>')[0]; continue
        if text.startswith('<... '):
            resumed = re.match(r'<\.\.\. (\w+) resumed>(.*)', text)
            if not resumed or pid not in pending:
                errors.append({'line': number, 'reason': 'unmatched resumed syscall'}); continue
            text = pending.pop(pid) + resumed.group(2)
        m = re.match(r'(\w+)\((.*)\)\s+=\s+(-?\d+)(.*)', text)
        if not m: continue
        call, argstr, result, suffix = m.groups()
        result = int(result)
        args = split_args(argstr)
        current = directories.get(pid, cwd)
        if call in ['clone', 'clone3', 'fork', 'vfork'] and result > 0:
            directories[str(result)] = current
        elif call in ['chdir', 'fchdir'] and result == 0:
            directories[pid] = operand(args, 0, current)
        indices = MUTATIONS.get(call)
        if call in ['open', 'openat']:
            if not re.search(r'\bO_(WRONLY|RDWR|CREAT|TRUNC|APPEND)\b', argstr): continue
            indices = [0 if call == 'open' else 1]
        if indices is None: continue
        if result < 0:
            failed += 1; continue
        try:
            paths = [operand(args, i, current) for i in indices]
            if call in ['open', 'openat', 'creat'] and annotation(suffix):
                resolved = annotation(suffix)
                if re.match(r'^/(proc/(self|[0-9]+)/fd|dev/fd)/[0-9]+$', paths[0]):
                    paths = [resolved]
                else:
                    paths.append(resolved)
            for path in paths:
                if path in SPECIAL or path.startswith('/memfd:'): devices.add(path)
                else: writes.add(path)
            mutations += 1
        except (ValueError, SyntaxError, IndexError) as exc:
            errors.append({'line': number, 'reason': str(exc)})
    for pid, text in pending.items():
        call = text.split('(')[0]
        if call in MUTATIONS or (call in ['open', 'openat'] and re.search(r'O_(WRONLY|RDWR|CREAT|TRUNC|APPEND)', text)):
            errors.append({'pid': pid, 'reason': 'unfinished mutation'})
    outside = sorted(p for p in writes if not within(p, roots))
    return dict(mutation_count=mutations, paths=sorted(writes), outside=outside,
                failed_operations=failed, parse_errors=errors, special_devices=sorted(devices),
                allowed_roots=roots, passed=not outside and not errors)

if __name__ == '__main__':
    if sys.argv[1:] == ['--calls']: print(CALLS); sys.exit(0)
    trace, cwd, report, *roots = sys.argv[1:]
    roots = [os.path.abspath(p) for p in roots]
    with open(trace) as stream: result = audit(stream, os.path.abspath(cwd), roots)
    with open(report, 'w') as stream: json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k != 'paths'}))
    sys.exit(0 if result['passed'] else 1)
