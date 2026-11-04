#!/bin/bash
# assemble <Name> from parts/<Name>.body.html + _base.css into <Name>.dc.html
# second argument "dark" appends the dark override block and writes <Name>Dark.dc.html
set -e
n="$1"; variant="$2"; out="$n"
[ "$variant" = "dark" ] && out="${n}Dark"
{
printf '<!doctype html>\n<html>\n<head>\n  <meta charset="utf-8">\n  <script src="./support.js"></script>\n</head>\n<body>\n<x-dc>\n<helmet>\n'
printf '  <style>\n'
cat _base.css
[ "$variant" = "dark" ] && cat _dark.css
printf '  </style>\n</helmet>\n'
cat "parts/$n.body.html"
printf '</x-dc>\n</body>\n</html>\n'
} > "$out.dc.html"
echo "built $out.dc.html ($(wc -c < "$out.dc.html") bytes)"
