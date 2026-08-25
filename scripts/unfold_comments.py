#!/usr/bin/env python3
"""Unfold wrapped Swift comments so one idea occupies one line.

    python3 scripts/unfold_comments.py $(find Sources -name '*.swift')

Folding a comment across several short lines inflates a file's line count for
no benefit, which matters against a per-file line budget. This joins a
paragraph's continuation lines back together. It is MECHANICAL only: it never
deletes a word and never touches code. Trimming the prose itself is a judgment
call and stays a hand job.

Every guard below exists because it caught a real corruption. Anything
uncertain is left folded — a missed join costs nothing, a wrong join silently
mangles documentation:

  * Xcode headers, where the filename and project name are consecutive bare
    tokens and must not merge.
  * Column-aligned blocks — tables, ladders, ASCII diagrams, pasted code.
  * Bullets, which absorb their own continuations but never each other, and
    never the dedented paragraph that follows the list.
  * `- Parameter` / `- Returns` doc lists.
  * Swift multi-line string literals, whose contents can start with `//`.
  * Words broken mid-hyphen across a wrap, which must rejoin with no space.

Verify a run with: strip every full-line comment from HEAD and from the working
tree and diff them. They must be identical.
"""

import re
import sys
from pathlib import Path

COMMENT = re.compile(r'^(\s*)(///|//)( ?)(.*)$')

# B must not begin a new structural element.
BLOCKERS = re.compile(
    r'^('
    r'MARK:|TODO|FIXME|NOTE:|WARNING:|'          # section + callout markers
    r'-\s|\*\s|•|'                               # bullets
    r'\d+[.)]\s|'                                # numbered lists
    r'#|```|'                                    # headings, fences
    r'[A-Za-z]+:\s*$'                            # bare "Label:" line
    r')'
)

# Doc bullets: "- Parameter x:", "- Returns:", etc. already covered by "-\s".
PARAM = re.compile(r'^-\s*(Parameter|Parameters|Returns|Throws|Note|Important|Warning)\b')

BULLET = re.compile(r'^([*\-•]|\d+[.)])\s+\S')

# A hyphen at a wrap point usually splits one word, but English also suspends a
# hyphen before a conjunction ("pre- and post-processing"). Those keep the space.
SUSPENDED = {'and', 'or', 'to', 'the', 'nor', 'but'}


def is_structural(text: str) -> bool:
    """Column-aligned content — tables, ladders, ASCII diagrams, code samples.

    Indentation alone is NOT the signal; an indented sub-paragraph under a
    numbered step is ordinary prose and should fold. What marks a column is a
    run of two or more spaces INSIDE the line, or a tab.
    """
    return '\t' in text or re.search(r'\S {2,}\S', text) is not None


def is_bullet(text: str) -> bool:
    """A list item, with or without leading indent."""
    return bool(BULLET.match(text.lstrip()))


def indent_of(text: str) -> int:
    return len(text) - len(text.lstrip())


def joinable(a_indent, a_marker, a_text, b_indent, b_marker, b_text) -> bool:
    if a_indent != b_indent or a_marker != b_marker:
        return False
    if not a_text.strip() or not b_text.strip():
        return False                       # blank comment line = paragraph break

    # A bullet absorbs its own wrapped continuation. B must be indented DEEPER
    # than the bullet; a line that dedents is the paragraph after the list.
    if is_bullet(a_text):
        if is_bullet(b_text) or indent_of(b_text) <= indent_of(a_text):
            return False
        return not PARAM.match(b_text.lstrip())

    if is_structural(a_text) or is_structural(b_text):
        return False
    # Never pull a hanging block up into a lead line at a different indent.
    if indent_of(a_text) != indent_of(b_text):
        return False
    if BLOCKERS.match(a_text.lstrip()) or BLOCKERS.match(b_text.lstrip()):
        return False
    if PARAM.match(a_text) or PARAM.match(b_text):
        return False
    if a_text.rstrip().endswith(':'):
        return False                       # introduces a list or block
    # Two consecutive bare tokens are metadata, not prose — the Xcode header's
    # filename and project name. One bare token after prose is just a short last
    # word ("...their slot are" / "truncated.") and folds normally.
    if ' ' not in a_text.strip() and ' ' not in b_text.strip():
        return False
    if '```' in a_text or '```' in b_text:
        return False
    return True


def rejoin(left: str, right: str) -> str:
    """Join two comment fragments, closing a word broken across the wrap."""
    first_word = right.split(' ', 1)[0].rstrip('.,;:').lower()
    broken_word = (
        re.search(r'[A-Za-z]-$', left) is not None
        and right[:1].isalpha()
        and first_word not in SUSPENDED
    )
    return left + ('' if broken_word else ' ') + right


def unfold(lines):
    out = []
    in_multiline_string = False
    i = 0
    while i < len(lines):
        line = lines[i]

        # Swift multi-line string literals can contain lines starting with //.
        if line.count('"""') % 2 == 1:
            in_multiline_string = not in_multiline_string
            out.append(line)
            i += 1
            continue
        if in_multiline_string:
            out.append(line)
            i += 1
            continue

        m = COMMENT.match(line)
        if not m:
            out.append(line)
            i += 1
            continue

        indent, marker, _, text = m.groups()
        merged = text
        j = i + 1
        while j < len(lines):
            if lines[j].count('"""') % 2 == 1:
                break
            n = COMMENT.match(lines[j])
            if not n:
                break
            b_indent, b_marker, _, b_text = n.groups()
            if not joinable(indent, marker, merged, b_indent, b_marker, b_text):
                break
            merged = rejoin(merged.rstrip(), b_text.strip())
            j += 1

        out.append(f'{indent}{marker} {merged}'.rstrip())
        i = j
    return out


def main(paths):
    changed = 0
    for p in paths:
        path = Path(p)
        original = path.read_text().splitlines()
        result = unfold(original)
        if result != original:
            path.write_text('\n'.join(result) + '\n')
            changed += 1
            print(f'{len(original) - len(result):5d}  {p}')
    print(f'\n{changed} files changed')


if __name__ == '__main__':
    main(sys.argv[1:])
