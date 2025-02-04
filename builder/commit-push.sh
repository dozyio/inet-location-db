#!/bin/bash
set -e 

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

git add *.txt

if ! git diff-index --quiet HEAD --; then
  git commit -m "Update generated output .txt files"

  git push origin HEAD
else
  echo "No changes detected. Nothing to commit."
fi
