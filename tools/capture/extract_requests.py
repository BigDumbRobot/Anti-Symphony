#!/usr/bin/env python3
"""Pull SendRequest(write, req, addr, len, data, delay) arguments out of each
SymphonyIOControl function in the disassembled Apogee daemon (unoptimised arm64).

For every call it reports the last value moved into w1..w4 before the call:
a number when it was an immediate, otherwise '?' (computed from function args).
Usage: extract_requests.py daemon-arm64.s
"""
import re
import sys

FUNC = re.compile(r'^(\S.*\)):\s*$')
INS = re.compile(r'^[0-9a-f]+\s+(\w+)\s+(.*)$')
IMM = re.compile(r'^#(-?0x[0-9a-f]+|-?\d+)$')

def main(path):
    func = None
    regs = {}
    out = []
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        m = FUNC.match(line)
        if m:
            func = m.group(1)
            regs = {}
            continue
        if not func or not func.startswith('SymphonyIOControl::'):
            continue
        m = INS.match(line)
        if not m:
            continue
        op, args = m.group(1), m.group(2)
        parts = [a.strip() for a in args.split(',')]
        dst = parts[0] if parts else ''
        key = dst[1:] if dst[:1] in 'wx' and dst[1:].isdigit() else None
        if key is not None:
            src = parts[1] if len(parts) > 1 else ''
            if op == 'mov' and IMM.match(src):
                regs[key] = int(IMM.match(src).group(1), 0)
            elif op == 'mov' and src[:1] in 'wx' and src[1:].isdigit():
                regs[key] = regs.get(src[1:], '?')
            elif op == 'and' and len(parts) > 2 and parts[2] == '#0x1' and regs.get(parts[1][1:]) is not None:
                v = regs.get(parts[1][1:])
                regs[key] = v & 1 if isinstance(v, int) else '?'
            elif op == 'movk':
                regs[key] = '?'
            elif op not in ('str', 'stur', 'strb', 'sturb', 'strh', 'sturh', 'stp', 'cmp', 'cbz', 'cbnz', 'tbnz', 'tbz'):
                regs[key] = '?'
        if op == 'bl' and 'SendRequest' in args:
            fmt = lambda v: hex(v) if isinstance(v, int) else '?'
            w = regs.get('1')
            out.append((func, 'write' if w == 1 else 'read' if w == 0 else '?',
                        fmt(regs.get('2')), fmt(regs.get('3')), fmt(regs.get('4'))))
    for f, rw, req, addr, ln in out:
        print(f'{req:>5} {rw:5} addr={addr:>8} len={ln:>6}  {f}')

if __name__ == '__main__':
    main(sys.argv[1])
