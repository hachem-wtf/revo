#!/usr/bin/env bash
DOCS_PATH=./_ign-web/
HASH=$(git rev-parse --short HEAD)
STDOCPATH=$DOCS_PATH/content/std.html

cp ./*.md ./_ign-web/content/
cp ./*.html ./_ign-web/content/
rm ./_ign-web/content/README.md

"$(git rev-parse --show-toplevel)/zig-out/bin/revo" doc --html --splice ../src/std/iface/ < "$STDOCPATH" > ./std-output.html
mv ./std-output.html $STDOCPATH

cd $DOCS_PATH
git add --all
git commit -m "auto update from #$HASH"

# read -p "do i push [y/n] " choice
# case "$choice" in 
#   y|Y ) echo "git push";;
#   n|N ) echo "ok";;
#   * ) echo "ok whatever";;
# esac
