#!/usr/bin/env python3
"""check_tables.py <repo-root> [--update] — the control-table rules (the tables stage; run by check_tables.sh with python3 -I).

A table is (1) a tracked *.def with an X( row, (2) a function-like macro #define NAME(X) whose body is X( rows, or (3) in the
repository's C sources (not tests/, not app/extern/) a const array of more than one row with a brace initializer (plain char
strings and all-zero arrays aside). Only tracked and new unignored files are read (git ls-files), never build/ or app/extern/.

  R1  header: the comment before the rows holds the signature X(c1, c2, ...) whose arity is every row's, or "Same X(...) columns
      as <file>.def" naming a .def of that arity (the repository or build/sysroot/include); every column is named again with a
      description; a row count the header states ("The 15 rows", "16 tokens") is the row count
  R2a the table is expanded into an enum whose last enumerator ends in _COUNT (_max, _MAX, _DEF_COUNT, _LAST: rule sentinel-name)
  R2b some _Static_assert of the repository names that sentinel
  R2c an initialized array sized by a sentinel ([X_COUNT], [X_max], [X_MAX]) expands a .def or an X-list
  R2d any other multi-row const table (kind 3) is named by a _Static_assert of its file
  R3  tests/ reach the table: (i) a test expands it between #define X and #undef X, (ii) a test's for loop is bounded by its
      sentinel, or (iii) a golden entry names a golden file a test reads; for reason, finding and route tables only (i)
  R4  column 1 is unique, every @key column or @key(a,b) tuple is unique, every string column not tagged @dup is unique (a route
      table without tags: the row minus column 1 is unique)
  R5  a table whose header says append-only, or tagged @stored or @wire, is recorded in abi/tables.txt ("<def> <index> <column 1>
      <string columns>"; @keyed: no index); a changed or removed line needs a raised major against the newest v<x.y.z> tag
      (else HEAD); --update writes the file
  R6  report only: a switch in the C sources with more than 6 case labels, an enum (case-label prefix) switched in 3 or more places

tables.allow at the root, '#' comments: "allow <path>[:<symbol>] <rule> <reason>" (the reason required) and "golden <path.def>
<golden file>"; an entry that matches nothing fails. KYR_TABLES_WARN=1 reports and exits 0 (one release, then the stage is hard).
"""
import os
import re
import subprocess
import sys

ID = r"[A-Za-z_][A-Za-z0-9_]*"
SENTINEL_OK = re.compile(r"_COUNT$")
SENTINEL_OTHER = re.compile(r"(_max|_MAX|_DEF_COUNT|_LAST)$")
SIZE_SENTINEL = re.compile(r"^(" + ID + r"(?:_COUNT|_max|_MAX))$")
COUNT_WORDS = (r"rows?|entries|tokens|routes|findings|capabilities|reasons|dbis|DBIs|keys|members|labels|kinds|records|envs"
               r"|levels|states|commands|verbs")
STRICT_TEST = re.compile(r"(reason|finding|route)", re.IGNORECASE)
ASSERT_RE = re.compile(r"\b(_Static_assert|static_assert|KYR_STATIC_ASSERT|KYR_TABLE_ASSERT)\s*\(")
INC_ROOTS = ["app/src", "app/include", "app", "include", "src", "", "tests"]


def git_files(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    new = subprocess.run(["git", "-C", root, "ls-files", "-z", "--others", "--exclude-standard"], capture_output=True,
                         check=True).stdout
    names = sorted({n.decode() for n in (out + new).split(b"\0") if n})
    keep = []
    for n in names:
        if n.startswith("build/") or n.startswith("app/extern/"):
            continue
        p = os.path.join(root, n)
        if os.path.isfile(p) and not os.path.islink(p):
            keep.append(n)
    return keep


def blank_comments(text):
    """(code, comments): code is text with every comment replaced by spaces (newlines kept, offsets unchanged); comments is
    [(start, end, body)]."""
    out = list(text)
    comments = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            comments.append((i, j, text[i + 2:j]))
            for k in range(i, j):
                out[k] = " "
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            comments.append((i, j, text[i + 2:j - 2]))
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            i = j + 1
        else:
            i += 1
    return "".join(out), comments


def balanced(code, i):
    """code[i] is '(' or '{': the index just past its partner, honouring string and char literals."""
    open_c = code[i]
    close_c = ")" if open_c == "(" else "}"
    depth, j, n = 0, i, len(code)
    while j < n:
        c = code[j]
        if c in "\"'":
            k = j + 1
            while k < n and code[k] != c and code[k] != "\n":
                k += 2 if code[k] == "\\" else 1
            j = k + 1
            continue
        if c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def split_args(s):
    args, depth, cur, i, n = [], 0, [], 0, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            k = i + 1
            while k < n and s[k] != c:
                k += 2 if s[k] == "\\" else 1
            cur.append(s[i:k + 1])
            i = k + 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    tail = "".join(cur).strip()
    if tail or args:
        args.append(tail)
    return args


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def is_string(arg):
    return bool(re.fullmatch(r'(?:[LuU]?"(?:[^"\\]|\\.)*"\s*)+', arg.strip()))


class Table:
    def __init__(self, kind, path, name, rows, header, line, text):
        self.kind, self.path, self.name, self.rows, self.header, self.line, self.text = kind, path, name, rows, header, line, text
        self.sentinel = None


class Checker:
    def __init__(self, root):
        self.root = root
        self.files = git_files(root)
        self.cache = {}
        self.findings = []      # (path, line, rule, symbol, text, report_only)
        self.allow, self.golden, self.allow_used, self.golden_used = [], [], set(), set()
        self.bad_allow = []
        self.tables = []
        self.c_files = [f for f in self.files if f.endswith((".c", ".h", ".inc", ".def"))]
        self.src_files = [f for f in self.files if f.endswith((".c", ".h", ".inc")) and not f.startswith("tests/")
                          and not f.startswith("share/template/")]
        self.test_files = [f for f in self.files if f.startswith("tests/") and f.endswith((".c", ".h", ".inc"))]

    def read(self, path):
        if path not in self.cache:
            with open(os.path.join(self.root, path), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            code, comments = blank_comments(text)
            self.cache[path] = (text, code, comments)
        return self.cache[path]

    def add(self, path, line, rule, symbol, text, report=False):
        self.findings.append((path, line, rule, symbol, text, report))

    # ---- allow file ----
    def load_allow(self):
        p = os.path.join(self.root, "tables.allow")
        if not os.path.isfile(p):
            return
        with open(p, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                s = raw.strip()
                if not s or s.startswith("#"):
                    continue
                parts = s.split(None, 3)
                if parts[0] == "allow" and len(parts) == 4:
                    target, rule, reason = parts[1], parts[2], parts[3]
                    path, _, sym = target.partition(":")
                    self.allow.append((n, path, sym, rule, reason))
                elif parts[0] == "golden" and len(parts) == 3:
                    self.golden.append((n, parts[1], parts[2]))
                else:
                    self.bad_allow.append(n)

    def allowed(self, path, symbol, rule):
        hit = False
        for entry in self.allow:
            n, p, sym, r, _ = entry
            if p == path and r == rule and (not sym or sym == symbol):
                self.allow_used.add(n)
                hit = True
        return hit

    # ---- includes ----
    def resolve(self, includer, target, quoted):
        cands = []
        if quoted:
            cands.append(os.path.normpath(os.path.join(os.path.dirname(includer), target)))
        for r in INC_ROOTS:
            cands.append(os.path.normpath(os.path.join(r, target)) if r else os.path.normpath(target))
        for c in cands:
            if c in self.file_set:
                return c
        ends = [f for f in self.files if f.endswith("/" + target) or f == target]
        return ends[0] if len(ends) == 1 else None

    def includes(self, path):
        """[(pos, resolved path)] of every #include in path."""
        text, code, _ = self.read(path)
        out = []
        for m in re.finditer(r'^[ \t]*#[ \t]*include[ \t]*([<"])([^>"]+)[>"]', code, re.M):
            r = self.resolve(path, m.group(2), m.group(1) == '"')
            if r:
                out.append((m.start(), r))
        return out

    # ---- discovery ----
    def rows_in(self, code, start, end):
        rows = []
        for m in re.finditer(r"(?<![A-Za-z0-9_])X\s*\(", code[start:end]):
            i = start + m.end() - 1
            j = balanced(code, i)
            rows.append((start + m.start(), split_args(code[i + 1:j - 1])))
        return rows

    def discover(self):
        self.file_set = set(self.files)
        for f in self.files:
            if not f.endswith(".def"):
                continue
            text, code, comments = self.read(f)
            if not re.search(r"^\s*X\s*\(", code, re.M):
                continue
            rows = [(p, a) for p, a in self.rows_in(code, 0, len(code)) if not code[code.rfind("\n", 0, p) + 1:p].strip()]
            first = rows[0][0] if rows else len(code)
            header = "\n".join(body for s, e, body in comments if s < first)
            self.tables.append(Table("def", f, f, rows, header, line_of(text, first), text))
        for f in self.c_files:
            if f.endswith(".def"):
                continue
            text, code, comments = self.read(f)
            for m in re.finditer(r"^[ \t]*#[ \t]*define[ \t]+(" + ID + r")\(\s*X\s*\)", code, re.M):
                end = m.end()
                while True:
                    nl = code.find("\n", end)
                    if nl < 0:
                        end = len(code)
                        break
                    if code[:nl].rstrip(" \t").endswith("\\"):
                        end = nl + 1
                        continue
                    end = nl
                    break
                rows = self.rows_in(code, m.end(), end)
                if not rows:
                    continue
                header = ""
                for s, e, body in reversed(comments):
                    if e <= m.start() and not code[e:m.start()].strip():
                        header = body
                        break
                self.tables.append(Table("xlist", f, m.group(1), rows, header, line_of(text, m.start()), text))

    # ---- expansions of a table: [(path, pos)] ----
    def expansions(self, t):
        out = []
        if t.kind == "def":
            for f in self.c_files:
                if f == t.path:
                    continue
                for pos, r in self.includes(f):
                    if r == t.path:
                        out.append((f, pos))
            # a .inc that includes the def counts through every file including the .inc
            for f, pos in list(out):
                if f.endswith(".inc"):
                    for g in self.c_files:
                        for p2, r2 in self.includes(g):
                            if r2 == f:
                                out.append((g, p2, f))
        else:
            for f in self.c_files:
                _, code, _ = self.read(f)
                for m in re.finditer(r"(?<![A-Za-z0-9_#])" + re.escape(t.name) + r"\s*\(", code):
                    line_start = code.rfind("\n", 0, m.start()) + 1
                    if re.match(r"[ \t]*#[ \t]*define", code[line_start:m.start()]):
                        continue
                    out.append((f, m.start()))
        return out

    def enclosing_enum(self, path, pos):
        """The last enumerator of the enum whose body holds pos, or None."""
        _, code, _ = self.read(path)
        depth, i = 0, pos
        while i > 0:
            i -= 1
            c = code[i]
            if c == "}":
                depth += 1
            elif c == "{":
                if depth == 0:
                    break
                depth -= 1
        else:
            return None
        if code[i] != "{":
            return None
        before = code[max(0, i - 200):i]
        if not re.search(r"\benum(\s+" + ID + r")?\s*$", before):
            return None
        end = balanced(code, i)
        body = code[i + 1:end - 1]
        lines = [ln for ln in body.split("\n") if not re.match(r"\s*#", ln)]
        body = "\n".join(lines)
        body = re.sub(r"\b" + ID + r"\s*\([^()]*(\([^()]*\)[^()]*)*\)", " ", body)  # an X-list invocation or macro call
        items = [x.strip() for x in body.split(",") if x.strip()]
        if not items:
            return None
        m = re.match(ID, items[-1])
        return m.group(0) if m else None

    def rule_text_sentinel(self, t):
        sentinels = []
        for exp in self.expansions(t):
            s = self.enclosing_enum(exp[0], exp[1])
            if s:
                sentinels.append(s)
        good = [s for s in sentinels if SENTINEL_OK.search(s)]
        if good:
            return good[0], None
        other = [s for s in sentinels if SENTINEL_OTHER.search(s)]
        if other:
            return other[0], "sentinel-name"
        return None, "R2a"

    # ---- the rules ----
    def header_tags(self, header):
        tags = {"key": [], "dup": set(), "stored": False, "keyed": False}
        for m in re.finditer(r"@key\(([^)]*)\)", header):
            tags["key"].append([c.strip() for c in m.group(1).split(",") if c.strip()])
        for m in re.finditer(r"@key\s+(" + ID + ")", header):
            tags["key"].append([m.group(1)])
        for m in re.finditer(r"@dup\(([^)]*)\)", header):
            tags["dup"].update(c.strip() for c in m.group(1).split(",") if c.strip())
        for m in re.finditer(r"@dup\s+(" + ID + ")", header):
            tags["dup"].add(m.group(1))
        tags["stored"] = bool(re.search(r"append[- ]only|@stored\b|@wire\b", header, re.I))
        tags["keyed"] = "@keyed" in header
        return tags

    def signature(self, t):
        """(columns, signature span text) or (None, reason)."""
        for m in re.finditer(r"\bX\s*\(([^()]*)\)", t.header):
            raw = [a.strip() for a in m.group(1).split(",")]
            cols, tags = [], {}
            ok = True
            for a in raw:
                parts = a.split()
                if not parts or not re.fullmatch(ID, parts[0]) or any(not re.fullmatch(r"@key|@dup", p) for p in parts[1:]):
                    ok = False
                    break
                cols.append(parts[0])
                tags[parts[0]] = parts[1:]
            if ok and cols:
                return cols, m.group(0), tags
        return None, None, None

    def same_as(self, t):
        m = re.search(r"Same\s+X\(\.\.\.\)\s+columns\s+as\s+`?([\w./-]+\.def)", t.header)
        if not m:
            return None
        name = m.group(1)
        found = [f for f in self.files if f.endswith(".def") and (f == name or f.endswith("/" + name))]
        if found:
            other = next((x for x in self.tables if x.path == found[0]), None)
            if other:
                cols, _, _ = self.signature(other)
                return (name, len(cols) if cols else (len(other.rows[0][1]) if other.rows else None))
        sysinc = os.path.join(self.root, "build/sysroot/include")
        for dirpath, _, names in os.walk(sysinc):
            for nm in names:
                full = os.path.join(dirpath, nm)
                if full.endswith("/" + name) or nm == name:
                    with open(full, encoding="utf-8", errors="replace") as fh:
                        txt = fh.read()
                    code, comments = blank_comments(txt)
                    rows = self.rows_in(code, 0, len(code))
                    return (name, len(rows[0][1]) if rows else None)
        return (name, None)

    def check_r1(self, t):
        arities = {len(a) for _, a in t.rows}
        for m in re.finditer(r"(?<![\w.-])(\d+)\s+(?:[a-z][a-z-]*\s+)?(" + COUNT_WORDS + r")\b", t.header):
            if int(m.group(1)) != len(t.rows):
                self.add(t.path, t.line, "R1", t.name, "the header says \"%s\", the table has %d rows" % (m.group(0), len(t.rows)))
        cols, sig, coltags = self.signature(t)
        if cols is None:
            same = self.same_as(t)
            if same is None:
                self.add(t.path, t.line, "R1", t.name, "no X(c1, c2, ...) signature in the header comment")
                return None, {}
            name, arity = same
            if arity is None:
                self.add(t.path, t.line, "R1", t.name, "the header names %s, which is not found" % name)
            elif arities != {arity}:
                self.add(t.path, t.line, "R1", t.name, "rows of arity %s, %s has %s" % (sorted(arities), name, arity))
            return None, {}
        if arities != {len(cols)}:
            self.add(t.path, t.line, "R1", t.name, "signature %s has %d columns, rows have %s" % (sig, len(cols), sorted(arities)))
        rest = t.header.replace(sig, " ", 1)
        for c in cols:
            if not re.search(r"(?<![A-Za-z0-9_])" + re.escape(c) + r"(?![A-Za-z0-9_])[`*'\"]*[ \t:=,\-—–]+[A-Za-z(]", rest):
                self.add(t.path, t.line, "R1", t.name, "column %s is not described in the header" % c)
        return cols, coltags

    def check_r2ab(self, t):
        s, problem = self.rule_text_sentinel(t)
        t.sentinel = s
        if problem == "R2a":
            self.add(t.path, t.line, "R2a", t.name, "not expanded into an enum whose last enumerator ends in _COUNT")
        elif problem == "sentinel-name":
            self.add(t.path, t.line, "sentinel-name", t.name, "the sentinel %s does not end in _COUNT" % s)
        if s:
            for f in self.c_files:
                _, code, _ = self.read(f)
                for m in ASSERT_RE.finditer(code):
                    j = balanced(code, m.end() - 1)
                    if re.search(r"\b" + re.escape(s) + r"\b", code[m.end():j]):
                        return
            self.add(t.path, t.line, "R2b", t.name, "no _Static_assert names %s" % s)

    def check_r3(self, t):
        strict = bool(STRICT_TEST.search(os.path.basename(t.path) if t.kind == "def" else t.name))
        for f in self.test_files:
            _, code, _ = self.read(f)
            sites = []
            if t.kind == "def":
                sites = [p for p, r in self.includes(f) if r == t.path]
            else:
                sites = [m.start() for m in re.finditer(r"(?<![A-Za-z0-9_#])" + re.escape(t.name) + r"\s*\(", code)]
            for p in sites:
                before = code[:p]
                d = [m.start() for m in re.finditer(r"^[ \t]*#[ \t]*define[ \t]+X\b", before, re.M)]
                u = [m.start() for m in re.finditer(r"^[ \t]*#[ \t]*undef[ \t]+X\b", before, re.M)]
                if d and (not u or u[-1] < d[-1]) and re.search(r"^[ \t]*#[ \t]*undef[ \t]+X\b", code[p:], re.M):
                    return
        if strict:
            self.add(t.path, t.line, "R3", t.name, "no test expands it between #define X and #undef X (a row ledger)")
            return
        if t.sentinel:
            pat = re.compile(r"\bfor\s*\([^;]*;[^;]*\b" + re.escape(t.sentinel) + r"\b[^;]*;")
            for f in self.test_files:
                if pat.search(self.read(f)[1]):
                    return
        for n, d, g in self.golden:
            if d == t.path and os.path.isfile(os.path.join(self.root, g)):
                base = os.path.basename(g)
                if any(base in self.read(f)[0] for f in self.files if f.startswith("tests/") and f != g):
                    self.golden_used.add(n)
                    return
        self.add(t.path, t.line, "R3", t.name, "no test reaches it (a #define X expansion, a for loop to its sentinel, a golden)")

    def check_r4(self, t, cols, coltags):
        tags = self.header_tags(t.header)
        names = cols or ["column %d" % (i + 1) for i in range(max((len(a) for _, a in t.rows), default=0))]
        for c, ts in (coltags or {}).items():
            if "@key" in ts:
                tags["key"].append([c])
            if "@dup" in ts:
                tags["dup"].add(c)

        def dup_check(label, keyf):
            seen = {}
            for pos, a in t.rows:
                k = keyf(a)
                if k is None:
                    continue
                if k in seen:
                    self.add(t.path, line_of(t.text, pos) if t.kind == "def" else t.line, "R4", t.name,
                             "%s repeats %s (first at row %d)" % (label, " ".join(k) if isinstance(k, tuple) else k, seen[k]))
                else:
                    seen[k] = len(seen) + 1
        dup_check(names[0] if names else "column 1", lambda a: a[0] if a else None)
        for key in tags["key"]:
            idx = [names.index(c) for c in key if c in names]
            if idx:
                dup_check("@key " + ",".join(key), lambda a, idx=idx: tuple(a[i] for i in idx) if max(idx) < len(a) else None)
        route = STRICT_TEST.search(os.path.basename(t.path)) and "route" in (os.path.basename(t.path) + t.name).lower()
        if route and not tags["key"]:
            dup_check("the row minus column 1", lambda a: tuple(a[1:]) if len(a) > 1 else None)
            return
        width = max((len(a) for _, a in t.rows), default=0)
        for i in range(1, width):
            col = names[i] if i < len(names) else "column %d" % (i + 1)
            if col in tags["dup"]:
                continue
            if all(i < len(a) and is_string(a[i]) for _, a in t.rows):
                dup_check(col, lambda a, i=i: a[i] if i < len(a) else None)

    # ---- R5 ----
    def r5_lines(self, t, cols):
        tags = self.header_tags(t.header)
        lines = []
        for idx, (_, a) in enumerate(t.rows):
            strs = [x for x in a[1:] if is_string(x)]
            head = [t.path] if tags["keyed"] else [t.path, str(idx)]
            lines.append(" ".join(head + [a[0] if a else ""] + strs))
        return lines

    def check_r5(self, update):
        want = []
        for t in self.tables:
            if t.kind == "def" and self.header_tags(t.header)["stored"]:
                want.extend(self.r5_lines(t, None))
        path = os.path.join(self.root, "abi/tables.txt")
        if update:
            if want:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write("# abi/tables.txt: the append-only, stored and wire tables (check_tables.sh --update)\n")
                    fh.write("\n".join(want) + "\n")
                print("tables: wrote abi/tables.txt (%d rows)" % len(want))
            return
        if not want:
            return
        have = []
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                have = [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.startswith("#")]
        else:
            self.add("abi/tables.txt", 0, "R5", "", "missing: %d append-only rows unrecorded (check_tables.sh --update)" % len(want))
            return
        if have != want:
            missing = [x for x in want if x not in have]
            for x in missing[:5]:
                self.add("abi/tables.txt", 0, "R5", "", "unrecorded row: %s (check_tables.sh --update)" % x)
        base = self.baseline_rows()
        if base is None:
            return
        base_rows, base_major, where = base
        gone = [x for x in base_rows if x not in want]
        major = self.version_major()
        if gone and (major is None or base_major is None or major <= base_major):
            for x in gone[:10]:
                self.add("abi/tables.txt", 0, "R5", "", "changed or removed since %s without a raised major: %s" % (where, x))

    def git(self, *args):
        r = subprocess.run(["git", "-C", self.root] + list(args), capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else None

    def version_major(self):
        try:
            with open(os.path.join(self.root, "VERSION"), encoding="utf-8") as fh:
                return int(fh.read().strip().split(".")[0])
        except (OSError, ValueError):
            return None

    def baseline_rows(self):
        tag = (self.git("describe", "--tags", "--match", "v[0-9]*", "--abbrev=0") or "").strip()
        ref = tag or "HEAD"
        txt = self.git("show", ref + ":abi/tables.txt")
        if txt is None:
            return None
        ver = self.git("show", ref + ":VERSION")
        try:
            major = int(ver.strip().split(".")[0]) if ver else None
        except ValueError:
            major = None
        rows = [ln for ln in txt.splitlines() if ln.strip() and not ln.startswith("#")]
        return rows, major, ref

    # ---- kind 3, R2c, R2d ----
    def arrays(self):
        decl = re.compile(r"(?:^|[;{}])\s*((?:static\s+)?(?:const\s+)?(?:(?:struct|enum|union)\s+" + ID + r"|" + ID +
                          r")(?:\s+const)?(?:\s*\*\s*(?:const\s*)?)*\s*\b(" + ID + r")\s*\[([^\]\[]*)\](?:\s*\[[^\]\[]*\])*\s*=\s*\{)")
        for f in self.src_files:
            if not f.endswith((".c", ".h", ".inc")):
                continue
            text, code, _ = self.read(f)
            depth = self.depths(code)
            for m in decl.finditer(code):
                spec = m.group(1)
                if not re.search(r"\bconst\b", spec):
                    continue
                if depth(m.start(1)) > 0 and not re.match(r"\s*static\b", spec):
                    continue    # a function's own stack list (an argv, a few keys): not a table
                name, size = m.group(2), m.group(3).strip()
                ob = m.end() - 1
                end = balanced(code, ob)
                body = code[ob + 1:end - 1]
                elems = [x for x in split_args(body) if x.strip()]
                pre = spec[:spec.rfind(name)]
                if re.match(r"\s*(?:static\s+)?(?:const\s+)?(?:unsigned\s+|signed\s+)?char\s*(?:const\s*)?$", pre.replace("\n", " ")):
                    continue
                expands = bool(re.search(r"#\s*include\s*[<\"][^>\"]+\.(def|inc)[>\"]", body)) or any(
                    re.search(r"(?<![A-Za-z0-9_])" + re.escape(t.name) + r"\s*\(", body) for t in self.tables if t.kind == "xlist")
                yield f, line_of(text, m.start(2)), name, size, elems, expands, code, pre

    @staticmethod
    def depths(code):
        """depth(pos): the brace depth at pos (string and char literals skipped)."""
        marks, d, i, n = [], 0, 0, len(code)
        while i < n:
            c = code[i]
            if c in "\"'":
                k = i + 1
                while k < n and code[k] != c and code[k] != "\n":
                    k += 2 if code[k] == "\\" else 1
                i = k + 1
                continue
            if c == "{":
                d += 1
                marks.append((i, d))
            elif c == "}":
                d -= 1
                marks.append((i, d))
            i += 1
        import bisect
        keys = [m[0] for m in marks]

        def depth(pos):
            j = bisect.bisect_left(keys, pos) - 1
            return marks[j][1] if j >= 0 else 0
        return depth

    def check_arrays(self):
        for f, line, name, size, elems, expands, code, pre in self.arrays():
            if SIZE_SENTINEL.match(size):
                if not expands:
                    self.add(f, line, "R2c", name, "%s[%s] is initialized by hand: expand the .def, or declare it [] with "
                             "_Static_assert(KYR_COUNTOF(%s) == %s)" % (name, size, name, size))
                continue
            if expands or len(elems) <= 1:
                continue
            if all(re.fullmatch(r"\{?\s*0[uUlL]*\s*\}?|NULL|\{\s*\}", e.strip()) for e in elems):
                continue
            chars = [re.fullmatch(r"'(?:[^'\\]|\\.[^']*)'", e.strip()) for e in elems]
            byte_type = bool(re.search(r"\b(uint8_t|int8_t|char)\b", pre))
            literal = all(c or re.fullmatch(r"(0x[0-9A-Fa-f]{1,2}|\d{1,3})[uU]?", e.strip()) for c, e in zip(chars, elems))
            if literal and (all(chars) or (byte_type and len(elems) < 64)):
                continue    # a short byte string (a file magic, a mask), not a table
            named = False
            for m in ASSERT_RE.finditer(code):
                j = balanced(code, m.end() - 1)
                if re.search(r"\b" + re.escape(name) + r"\b", code[m.end():j]):
                    named = True
                    break
            if not named:
                self.add(f, line, "R2d", name, "%s (%d rows) is named by no _Static_assert" % (name, len(elems)))

    # ---- R6 ----
    def check_switches(self):
        sites = []
        for f in self.src_files:
            if not f.endswith(".c"):
                continue
            text, code, _ = self.read(f)
            for m in re.finditer(r"\bswitch\s*\(", code):
                j = balanced(code, m.end() - 1)
                k = code.find("{", j)
                if k < 0 or code[j:k].strip():
                    continue
                end = balanced(code, k)
                body = code[k + 1:end - 1]
                flat, depth, out = body, 0, []
                i = 0
                while i < len(flat):        # drop nested switch bodies
                    mm = re.compile(r"\bswitch\s*\(").search(flat, i)
                    if not mm:
                        out.append(flat[i:])
                        break
                    out.append(flat[i:mm.start()])
                    jj = balanced(flat, mm.end() - 1)
                    kk = flat.find("{", jj)
                    i = balanced(flat, kk) if kk >= 0 else jj
                labels = re.findall(r"\bcase\s+([^:]+?)\s*:(?!:)", "".join(out))
                func = self.func_at(code, m.start())
                ln = line_of(text, m.start())
                if len(labels) > 6:
                    self.add(f, ln, "R6", func, "switch with %d case labels in %s(): a table?" % (len(labels), func), report=True)
                idents = {x.strip() for x in labels if re.fullmatch(r"[A-Z][A-Z0-9_]*", x.strip())}
                if len(idents) >= 3:
                    sites.append((f, ln, func, idents))
        # one enum switched in several places: switches sharing at least half of the smaller label set
        seen = set()
        for i, (f, ln, func, labs) in enumerate(sites):
            if i in seen:
                continue
            group = [i]
            for j in range(i + 1, len(sites)):
                other = sites[j][3]
                if len(labs & other) * 2 >= min(len(labs), len(other)):
                    group.append(j)
            if len(group) >= 3:
                pre = os.path.commonprefix(sorted(set().union(*(sites[k][3] for k in group))))
                for k in group:
                    seen.add(k)
                    g = sites[k]
                    self.add(g[0], g[1], "R6", g[2], "%s* switched in %d places: one table?" % (pre, len(group)), report=True)

    @staticmethod
    def func_at(code, pos):
        best = "?"
        for m in re.finditer(r"^(?:[A-Za-z_][\w\s\*]*?\s\**)?(" + ID + r")\s*\([^;{]*\)\s*\{", code[:pos], re.M):
            best = m.group(1)
        return best

    # ---- run ----
    def run(self, update):
        self.load_allow()
        self.discover()
        if update:
            self.check_r5(True)
            return 0
        for t in self.tables:
            cols, coltags = self.check_r1(t)
            self.check_r2ab(t)
            self.check_r3(t)
            self.check_r4(t, cols, coltags)
        self.check_r5(False)
        self.check_arrays()
        self.check_switches()
        problems = reports = 0
        for path, line, rule, symbol, text, report in sorted(self.findings, key=lambda x: (x[0], x[1], x[2])):
            if self.allowed(path, symbol, rule):
                continue
            if report:
                reports += 1
                print("  %s:%s: %s (report): %s" % (path, line, rule, text))
            else:
                problems += 1
                print("  %s:%s: %s: %s" % (path, line, rule, text))
        for n in self.bad_allow:
            print("  BAD     tables.allow:%d: an entry is \"allow <path>[:<symbol>] <rule> <reason>\" or \"golden <def> <file>\"" % n)
            problems += 1
        for n, p, sym, rule, _ in self.allow:
            if n not in self.allow_used:
                print("  STALE   tables.allow:%d: allow %s%s %s matches nothing" % (n, p, ":" + sym if sym else "", rule))
                problems += 1
        for n, d, g in self.golden:
            if n not in self.golden_used and not (d in self.file_set and os.path.isfile(os.path.join(self.root, g))):
                print("  STALE   tables.allow:%d: golden %s %s names no table or no file" % (n, d, g))
                problems += 1
        ntab = len(self.tables)
        if problems:
            warn = os.environ.get("KYR_TABLES_WARN", "0") == "1"
            print("tables: %d problems in %d tables (%d reported)%s" % (problems, ntab, reports,
                                                                         " (KYR_TABLES_WARN=1: reported, not refused)" if warn else ""))
            return 0 if warn else 1
        print("tables: clean (%d tables, %d reported)" % (ntab, reports))
        return 0


def main():
    args = sys.argv[1:]
    update = "--update" in args
    args = [a for a in args if a != "--update"]
    root = os.path.realpath(args[0] if args else os.environ.get("ROOT_DIR", os.getcwd()))
    if subprocess.run(["git", "-C", root, "rev-parse", "--is-inside-work-tree"], capture_output=True).returncode != 0:
        print("check_tables: %s is not a git work tree" % root, file=sys.stderr)
        return 2
    return Checker(root).run(update)


if __name__ == "__main__":
    sys.exit(main())
