#!/usr/bin/env python3
"""A9: direct simulator URL/typed-intent delivery; no OS-default dispatch claim."""
from run_sdk_m3 import main

if __name__ == '__main__':
    raise SystemExit(main(direct=True))
