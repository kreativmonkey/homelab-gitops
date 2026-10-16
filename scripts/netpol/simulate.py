#!/usr/bin/env python3
"""Replay observed flows against rendered NetworkPolicies.

usage: simulate.py <policies.yaml> <obsdir>
Reports flows the policies would drop (standard NetworkPolicy semantics, as
implemented by kube-network-policies). Only namespaces that appear in the
policy file count as "enforced". Input: flows-*.log from collect.sh plus
pods*.json / ns.json label snapshots (see the runbook). Pod names are shortened
to their owner prefix in the output.
"""
import collections, glob, ipaddress, json, os, sys
import yaml

pol_file, obs = sys.argv[1], sys.argv[2]
pols = [d for d in yaml.safe_load_all(open(pol_file)) if d and d.get("kind") == "NetworkPolicy"]
enforced = {p["metadata"]["namespace"] for p in pols}

pods = {}
for f in sorted(glob.glob(os.path.join(obs, "pods*.json"))):
    for p in json.load(open(f)):
        pods[f'{p["ns"]}/{p["name"]}'] = p
nsl = {n["name"]: n["labels"] for n in json.load(open(os.path.join(obs, "ns.json")))}
unknown = set()


def sel_match(sel, labels):
    if sel is None:
        return True
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        k, op, vals = e["key"], e["operator"], e.get("values", [])
        if op == "In" and labels.get(k) not in vals: return False
        if op == "NotIn" and labels.get(k) in vals: return False
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
    return True


def pod_labels(ref):
    p = pods.get(ref)
    if p is None:
        unknown.add(ref)
        return {}
    return p["labels"]


def port_match(ports, port, proto, podref):
    if not ports:
        return True
    for pp in ports:
        if (pp.get("protocol") or "TCP") != proto:
            continue
        if "port" not in pp:
            return True
        v = pp["port"]
        if isinstance(v, str):  # named port: resolve on the destination pod
            p = pods.get(podref)
            if p and any(c["name"] == v and c["port"] == port for c in p["ports"]):
                return True
            continue
        end = pp.get("endPort", v)
        if v <= port <= end:
            return True
    return False


def peer_match(peer, own_ns, ref, ip):
    if "ipBlock" in peer:
        net = ipaddress.ip_network(peer["ipBlock"]["cidr"])
        a = ipaddress.ip_address(ip)
        if a.version != net.version or a not in net:
            return False
        return not any(a in ipaddress.ip_network(x) for x in peer["ipBlock"].get("except", []))
    if ref is None:  # non-pod endpoint only matches ipBlock
        return False
    ns, _ = ref.split("/", 1)
    if "namespaceSelector" in peer:
        if not sel_match(peer["namespaceSelector"], nsl.get(ns, {"kubernetes.io/metadata.name": ns})):
            return False
    elif ns != own_ns:
        return False
    return sel_match(peer.get("podSelector"), pod_labels(ref))


def allowed(direction, pod_ref, peer_ref, peer_ip, port, proto, dst_ref):
    ns = pod_ref.split("/", 1)[0]
    if ns not in enforced:
        return True, None
    typ = direction.capitalize()
    sel = [p for p in pols if p["metadata"]["namespace"] == ns
           and typ in p["spec"].get("policyTypes", ["Ingress"])
           and sel_match(p["spec"].get("podSelector"), pod_labels(pod_ref))]
    if not sel:
        return True, None
    key = "ingress" if typ == "Ingress" else "egress"
    for p in sel:
        for rule in p["spec"].get(key) or []:
            peers = rule.get("from" if key == "ingress" else "to")
            if not port_match(rule.get("ports"), port, proto, dst_ref):
                continue
            if not peers or any(peer_match(x, ns, peer_ref, peer_ip) for x in peers):
                return True, p["metadata"]["name"]
    return False, ",".join(p["metadata"]["name"] for p in sel)


drops = collections.Counter()
for f in glob.glob(os.path.join(obs, "flows-*.log")):
    for line in open(f):
        parts = line.split()
        if len(parts) != 6:
            continue
        d, s, t, sip, dst, proto = parts
        dip, dport = dst.rsplit(":", 1)
        dport = int(dport)
        s = None if s in ("-", "external") else s
        t = None if t in ("-", "external") else t
        if t and dport >= 30000:  # reply leg of a pre-existing connection
            continue
        if d == "Egress" and s:
            ok, _ = allowed("egress", s, t, dip, dport, proto, t)
            if not ok:
                drops[("egress@" + s.split("/")[0], s.rsplit("-", 2)[0], t.split("/")[0] if t else dip, dport, proto)] += 1
        if d == "Ingress" and t:
            ok, _ = allowed("ingress", t, s, sip, dport, proto, t)
            if not ok:
                drops[("ingress@" + t.split("/")[0], s.split("/")[0] if s else sip, t.rsplit("-", 2)[0], dport, proto)] += 1

for (where, a, b, port, proto), n in sorted(drops.items()):
    print(f"{n:6d}  {where:28s} {a} -> {b}:{port}/{proto}")
if unknown:
    print(f"# {len(unknown)} pods without label snapshot (selectors treated as label-less):",
          " ".join(sorted(unknown))[:400], file=sys.stderr)
