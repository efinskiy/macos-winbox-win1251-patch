#!/usr/bin/env python3
"""Validate the release tag against the sole application version source."""
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def version():
    value = (ROOT/'VERSION').read_text().strip()
    if re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value) is None:
        raise ValueError('VERSION must contain MAJOR.MINOR.PATCH')
    tag = os.environ.get('RELEASE_TAG', '')
    if tag and tag != 'v'+value:
        raise ValueError(f'Release tag {tag!r} does not match VERSION {value!r}')
    return value


if __name__ == '__main__':
    value = version()
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('version='+value+'\n')
    print(value)
