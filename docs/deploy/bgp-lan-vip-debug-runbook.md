# BGP LAN VIP debug runbook

Debugging the unraid-lab LAN VIP (`10.10.210.30`, Cilium BGP Control Plane
peering with wrt-london). Plan: `add-metallb-lan-exposure`
(`syscode-ai-internal-plans`).

Topology: unraid-lab nodes (`192.168.122.0/24`, libvirt NAT'd, no LAN L2
presence) → Cilium (AS65001) → tailnet path (bookofshadows advertises the
subnet route) → wrt-london (AS65000, FRR/bgpd) → LAN.

## 1. Check status on both ends

**Cluster side:**

```bash
export KUBECONFIG=/tmp/unraid-lab-kubeconfig.yaml   # or fetch fresh, see step 7
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium bgp peers
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium bgp routes advertised ipv4 unicast
kubectl get ciliumbgpclusterconfigs,ciliumbgppeerconfigs,ciliumbgpadvertisements
```

**Router side:**

```bash
ssh root@wrt-london.wind-bearded.ts.net "vtysh -c 'show bgp summary'"
ssh root@wrt-london.wind-bearded.ts.net "vtysh -c 'show bgp neighbors 192.168.122.143'"
ssh root@wrt-london.wind-bearded.ts.net "ip route show table all | grep 192.168.122"
```

Healthy state: peers show `Established` on both sides, `PfxRcd`/`Advertised`
non-zero. `active`/`Active` with 0 messages on both sides = TCP never
connects — go to step 2.

## 2. Confirm the CRDs actually registered

The Cilium **operator** (a separate Deployment from the agent DaemonSet)
registers the BGP CRDs. Restarting the DaemonSet alone does not trigger
this — bit us once already.

```bash
kubectl get crd | grep ciliumbgp   # should list 5 CRDs
kubectl -n kube-system get deploy cilium-operator   # check AGE — stale after a values change?
kubectl -n kube-system rollout restart deploy/cilium-operator  # if stale
```

Agent pods block startup waiting for these CRDs
(`"Still waiting for Cilium Operator to register CRDs"` in
`kubectl -n kube-system logs ds/cilium -c cilium-agent`). They unblock
automatically once the CRDs land — no agent restart needed after the
operator's.

## 3. Validate the CR schema before assuming it's applied

`kubectl apply` errors don't always surface through ArgoCD cleanly — check
`OutOfSync` + `status.conditions[].message` on the Application, or dry-run
the manifests directly against the live CRD schema:

```bash
kubectl kustomize clusters/unraid-lab/apps/cilium-lan-vip/manifests | kubectl apply --dry-run=server -f -
```

Known past mistakes (schema doesn't match intuition):

- `peerAddress` is a bare IP, no `/32` suffix.
- `advertisementType: Service` (not an invented value like
  `LBServiceAddress`), with `service.addresses: [LoadBalancerIP]`.

## 4. Confirm the prerequisite path is actually live

BGP needs the same reachability the Omni SideroLink join needed — see
`omni-on-unraid` artifact `2026-07-16-libvirt-unraid-lab-tailnet-join.md`
for the original pattern this reuses.

```bash
# on wrt-london: is the route installed?
ssh root@wrt-london.wind-bearded.ts.net "ip route show table all | grep 192.168.122"

# on bookofshadows: is the masquerade exemption hitting?
ssh bookofshadows "iptables -t nat -L LIBVIRT_PRT -n -v --line-numbers"
# rule matching -d 100.125.63.88 should show non-zero pkts after a connect attempt
```

Both need owner action if missing: a Tailscale ACL `grants` entry
(`src: wrt-london-ts, dst: 192.168.122.0/24`), and the exemption rule in
`/etc/libvirt/hooks/network` on bookofshadows (source of truth:
`omni-on-unraid/contrib/libvirt-network-hook`) — `EXEMPT_IPS` list, add the
new destination, don't duplicate the whole conditional block.

## 5. Trace the packet with eBPF (cluster side)

```bash
kubectl exec -n kube-system <cilium-pod-on-the-node> -c cilium-agent -- \
  cilium-dbg monitor --type drop --type trace -v | grep '179\|<peer-ip>'
```

Trigger a fresh attempt in another shell while this runs
(`cilium bgp peers` is enough to prompt a reconnect). Confirms whether the
SYN leaves the node's `eth0` at all — if it does, the problem is downstream
of Cilium.

## 6. Packet capture on bookofshadows (no tcpdump/conntrack on the host)

Neither tool is installed on bookofshadows. Use an ephemeral container
instead of installing anything on the NAS:

```bash
ssh bookofshadows "docker run --rm --net=host --privileged -d --name bgp-capture nicolaka/netshoot sh -c \
  'tcpdump -i virbr0 -nn tcp port 179 -w /tmp/virbr0.pcap -c 5 & tcpdump -i tailscale1 -nn tcp port 179 -w /tmp/ts1.pcap -c 5 & wait'"

# trigger a connect attempt, then:
ssh bookofshadows "docker exec bgp-capture sh -c 'tcpdump -nn -r /tmp/virbr0.pcap; echo ---ts1---; tcpdump -nn -r /tmp/ts1.pcap'"

# clean up (self-removes, --rm)
ssh bookofshadows "docker stop bgp-capture"
```

Nothing on `virbr0` (the shared bridge) → check the VM's own tap interface
specifically:

```bash
ssh bookofshadows "virsh domiflist <vm-name>"   # get the vnetNN interface
ssh bookofshadows "docker exec -d bgp-capture sh -c 'timeout 20 tcpdump -i vnetNN -nn -U -w /tmp/vnetNN.pcap tcp port 179'"
# trigger, wait ~20s, then read /tmp/vnetNN.pcap same way
```

## 7. Fetch a fresh kubeconfig

```bash
/Users/giovanni/syscode/git/omni-on-unraid/.tools/bin/omnictl \
  --omniconfig /Users/giovanni/.talos/omni/config \
  kubeconfig --cluster unraid-lab -f /tmp/unraid-lab-kubeconfig.yaml
```

Known bug: this `omnictl` build (1.5.8, vs backend 1.9.3) sometimes writes
its PGP key to a literal `$HOME` directory instead of expanding the env var
— creates a stray `./$HOME/.talos/keys/...` in whatever directory you ran
it from. Harmless, just `rm -rf` it; don't confuse it with real repo
content.

## Known state (2026-08-08)

Diagnosed as far as possible from the hypervisor side: the SYN leaves the
Talos VM's Cilium egress hook but never reaches `virbr0`, and not even the
VM's own dedicated tap interface (`vnet25` for
`unraid-lab-control-planes-mgm6gd`) — the most granular point capturable
without VM-internal access. Cilium, libvirt forwarding/NAT, and the Tailscale
routing chain are all cleared. The drop is inside the Talos VM's own kernel
network stack, between Cilium's hand-off and the virtio NIC's transmit.

Next step needs `talosctl` against the node (maintenance API, reachable
only from bookofshadows per the join doc) — not more iptables/Cilium
tweaking.
