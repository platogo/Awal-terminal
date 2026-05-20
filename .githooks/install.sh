#!/bin/sh
# Run once per clone to enable project git hooks
git config core.hooksPath .githooks
echo "Git hooks installed (.githooks/)"
