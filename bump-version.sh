#!/usr/bin/env bash
set -e
N="$1"
if [ -z "$N" ]; then echo "Usage: bash bump-version.sh <number>"; exit 1; fi
perl -pi -e "s/\?v=[0-9]+/?v=$N/g" *.html
perl -pi -e "s{^/\* v[0-9]+ \*/}{/* v$N */}" assets/css/app.css
echo "Bumped everything to v$N. Push all *.html and assets/css/app.css."