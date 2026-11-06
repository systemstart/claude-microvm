# Assembles the session's egress allowlist and describes it for the session
# contract. Input: one "<source label>\t<raw allowlist line>" per line, in
# the order the sources were added (built-in lists first, EGRESS_ALLOW last).
#
#   -v deny=LIST       EGRESS_DENY, comma/space separated
#   -v mode=MODE       EGRESS_POLICY (alert|shadow|enforce)
#   -v builtin=0|1     EGRESS_BUILTIN; 0 says in the contract that the
#                      built-in lists were left out (the input has none)
#   -v allowout=FILE   the allowlist the proxy, alert matcher and report read:
#                      every raw line except the entries EGRESS_DENY removes
#   -v contractout=FILE  the rules block for the session contract
#   -v B D R G Y Z     bold, dim, red, green, yellow, reset (empty: no colour)
#
# The allowlist format has no deny rule. EGRESS_DENY drops each entry that is
# a denied domain or below one; a broader entry that still covers a denied
# domain cannot be narrowed, so it is marked and warned about instead.

function host(e) {
  sub(/#.*/, "", e); gsub(/^[ \t\r]+|[ \t\r]+$/, "", e)
  sub(/:[0-9]+$/, "", e); sub(/^\*\./, "", e); sub(/\.$/, "", e)
  return tolower(e)
}
# The entry as the contract shows it: normalized host, plus a non-443 port.
function shown(e,   p) {
  sub(/#.*/, "", e); gsub(/^[ \t\r]+|[ \t\r]+$/, "", e)
  p = (match(e, /:[0-9]+$/) && substr(e, RSTART + 1) != "443") ? substr(e, RSTART) : ""
  return host(e) p
}
function under(h, d) { return h == d || substr(h, length(h) - length(d)) == "." d }
# The broader EGRESS_DENY entry that already covers deny d, if any.
function cover(d,   i) {
  for (i = 1; i <= ndeny; i++) if (dorder[i] != d && under(d, dorder[i])) return dorder[i]
  return ""
}
# Word-wraps the space-separated items in s under a fixed indent.
function wrap(s, indent,   n, w, i, line, out) {
  n = split(s, w, " "); line = ""; out = ""
  for (i = 1; i <= n; i++) {
    if (line != "" && length(indent line " " w[i]) > 80) { out = out indent line "\n"; line = "" }
    line = line (line == "" ? "" : " ") w[i]
  }
  return out (line != "" ? indent line "\n" : "")
}

BEGIN {
  FS = "\t"
  nd = split(deny, raw, /[,[:space:]]+/)
  for (i = 1; i <= nd; i++) if ((d = host(raw[i])) != "" && !(d in ds)) { ds[d] = 1; dorder[++ndeny] = d }
  printf "" > allowout
}

{
  label = $1; line = substr($0, length($1) + 2)
  if (!(label in seen)) { seen[label] = 1; labels[++nl] = label }
  h = host(line)
  if (h == "") { print line > allowout; next }
  e = shown(line)
  mark = ""
  # Removal first: a deny that removes the entry makes any narrower deny
  # under it moot. Denies are walked in the order given, never `for (d in
  # ds)`, so the output does not depend on awk's hash order.
  for (i = 1; i <= ndeny; i++)
    if (under(h, d = dorder[i])) { mark = "✗"; removed[d] = removed[d] " " e " (" label ")"; nremoved++; break }
  if (mark == "")
    for (i = 1; i <= ndeny; i++)
      if (under(d = dorder[i], h)) { mark = "⚠"; wide[d] = wide[d] " " e " (" label ")"; nwide++ }
  if (mark != "✗") print line > allowout
  key = label SUBSEP mark e
  # Sorted by host later, so the marker rides after a "|" until then.
  if (!(key in entries)) { entries[key] = 1; list[label] = list[label] " " e "|" mark }
}

# Colours the markers once the text is wrapped, so escapes never count
# toward the line width.
function paint(s) {
  gsub(/✗[^ \n]*/, R "&" Z, s); gsub(/⚠[^ \n]*/, Y "&" Z, s)
  return s
}

END {
  ind = "                      "
  out = "  " B "allowlist" Z "     " D "highest precedence first; whatever matches nothing gets the last rule" Z "\n"
  if (ndeny > 0) {
    out = out "                " R "deny " Z " " B "EGRESS_DENY" Z "\n"
    s = ""; for (i = 1; i <= ndeny; i++) s = s " " dorder[i]
    out = out wrap(s, ind)
    for (i = 1; i <= ndeny; i++) {
      d = dorder[i]
      if (d in wide) out = out ind Y "⚠ " d " is NOT blocked — still allowed by" wide[d] Z "\n"
      else if (d in removed) continue
      else if ((c = cover(d)) != "") out = out ind D d ": redundant, " c " already denies it" Z "\n"
      else out = out ind D d ": nothing to remove, already unlisted" Z "\n"
    }
  }
  # Allows are a union — no order among them — listed most specific source
  # first: the session's own additions before the project's, built-ins last.
  for (i = nl; i >= 1; i--) {
    out = out "                " G "allow" Z " " B labels[i] Z "\n"
    n = split(substr(list[labels[i]], 2), es, " ")
    asort(es)
    s = ""; for (j = 1; j <= n; j++) { split(es[j], em, "|"); s = s " " em[2] em[1] }
    out = out paint(wrap(s, ind))
  }
  if (builtin == "0")
    out = out "                " D "off  " Z " " B "built-in lists" Z D " — EGRESS_BUILTIN=0: only the above, and the agent's model endpoints" Z "\n"
  if (mode == "enforce") last = R "deny " Z " " B "everything else" Z D ", and any port an entry does not grant" Z
  else if (mode == "shadow") last = Y "log  " Z " " B "everything else" Z D " as would_deny — nothing is blocked yet" Z
  else last = Y "alert" Z " " B "on everything else" Z D " — nothing is blocked" Z
  out = out "                " last "\n"
  # A legend for the marks that actually appear, and only those.
  legend = (nremoved > 0 ? "   ✗ removed by EGRESS_DENY" : "") (nwide > 0 ? "   ⚠ broader than a denied domain, so the deny loses" : "")
  if (legend != "") out = out ind D substr(legend, 4) Z "\n"
  printf "%s", out > contractout

  if (ndeny > 0) {
    printf "egress: EGRESS_DENY removed %d allowlist entr%s\n", nremoved, nremoved == 1 ? "y" : "ies" > "/dev/stderr"
    for (i = 1; i <= ndeny; i++) if ((d = dorder[i]) in wide)
      printf "warning: EGRESS_DENY=%s is still allowed via:%s — the allowlist cannot carve a subdomain out of a broader entry\n", d, wide[d] > "/dev/stderr"
  }
}
