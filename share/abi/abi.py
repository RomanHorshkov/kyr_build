#!/usr/bin/env python3
# abi.py — the parts of the ABI gate (check_abi.sh) that read the compiler's debug information.
#
#   abi.py program  <dwarf> <type-prefix> <out.c> <header ...>   write the layout program for every public type the headers declare
#   abi.py complete <dwarf> <type-prefix> <program-output>       a hand-written abi/layout.c lists exactly the public types and fields
#   abi.py sections <dwarf> <aux-info> <type-prefix> <func-prefix> <include-dir>
#                                                                 enums, callbacks and functions, one line each, on stdout
#   abi.py enumerators <dwarf> <type-prefix>                     every enumerator of an unnamed or untypedef'd public enum
#   abi.py classify <old> <new>                                   the raise the change needs (first line: identical | tooling |
#                                                                 minor | major), then the reason; comment lines are not ABI
#
# Public means: a typedef whose name starts with the type prefix (complete structs and unions with every member; scalar, enum
# and typedef'd types by size; pointer-to-function typedefs as callbacks), an unnamed or untypedef'd enum whose enumerators start
# with the prefix in upper case (constants), and a function the headers under the include directory declare with the function
# prefix. Line formats are DB_lmdb's (abi/layout.txt), so a file it wrote stays valid; enumerators of unnamed enums are the one
# category it did not have (`enumerator NAME VALUE`).
import re
import sys


def category(line):
    f = line.split()
    if not f:
        return 'blank'
    if f[0].startswith('#'):
        return 'comment'
    return {'field': 'struct', 'bits': 'struct', 'value': 'enum'}.get(f[0], f[0])


def classify(old_path, new_path):
    """SemVer on the ABI: an existing line changed or removed, or a member added to an existing struct, is a major; new names in
    categories the old file covers are a minor; lines only of categories it did not cover are a tooling change."""
    strip = lambda p: [l for l in open(p).read().splitlines() if category(l) not in ('comment', 'blank')]
    old, new = strip(old_path), strip(new_path)
    j, kept = 0, []
    for line in new:
        if j < len(old) and line == old[j]:
            kept.append(True)
            j += 1
        else:
            kept.append(False)
    if j != len(old):
        print('major')
        print(f'  existing line changed or removed: {old[j]!r}')
        return 0
    in_old_struct = False
    for line, k in zip(new, kept):
        if line.startswith('struct '):
            in_old_struct = k
        elif line.startswith(('  field ', '  bits ')) and not k and in_old_struct:
            print('major')
            print(f'  member added to an existing struct: {line.strip()!r}')
            return 0
    added = [l for l, k in zip(new, kept) if not k]
    if not added:
        print('identical')
        return 0
    covered = {category(l) for l in old}
    grown = sorted({category(l) for l in added} & covered)
    if grown:
        first = next(l for l in added if category(l) in covered).strip()
        print('minor')
        print('  new names in covered categories: ' + ', '.join(grown) + f' (first: {first})')
    else:
        print('tooling')
        print('  new categories: ' + ', '.join(sorted({category(l) for l in added})))
    return 0


DIE_RE = re.compile(r'^\s*<(\d+)><([0-9a-f]+)>: Abbrev Number: \d+ \((DW_TAG_\w+)\)')
ATTR_RE = re.compile(r'^\s*<[0-9a-f]+>\s+(DW_AT_\w+)\s*:\s*(.*)$')


def load_dwarf(path):
    dies, stack, cur = {}, {}, None
    for line in open(path):
        m = DIE_RE.match(line)
        if m:
            depth, off = int(m.group(1)), int(m.group(2), 16)
            cur = {'tag': m.group(3), 'parent': stack.get(depth - 1), 'kids': [], 'off': off}
            dies[off] = cur
            stack[depth] = off
            if cur['parent'] is not None:
                dies[cur['parent']]['kids'].append(off)
            continue
        m = ATTR_RE.match(line)
        if m and cur is not None:
            k, v = m.group(1), m.group(2).strip()
            if k == 'DW_AT_name':
                cur['name'] = v.rsplit(': ', 1)[-1] if v.startswith('(') else v
            elif k == 'DW_AT_type':
                cur['type'] = int(v.strip('<>').split()[0], 16)
            elif k == 'DW_AT_byte_size':
                cur['size'] = v
            elif k == 'DW_AT_const_value':
                cur['value'] = v.rsplit(': ', 1)[-1] if v.startswith('(') else v
            elif k == 'DW_AT_bit_size':
                cur['bits'] = v
            elif k == 'DW_AT_data_bit_offset':
                cur['bit_offset'] = v
            elif k == 'DW_AT_declaration':
                cur['declaration'] = True
    return dies


class Dwarf:
    def __init__(self, path, type_prefix):
        self.dies = load_dwarf(path)
        self.prefix = type_prefix
        self.structs, self.scalars, self.enums, self.callbacks, self.constants = {}, [], {}, {}, {}
        typedef_targets = set()
        for d in self.dies.values():
            if d['tag'] != 'DW_TAG_typedef' or not d.get('name', '').startswith(type_prefix):
                continue
            t = self.dies.get(d.get('type'))
            if t is None:
                continue
            typedef_targets.add(t['off'])
            if t['tag'] in ('DW_TAG_structure_type', 'DW_TAG_union_type') and 'size' in t and not t.get('declaration'):
                self.structs[d['name']] = t
            elif t['tag'] in ('DW_TAG_enumeration_type', 'DW_TAG_base_type', 'DW_TAG_typedef'):
                self.scalars.append(d['name'])
            if t['tag'] == 'DW_TAG_enumeration_type':
                self.enums[d['name']] = self.enumerators(t)
            elif t['tag'] == 'DW_TAG_pointer_type' and self.dies.get(t.get('type'), {}).get('tag') == 'DW_TAG_subroutine_type':
                s = self.dies[t['type']]
                self.callbacks[d['name']] = (self.tname(s.get('type')), self.params_of(s))
        upper = type_prefix.upper()
        for d in self.dies.values():
            if d['tag'] != 'DW_TAG_enumeration_type' or d['off'] in typedef_targets:
                continue
            values = self.enumerators(d)
            if not values or not all(n.startswith(upper) for n, _ in values):
                continue
            self.constants[d.get('name', values[0][0])] = values

    def enumerators(self, t):
        return [(self.dies[k]['name'], self.dies[k].get('value', '?')) for k in t['kids'] if self.dies[k]['tag'] == 'DW_TAG_enumerator']

    def params_of(self, t):
        return [self.tname(self.dies[k].get('type')) for k in t['kids'] if self.dies[k]['tag'] == 'DW_TAG_formal_parameter']

    def tname(self, off):
        t = self.dies.get(off)
        if t is None:
            return 'void'
        tag = t['tag']
        if tag == 'DW_TAG_pointer_type':
            return self.tname(t.get('type')) + ' *'
        if tag == 'DW_TAG_const_type':
            return 'const ' + self.tname(t.get('type'))
        if tag == 'DW_TAG_volatile_type':
            return 'volatile ' + self.tname(t.get('type'))
        if tag == 'DW_TAG_array_type':
            return self.tname(t.get('type')) + ' []'
        if tag == 'DW_TAG_subroutine_type':
            return self.tname(t.get('type')) + ' (' + ', '.join(self.params_of(t)) + ')'
        return t.get('name', '<anonymous>')

    def members(self, t, path=''):
        """(designator, kind, dwarf die) for every member, anonymous or anonymous-typed aggregates flattened."""
        out = []
        for k in t['kids']:
            m = self.dies[k]
            if m['tag'] != 'DW_TAG_member':
                continue
            mt = self.dies.get(m.get('type'))
            while mt is not None and mt['tag'] in ('DW_TAG_const_type', 'DW_TAG_volatile_type'):
                mt = self.dies.get(mt.get('type'))
            anon_type = mt is not None and mt['tag'] in ('DW_TAG_structure_type', 'DW_TAG_union_type') and 'name' not in mt
            name = m.get('name')
            if name is None and anon_type:
                out += self.members(mt, path)
                continue
            designator = path + (name or '?')
            out.append((designator, 'bits' if 'bits' in m else 'field', m))
            if anon_type and 'bits' not in m:
                out += self.members(mt, designator + '.')
        return out


def program(dwarf, type_prefix, out_c, headers):
    d = Dwarf(dwarf, type_prefix)
    lines = ['#include <stdalign.h>', '#include <stddef.h>', '#include <stdio.h>', '']
    lines += [f'#include <{h}>' for h in headers]
    lines += ['', 'int main(void)', '{', '    printf("data_model pointer %zu long %zu\\n", sizeof(void*), sizeof(long));']
    for n in sorted(d.scalars):
        lines.append(f'    printf("type {n} size %zu\\n", sizeof({n}));')
    for n in sorted(d.structs):
        lines.append(f'    printf("struct {n} size %zu align %zu\\n", sizeof({n}), alignof({n}));')
        for designator, kind, m in d.members(d.structs[n]):
            if kind == 'bits':
                lines.append(f'    printf("  bits {designator} offset {m.get("bit_offset", "?")} width {m["bits"]}\\n");')
            else:
                lines.append(f'    printf("  field {designator} offset %zu size %zu\\n", offsetof({n}, {designator}), '
                             f'sizeof((({n}*)0)->{designator}));')
    lines += ['    return 0;', '}', '']
    open(out_c, 'w').write('\n'.join(lines))
    return 0


def complete(dwarf, type_prefix, program_output):
    d = Dwarf(dwarf, type_prefix)
    want = {'struct ' + n: [x for x, kind, _ in d.members(t) if kind == 'field' and '.' not in x] for n, t in d.structs.items()}
    want.update({'type ' + n: [] for n in d.scalars})
    have, key = {}, None
    for line in open(program_output):
        f = line.split()
        if f and f[0] in ('struct', 'type'):
            key = f[0] + ' ' + f[1]
            have[key] = []
        elif f and f[0] == 'field' and key:
            have[key].append(f[1])
    bad = 0
    for k in sorted(set(want) | set(have)):
        if k not in have:
            print(f'  {k} is public but not listed in abi/layout.c', file=sys.stderr)
            bad = 1
        elif k not in want:
            print(f'  {k} is listed in abi/layout.c but is not a public type', file=sys.stderr)
            bad = 1
        elif want[k] != have[k]:
            print(f'  {k}: fields in the header {want[k]}, listed in abi/layout.c {have[k]}', file=sys.stderr)
            bad = 1
    return bad


def split_params(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
            continue
        depth += (ch == '(') - (ch == ')')
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return [] if out == ['void'] else out


def sections(dwarf, aux, type_prefix, func_prefix, include_dir):
    d = Dwarf(dwarf, type_prefix)
    functions = {}
    proto_re = re.compile(r'^/\* ([^:]+):\d+:NC \*/ extern (.+?) ?\b(' + re.escape(func_prefix) + r'\w+) \((.*)\);$')
    for line in open(aux):
        m = proto_re.match(line.strip())
        if m and m.group(1).startswith(include_dir):
            functions[m.group(3)] = (m.group(2).strip(), split_params(m.group(4)))
    for n in sorted(d.enums):
        print(f'enum {n}')
        for e, v in d.enums[n]:
            print(f'  value {e} {v}')
    for n in sorted(d.callbacks):
        r, p = d.callbacks[n]
        print(f'callback {n} returns {r} params {len(p)} ({", ".join(p)})')
    for n in sorted(functions):
        r, p = functions[n]
        print(f'function {n} returns {r} params {len(p)} ({", ".join(p)})')
    return 0


def enumerators(dwarf, type_prefix):
    d = Dwarf(dwarf, type_prefix)
    for e, v in sorted(v for values in d.constants.values() for v in values):
        print(f'enumerator {e} {v}')
    return 0


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'classify':
        sys.exit(classify(*args))
    if cmd == 'enumerators':
        sys.exit(enumerators(*args))
    if cmd == 'program':
        sys.exit(program(args[0], args[1], args[2], args[3:]))
    if cmd == 'complete':
        sys.exit(complete(*args))
    if cmd == 'sections':
        sys.exit(sections(*args))
    sys.exit(f'abi.py: unknown command {cmd}')
