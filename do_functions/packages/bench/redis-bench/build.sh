#!/usr/bin/env bash

set -euo pipefail

virtualenv --without-pip virtualenv
pip install -r requirements.txt --target virtualenv/lib/python3.13/site-packages
