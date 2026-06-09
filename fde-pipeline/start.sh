#!/bin/bash
set -euo pipefail

if [ -f ".env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

export FLASK_APP=app.py
export FLASK_ENV=development
export PYTHONUNBUFFERED=1

flask run --host=0.0.0.0 --port="${PORT:-5000}"
