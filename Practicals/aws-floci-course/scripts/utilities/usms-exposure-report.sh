#!/usr/bin/env bash
# USMS exposure report - Lab 09 Exercise 3.
#
# Classifies EVERY network interface in usms-vpc as EXPOSED or ISOLATED from:
#   1. the route table of its subnet (explicit association, else the VPC main table)
#   2. its public address (the interface's own association, else its instance's)
#   3. the ingress rules of the security groups it wears
# Never from names, tags or descriptions: those are printed, never read for the verdict.
#
# Read-only. Writes outputs/lab-09-exposure.json. Always exits 0: a report, not a test.
#
# set -e is deliberately OFF. Every aws call below may legitimately fail on one object
# (a terminated instance's lingering interface, a group deleted since it was cached)
# and one failure must cost one row, not the whole report. -u and pipefail stay on so
# a typo or a broken pipe is still loud.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
[ -n "$VPC" ] && [ "$VPC" != "none" ] || { echo "USMS_VPC_ID is not set - source configs/lab-02.env" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/eni.json" 2>/dev/null \
  || echo '{"NetworkInterfaces":[]}' > "$TMP/eni.json"
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/rt.json" 2>/dev/null \
  || echo '{"RouteTables":[]}' > "$TMP/rt.json"
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/sg.json" 2>/dev/null \
  || echo '{"SecurityGroups":[]}' > "$TMP/sg.json"
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/ec2.json" 2>/dev/null \
  || echo '{"Reservations":[]}' > "$TMP/ec2.json"

python3 - "$TMP" "outputs/lab-09-exposure.json" << 'PY'
import ipaddress, json, subprocess, sys

tmp, out_path = sys.argv[1], sys.argv[2]
enis   = json.load(open(f"{tmp}/eni.json")).get("NetworkInterfaces", [])
rts    = json.load(open(f"{tmp}/rt.json")).get("RouteTables", [])
groups = {g["GroupId"]: g for g in json.load(open(f"{tmp}/sg.json")).get("SecurityGroups", [])}
insts  = {i["InstanceId"]: i
          for r in json.load(open(f"{tmp}/ec2.json")).get("Reservations", [])
          for i in r.get("Instances", [])}

# subnet -> route table; a subnet with no explicit association uses the main table
main_rt, by_subnet = None, {}
for rt in rts:
    for a in rt.get("Associations", []):
        if a.get("Main"):
            main_rt = rt
        elif a.get("SubnetId"):
            by_subnet[a["SubnetId"]] = rt

def igw_route(subnet):
    rt = by_subnet.get(subnet, main_rt)
    if rt is None:
        return None, "no route table"
    for r in rt.get("Routes", []):
        if (r.get("DestinationCidrBlock") == "0.0.0.0/0"
                and (r.get("GatewayId") or "").startswith("igw-")):
            return rt["RouteTableId"], r["GatewayId"]
    return rt["RouteTableId"], None

def group(gid):
    # a group not in the VPC cache (deleted, or in another VPC) is looked up once
    if gid not in groups:
        p = subprocess.run(["aws", "ec2", "describe-security-groups", "--group-ids", gid,
                            "--output", "json"], capture_output=True, text=True)
        try:
            groups[gid] = json.loads(p.stdout)["SecurityGroups"][0]
        except Exception:
            groups[gid] = {"GroupId": gid, "IpPermissions": [], "_missing": True}
    return groups[gid]

def internet_ports(gids):
    ports = set()
    for gid in gids:
        for p in group(gid).get("IpPermissions", []):
            if any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or \
               any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", [])):
                lo = p.get("FromPort")
                ports.add("all" if lo is None else str(lo))
    return sorted(ports)

def public_addr(eni):
    pub = (eni.get("Association") or {}).get("PublicIp")
    if not pub:
        iid = (eni.get("Attachment") or {}).get("InstanceId")
        pub = (insts.get(iid) or {}).get("PublicIpAddress")
    if not pub:
        return None
    # Floci reports 127.0.0.1 (a Docker port mapping) as the public address: an address
    # nobody on the internet can send to is not a public address.
    try:
        return pub if ipaddress.ip_address(pub).is_global else None
    except ValueError:
        return None

rows = []
for e in enis:
    iid = (e.get("Attachment") or {}).get("InstanceId")
    inst = insts.get(iid) or {}
    state = (inst.get("State") or {}).get("Name", "-")
    name = ({t["Key"]: t["Value"] for t in inst.get("Tags", [])}.get("Name")
            or e.get("Description") or e.get("InterfaceType") or e["NetworkInterfaceId"])
    gids = [g["GroupId"] for g in e.get("Groups", [])]
    rt_id, igw = igw_route(e.get("SubnetId"))
    pub = public_addr(e)
    open_ports = internet_ports(gids)

    # Verdict. No internet gateway route on the subnet: nothing from the internet can
    # arrive or return, whatever the groups say -> ISOLATED. With one, the interface is
    # EXPOSED - including the case of no ingress rule at all (usms-nat in the brief):
    # the path exists and one authorize-security-group-ingress opens it, so the review
    # must list it. The reason column says which of the two it is.
    if not igw:
        verdict, why = "ISOLATED", "no igw route on subnet"
    else:
        bits = ["igw route"]
        if pub:
            bits.append("public address")
        bits.append(f"sg allows {','.join(open_ports)} from 0.0.0.0/0" if open_ports
                    else "but no internet ingress rule")
        verdict, why = "EXPOSED", " + ".join(bits)
    if state == "terminated":
        why += " (lingering interface of a terminated instance)"

    rows.append({"interface": e["NetworkInterfaceId"], "name": name, "instanceState": state,
                 "subnet": e.get("SubnetId"), "routeTable": rt_id, "privateIp": e.get("PrivateIpAddress"),
                 "publicIp": pub, "groups": gids, "internetPorts": open_ports,
                 "verdict": verdict, "reason": why})

print("== USMS exposure report ==")
for r in sorted(rows, key=lambda x: (x["verdict"], x["name"])):
    print(f"  {r['name'][:20]:<20} {r['interface']:<22} {r['privateIp'] or '-':<12} "
          f"{r['publicIp'] or '-':<14} {r['verdict']:<9} {r['reason']}")
print(f"EXPOSED={sum(r['verdict']=='EXPOSED' for r in rows)}  "
      f"ISOLATED={sum(r['verdict']=='ISOLATED' for r in rows)}  interfaces={len(rows)}")
json.dump(rows, open(out_path, "w"), indent=2)
PY
