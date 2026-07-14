#!/usr/bin/env bash
# wrapper for register-agent.py
cd "$(dirname "$0")"
python3 register-agent.py "$@"
