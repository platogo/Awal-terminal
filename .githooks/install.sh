#!/bin/sh
# Only needs to be run once per clone.
git config core.hooksPath .githooks
echo "Git hooks installed (.githooks/)"
