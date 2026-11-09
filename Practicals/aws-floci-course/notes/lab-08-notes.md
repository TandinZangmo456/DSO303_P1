# Lab 08 notes

## Environment

- Floci restarted overnight and the k3s container exited. I recreated the cluster and node group from the Lab 07 templates, k3s reused its data, and I deleted the ghost node b216da0cd7ac.
- I stopped the DSO202 kind clusters (load average was about 37, swap was full, and one held port 30080).
- verify-lab-07.sh: PASS=29 FAIL=1. The failure is a false positive on outputs/.gitkeep.

## Step 3 - 10x traffic plan (draft, edit in your own words)

1. Dimension 1 (more pods): raise the HPA's maxReplicas, then check for Pending pods and node allocated CPU.
2. Dimension 3 (more nodes): raise the node group's maxSize/desiredSize, or let Cluster Autoscaler/Karpenter do it. Check that the new nodes are Ready and the Pending pods are scheduled.
3. Dimension 2 (bigger pods) only if one pod is CPU-bound. This replaces every pod and changes the HPA's denominator.
4. Dimension 4 (bigger nodes) last. It cannot change in place: create a new node group, cordon and drain the old one, then delete it.

## Step 6 - Guaranteed gateway

Burstable → Guaranteed → Burstable, and the pod was replaced each time. Changing requests/limits changes the pod template, which is dimension 2. That is why VPA is used much less than HPA. I would want Guaranteed for a latency-critical pod that must be evicted last.

## Step 9 - HPA observed

- 2% → 58%: ceil(2 × 58 / 50) = 3, so the HPA scaled 2 → 3. CPU then settled at 20–30%, so it went no higher.
- After the load stopped, it held 3 for the 300 s window, then scaled to 2.
- Events: "New size: 3; reason: cpu resource utilization (percentage of request) above target" and "New size: 2; reason: All metrics below target".

## Step 10 - Node group

update-nodegroup-config failed with 400 InvalidArgument (Floci 2.0.1 known issue). The node group stays at 2/4/2 and no node appeared.

## Step 16 - Ingress

No IngressClass or controller (k3s runs with --disable traefik). The Ingress is stored with no address. The AWS Load Balancer Controller would run: create-load-balancer, create-target-group --target-type ip, create-listener, create-rule per path.

## Step 17 - Comparison (fill in)

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | desiredCount | spec.replicas |
| Who writes it? | Application Auto Scaling | HPA controller |
| Where does that thing run? | AWS, outside my workload | Cluster controller manager |
| Where does the metric come from? | CloudWatch | metrics-server (metrics.k8s.io) |
| What does "50% CPU" mean? | % of task reserved CPU | % of container CPU request |
| How is scale-in slowed down? | ScaleInCooldown | scaleDown.stabilizationWindowSeconds |
| No capacity for the new instance/pod? | Fargate always finds capacity | Pod stays Pending |
| What creates the alarms? | Two CloudWatch alarms, created automatically | None, the controller polls |

(Exposure table and the two prose paragraphs: TODO)

## Section 14 review questions

TODO
