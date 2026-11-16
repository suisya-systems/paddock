#!/usr/bin/env bash
# Shared test helper: hc_doc_stub <dir> writes a stub hc into <dir> that answers only `hc connect`
# doc.get / doc.set, as the core does, so org-escalation (the merge card of org-pull-request) runs
# with no core. The documents live in $STUB/docval-<name> and $STUB/docver-<name>; every call is
# appended to $STUB/hc-calls. Source it.
hc_doc_stub() {
  cat > "$1/hc" <<'EOF2'
#!/bin/sh
echo "$*" >> "$STUB/hc-calls"
[ "$1" = connect ] || exit 0
read -r req
method=$(printf '%s' "$req" | sed 's/.*"method":"\([^"]*\)".*/\1/')
name=$(printf '%s' "$req" | sed 's/.*"name":"\([^"]*\)".*/\1/')
ver() { cat "$STUB/docver-$name" 2>/dev/null || echo 0; }
val() { cat "$STUB/docval-$name" 2>/dev/null || echo null; }
case "$method" in
  doc.get) printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":%s}}\n' "$(val)" "$(ver)" ;;
  doc.set)
    v=$(printf '%s' "$req" | sed 's/.*"version":\([0-9]*\)}}$/\1/')
    printf '%s' "$req" | sed 's/.*"value":\(.*\),"version":[0-9]*}}$/\1/' > "$STUB/docval-$name"
    echo $(( v + 1 )) > "$STUB/docver-$name"
    printf '{"jsonrpc":"2.0","id":1,"result":{"version":%s}}\n' "$(ver)" ;;
esac
exit 0
EOF2
  chmod +x "$1/hc"
}
