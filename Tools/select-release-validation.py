#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1

"""Select release validation using the published releases from gh api --paginate --slurp."""

import argparse
import json
import re
import subprocess
import sys


def version(tag):
    match = re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?', tag)
    if not match:
        raise ValueError(f'Unsupported release tag: {tag}')
    return tuple(int(part or '0') for part in match.groups())


def commit(ref):
    return subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}'], text=True).strip()


def selection(tag, pages):
    current = version(tag)
    source = commit(f'refs/tags/{tag}')
    if source != commit('HEAD'):
        raise ValueError(f'{tag} does not point to the checked-out release source')
    published = [record['tag_name'] for page in pages for record in page
                 if not record['draft'] and not record['prerelease'] and record['tag_name'] not in ('tip', tag)]
    tier, base = 'minor', ''
    if published:
        previous = max(published, key=version)
        baseline = version(previous)
        if current <= baseline:
            raise ValueError(f'{tag} must be newer than the published {previous}')
        if current[:2] == baseline[:2]:
            tier, base = 'quick', commit(f'refs/tags/{previous}')
            if subprocess.run(['git', 'merge-base', '--is-ancestor', base, source]).returncode != 0:
                raise ValueError(f'The published {previous} must precede {tag} in Git history')
    return {'tier': tier, 'source': source, 'base': base}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    try:
        for key, value in selection(args.tag, json.load(sys.stdin)).items():
            print(f'{key}={value}')
    except (ValueError, TypeError, KeyError, subprocess.CalledProcessError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
