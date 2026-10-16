#!/usr/bin/env python3
"""Prepare comment-preserving JSONC path edits; never touch live files."""
import argparse
import json
import re
from pathlib import Path

OLD = '/home/tls'
NEW = '/var/lib/caddy/.local/share/caddy'
TOKEN = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}\[\]:,]|[^\s{}\[\]:,]+')


def document(path):
    text = Path(path).read_text(encoding='utf-8-sig')
    tokens = [m for m in TOKEN.finditer(text)
              if not m[0].isspace() and not m[0].startswith(('//', '/*'))]
    clean = ''.join(m[0] for m in tokens)
    value = json.loads(clean)
    spans = {}
    index = 0

    def parse(where):
        nonlocal index
        token = tokens[index]
        index += 1
        if token[0] == '{':
            if tokens[index][0] != '}':
                while True:
                    key = json.loads(tokens[index][0])
                    index += 2  # key and colon; json.loads already validated syntax
                    parse(where + (key,))
                    if tokens[index][0] != ',':
                        break
                    index += 1
            index += 1
        elif token[0] == '[':
            n = 0
            if tokens[index][0] != ']':
                while True:
                    parse(where + (n,))
                    n += 1
                    if tokens[index][0] != ',':
                        break
                    index += 1
            index += 1
        else:
            spans[where] = (token.start(), token.end(), json.loads(token[0]))
    parse(())
    return text, value, spans


def prepare(caddy, sing, out_caddy, out_sing):
    text, value, spans = document(caddy)
    storage = value.get('storage', {})
    if storage.get('module') != 'file_system' or storage.get('root') not in (OLD, NEW):
        raise ValueError('Expected explicit file_system storage root /home/tls or ' + NEW)
    source = storage['root']
    a, b, _ = spans[('storage', 'root')]
    Path(out_caddy).write_text(text[:a] + json.dumps(NEW) + text[b:], encoding='utf-8')
    references = []
    changes = 0
    if sing != '-':
        text, _, spans = document(sing)
        replacements = []
        for where, (a, b, val) in spans.items():
            if where and where[-1] in ('certificate_path', 'key_path') and isinstance(val, str):
                if val.startswith(OLD + '/'):
                    val = NEW + val[len(OLD):]
                    replacements.append((a, b, json.dumps(val)))
                if val.startswith(NEW + '/'):
                    # Paths are configuration input, but must stay inside storage.
                    Path(val).relative_to(NEW)
                    if '..' in Path(val).parts:
                        raise ValueError('Parent traversal in certificate path')
                    references.append(val)
        changes = len(replacements)
        for a, b, val in sorted(replacements, reverse=True):
            text = text[:a] + val + text[b:]
        Path(out_sing).write_text(text, encoding='utf-8')
    return {'source': source, 'sing_changes': changes,
            'references': sorted(set(references))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('caddy')
    parser.add_argument('sing')
    parser.add_argument('out_caddy')
    parser.add_argument('out_sing')
    args = parser.parse_args()
    print(json.dumps(prepare(args.caddy, args.sing, args.out_caddy, args.out_sing)))


if __name__ == '__main__':
    main()
