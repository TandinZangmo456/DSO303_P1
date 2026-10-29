# Lab 07 Notes - EKS and the USMS microservices

## Lab 07 support path
Probed on 2026-10-28T17:23:38Z
PATH A - use aws eks throughout

The eks API answered and kubectl was installed, so I used aws eks for the AWS half. k3d was missing, which is fine on Path A.

## Step 3 - Is EKS just ECS with different names?

It is not, because on EKS I run the data plane myself. The nodes are EC2 instances in my account that I have to patch, and there are two separate IAM roles, a cluster role for the control plane and a node role for the instances. On ECS with Fargate that whole side is handled by AWS.

It is nearly true because both do the same basic job. They keep N copies of a container running, give them a stable way to be reached, and replace them during a rolling update. A task definition and a pod template are doing similar work.

## Step 9 - Version and OIDC issuer

The command printed `1.30  None`.

The OIDC issuer is the URL that IAM trusts so that a pod's service account token can be swapped for temporary AWS role credentials. This is what IRSA is built on. My build has no issuer, so IRSA could not be completed here (see Step 21).

One thing I noticed: describe-cluster says version 1.30, but `kubectl get nodes` showed the node actually running v1.34.1+k3s1. Floci records the version I asked for but runs whatever k3s image it pulled.

## Things Floci did differently (observed during the lab)

- `aws eks create-cluster` timed out at the CLI's default 60 second read timeout the first time. Floci's log showed it was still downloading the rancher/k3s image, which took over 10 minutes with two retries. I added `--cli-read-timeout 600` after that.
- After that timeout the cluster ended up half created: list-clusters was empty but create-cluster said it already existed. It became ACTIVE later on its own.
- `aws iam list-entities-for-policy` returned UnsupportedOperation. I listed the holders of USMSStudentDataReadWrite by looping over every role and checking its attached policies instead.
- The assumed role session showed `floci-session` instead of the session name `lab07-eks-build` I passed.
- describe-cluster returned an empty Vpc field even though all four subnets came from usms-vpc. The subnets and security group were stored correctly.
- The endpoint was `https://localhost:6501` the first time and `https://localhost:6500` after recreating, not 6443 like the lab example.
- The node group said desired 2, but only one node (the k3s server) existed. t3.small and the AMI type are stored but nothing is provisioned. Pods still scheduled on the single node.
- `kubectl set env --from=secret/...` added each key as its own env entry with secretKeyRef instead of an envFrom.secretRef. The variables still reached the pod.
- My DSO202 kind clusters were running at the same time and holding ports 80 and 443 plus a lot of RAM. I stopped them before recreating the cluster.

## Step 16 - Service discovery and the replacement pod

- nslookup from inside a busybox pod returned the Service ClusterIPs (for example usms-enrolment resolved to 10.43.235.192, which matched `kubectl get svc`), not pod IPs. CoreDNS was at 10.43.0.10.
- 12 requests through the gateway were answered by two different enrolment pods (5 and 7 after the rebuild).
- I deleted pod usms-enrolment-575945b968-7s89l. A new pod, usms-enrolment-575945b968-862zk, was running within 2 seconds and showed up in the next tally. No request failed.
- The replacement was created by the ReplicaSet usms-enrolment-575945b968. The event was SuccessfulCreate from replicaset/usms-enrolment-575945b968. The Deployment only manages ReplicaSets, and the ReplicaSet is what keeps the pod count at 2.

## Step 17 - Secret

- I generated the Secret manifest into outputs/lab-07-secret.yaml instead of manifests/, so it is git-ignored. `git check-ignore -v` named the rule `.gitignore:7:outputs/*`.
- `kubectl get secret ... -o jsonpath` gave the base64 string, and piping it to `base64 -d` gave back `floci-dummy-token-not-a-real-secret`. No key or extra permission was needed.
- Inside the container, printenv showed the token and password in plain text.

## Step 18 - Rollout and rollback

- Changing APP_VERSION to 1.1.0 in the ConfigMap did not change the running pods. They still said 1.0.0 because env vars are only read when a container starts.
- After `kubectl rollout restart` the pods said 1.1.0, and the ReplicaSet hash in the pod name changed (7d8557c58d to 6476c9d87).
- History showed 3 revisions. Only the newest ReplicaSet had DESIRED 2, and the older ones were kept at 0.
- After `kubectl rollout undo` the pods still said 1.1.0. Undo reverted the pod template, not the ConfigMap, because the ConfigMap is a separate object that the Deployment does not version.
- I restored the ConfigMap to 1.0.0 and restarted again.

Your turn on usms-results:
- I changed the image to nginx:1.27 and rolled it back. `kubectl rollout history` showed 2 revisions afterwards (numbered 4 and 5), and the image was back on nginx:1.27-alpine.
- With 2 replicas, the default 25% works out to maxUnavailable 0 (0.5 rounds down) and maxSurge 1 (0.5 rounds up). So in practice it rolled the same way as enrolment: one extra pod was added first, then one old pod was removed, so the peak was 3 pods. The rollout status messages matched this ("1 out of 2 new replicas updated", then "1 old replicas pending termination"). The difference from enrolment would only show with 4 or more replicas.

## Step 19 - Failures

- ImagePullBackOff: the new usms-results pod went to ErrImagePull and then ImagePullBackOff while both old pods kept Running. The event message was actually a network error (lookup auth.docker.io failed, then a TLS handshake timeout) rather than "tag not found", but either way the pull failed and the broken image never replaced the working pods.
- Pending / FailedScheduling: usms-toobig asked for 64 CPU and 256Gi. describe showed `0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory`.
- CrashLoopBackOff: usms-crasher printed its two lines and exited 1. describe showed Last State Terminated, Exit Code 1, and the restart count kept going up (7 by the time I deleted it). `kubectl logs --previous` sometimes said it could not retrieve the logs once k3s had cleaned up the old container.
- For the first two the answer was in describe Events because the container never ran. For the crash the container did run, so logs was the useful command.

## Step 20 - ECS and Kubernetes, compared with both running

ECS showed usms-enrolment-svc with desired 2, running 2, status ACTIVE, task definition usms-enrolment:2. EKS showed three Deployments (2/2, 1/1, 2/2) and three ClusterIP Services with no external IP.

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | The task definition (usms-enrolment:2) | The pod template inside the Deployment |
| What keeps N copies alive? | The ECS service and its desiredCount | The ReplicaSet the Deployment creates |
| What gives it a stable name? | The ALB DNS name in front of the service | The Service, with a fixed ClusterIP and a DNS name |
| How does another service find it? | Through the ALB (or Service Connect / Cloud Map) | CoreDNS, for example usms-enrolment.usms.svc.cluster.local |
| What does a rolling update create? | A new ECS deployment using a new task definition revision | A new ReplicaSet |
| Where does rollback state live? | Old task definition revisions, and you point the service back at one | Old ReplicaSets kept at 0, up to revisionHistoryLimit, used by rollout undo |
| Which IAM role does the app code use? | The task role, usms-ecs-task-role | Here the node role, usms-eks-node-role. On real EKS it would be an IRSA role per service account |
| What would I have to change to move to another cloud? | Nearly everything: task definitions, ALB, IAM and the service are all AWS objects | The manifests mostly move as they are. IAM roles, the VPC, the node group and any load balancer annotations do not |

For USMS I would choose ECS with Fargate. The team is small and the system is quiet most of the year, and ECS gave the same result in Lab 04 with fewer moving parts and no nodes to look after.

## Step 21 - IRSA

The OIDC issuer was None, so the script printed that IRSA is conceptual on this build. Of the six IRSA steps:
1. Cluster publishes an OIDC document: not possible, no issuer.
2. Register it as an IAM OIDC provider: not possible. list-open-id-connect-providers returned nothing.
3. Write a role trusting that provider: not useful without a provider.
4. Service account for the workload: done, usms-enrolment-sa created from manifests/lab-07/60-serviceaccount.yaml, but there was no role ARN to annotate it with.
5. Webhook injects the token: not available.
6. SDK calls AssumeRoleWithWebIdentity: not available.

So I did not configure IRSA. I wrote the ServiceAccount, traced the trust chain and recorded that my build publishes no issuer. The node role is what actually gives pods AWS permissions here, which means every pod on the node gets the same access.

## Step 22 - Restart test

PERSISTENCE NOT PROVEN for the Kubernetes half.

- Before the restart: cluster ACTIVE, node group ACTIVE desired 2, Deployments 2/1/2, three ClusterIPs.
- After floci-down and floci-up: the cluster was re-derived from list-clusters and was still ACTIVE, and the node group was re-derived from list-nodegroups. So the AWS records survived in hybrid storage mode.
- The Kubernetes section came back empty. There was no namespace, no Deployments and no ConfigMaps, and docker ps showed no eks container. Floci stops and removes the k3s container on shutdown and does not start it again on startup, even though it reloads the cluster record from /app/data/eks-clusters.json.
- The node group line in the diff was not a real loss. The after-script only runs list-nodegroups, not describe-nodegroup, so that line just was not printed.

Recovery: I deleted and recreated the node group and cluster from the same templates, ran update-kubeconfig, then `kubectl apply -f manifests/lab-07/` recreated the namespace, all ConfigMaps, the three Deployments and Services, and the ServiceAccount in one command. I re-applied the Secret from outputs/ and re-ran set env. After that verify-lab-07.sh gave PASS=30 FAIL=0 and the smoke test passed. This showed why keeping everything as declarative manifests in Git matters.

The first time I had stopped Floci on the first night, the same thing happened, which is why kubectl got connection refused on port 6501 the next day.

## Step 23 and Section 8

- configs/lab-07.env has 21 exports and no empty values. lb_ports is 8081,8082.
- verify-lab-07.sh: PASS=30 FAIL=0 on Path A, both before and after the rebuild.
- Smoke test passed: gateway, enrolment and results each returned JSON.
- Cleanup script written and syntax checked with bash -n. Not run.

## Exercise 5 Part 3 - What Lab 08 needs from configs/lab-07.env

- USMS_EKS_CLUSTER: every aws eks call in Lab 08 needs the cluster name, and update-kubeconfig needs it too.
- USMS_EKS_NODEGROUP: Lab 08 Step 10 changes the node group's scaling config from the AWS side.
- USMS_EKS_NAMESPACE: all Lab 08 work happens inside usms, so every kubectl call uses it.
- USMS_EKS_LB_PORTS: Lab 08 Step 15 needs these host ports to expose a LoadBalancer Service. Without the tag the cluster has to be recreated.
- USMS_EKS_ENDPOINT: to check kubectl is talking to the right cluster after a restart. Mine changed from 6501 to 6500 when the cluster was recreated, so this matters.
- USMS_K8S_DEPLOY_ENROLMENT: the HorizontalPodAutoscaler targets this Deployment.
- USMS_K8S_DEPLOY_GATEWAY: this is the Deployment whose Service becomes a NodePort, then a LoadBalancer and an Ingress.
- USMS_K8S_SVC_GATEWAY: the Service that actually gets changed to NodePort and LoadBalancer.
- USMS_K8S_CPU_REQUEST: 50m, to check the HPA's percentage maths by hand. My baseline was 1m per pod, which is 2%.
- USMS_K8S_MANIFEST_DIR: if the cluster is lost again on a restart, this is what gets re-applied.

The role ARNs, policy ARNs and security group ID are more for reference and for Lab 09's IAM review than for Lab 08 itself.

## Section 14 - Review questions

### 1. ACTIVE cluster but every pod is Pending

ACTIVE only describes the control plane, which is the part AWS runs: the API server, etcd and the scheduler. Pending means the scheduler accepted the pod but could not find a node to put it on, and nodes belong to the data plane, which I supply. So both can be true at once. The control plane is healthy, but there is no usable capacity under it.

Two setups that cause this:
- No node group at all, or a node group whose instances never register. For example, the node role is missing eks:DescribeCluster, or its trust policy names eks.amazonaws.com instead of ec2.amazonaws.com, so the kubelet never joins.
- Nodes exist but none can take the pod. The requests are bigger than any node (like usms-toobig in Step 19), the nodes have a taint the pod does not tolerate, or a nodeSelector matches no node label.

I saw a related version of this in the lab. Floci reported the cluster ACTIVE while the k3s container was gone, so the AWS record and the real cluster disagreed.

### 2. Swapping the two trust policies

If the cluster role trusted ec2.amazonaws.com, the EKS control plane could not assume it. On real AWS, create-cluster in Step 8 would fail straight away, because EKS checks that it can assume the role you pass in roleArn.

If the node role trusted eks.amazonaws.com, the EC2 instances could not get credentials from their instance profile. create-nodegroup in Step 10 might be rejected, or the instances would start but the kubelet could not call eks:DescribeCluster. The node group would sit in CREATING or go DEGRADED, and in Step 11 `kubectl get nodes` would show no worker nodes.

On Floci neither would be noticed, because trust policies are stored but not evaluated. Only the verify script's trust checks would catch it.

### 3. Readiness probe versus liveness probe

A readiness probe decides whether the pod is in the Service's endpoint list. If it fails, the pod stops getting traffic but keeps running. A liveness probe decides whether the container should be restarted. If it fails, the kubelet kills the container.

Getting them backwards causes real problems. If a check that is sensitive to load, like a slow database query, is used as the liveness probe, then under heavy load the probe times out, the kubelet restarts the container, the remaining pods get even more load, and they get restarted too. One busy period turns into a restart loop. That check should be a readiness probe, so a slow pod just gets taken out of rotation until it recovers.

Exercise 3 showed the readiness side. The probe pointed at /healthz, which plain nginx does not serve, so both pods stayed 0/1 and the Service had no endpoints even though the containers were running fine.

### 4. Why the pod still said 1.1.0 after rollback

`kubectl rollout undo` scales an older ReplicaSet back up, which brings back an older pod template. The pod template only references the ConfigMap by name. The ConfigMap's contents are a separate object, and the Deployment does not keep a history of them. So the old pod template came back, read the same ConfigMap, and still got 1.1.0.

I would say Kubernetes rollback is a real rollback of the workload spec, but not a rollback of the whole release. If a release changes the image, a ConfigMap and a Secret, undo only brings back the image and template.

The practice that fixes this is versioning configuration together with the workload. You can make ConfigMaps immutable with the version in the name (usms-app-config-v2), so changing config means changing the pod template, and undo then goes back to the old ConfigMap too. Tools like Kustomize's configMapGenerator do this automatically by adding a hash to the name. Another option is keeping everything in Git and rolling back by reverting the commit and re-applying.

### 5. maxUnavailable 0 versus the default

usms-enrolment uses maxUnavailable 0 and maxSurge 1. During an update it always keeps 2 ready pods and adds one extra pod first, so it needs room for a third pod. usms-results uses the default 25% / 25%. With 2 replicas, 25% of 2 is 0.5. maxUnavailable rounds down to 0 and maxSurge rounds up to 1, so for two replicas it behaves the same, which matched what I saw in Step 18. The difference shows with more replicas. With 4 replicas the default allows 1 pod down and 1 extra at the same time, which is faster but runs below full capacity for a while.

maxUnavailable 0 suits something like enrolment during the registration window, where losing any capacity means students get errors. The default suits something like results outside exam time, or a cluster that has no spare room for an extra pod, where a short dip in capacity is acceptable.

maxUnavailable 0 is closer to Lab 04's ECS setting of minimumHealthyPercent 100, which also never drops below the desired count during a deployment.

### 6. "A Secret is encrypted, so it is fine to commit the manifest"

That is not right. A Kubernetes Secret is base64 encoded, and base64 is just an encoding. In Step 17 I decoded the token with `base64 -d` with no key at all.

What a Secret does give you: the value is kept out of the image and out of the Deployment spec, it is a separate object so RBAC can limit who reads it, and kubectl describe does not print it.

What it does not give you: it is not encrypted in etcd unless encryption at rest is turned on, anyone with get on secrets can read it, and inside the pod it is plain text (printenv showed it). A committed manifest puts the value into Git history for good, even if the file is deleted later.

On real EKS I would turn on KMS envelope encryption for Secrets when creating the cluster, and keep Secret manifests out of Git. I would keep the real values in AWS Secrets Manager and pull them in with something like the Secrets Store CSI driver or External Secrets. For AWS access, I would use IRSA or EKS Pod Identity so there are no stored AWS keys at all. In this lab I generated the Secret into outputs/, which is git-ignored, and checked it with git check-ignore.

### 7. ECS or Kubernetes for USMS

I would choose ECS with Fargate. USMS has a small team, one region, and a pattern of eight quiet months and two very busy ones. With Fargate there are no nodes to patch or size, it can scale down to very little in the quiet months, and scaling up for registration was already working in Lab 06 with Application Auto Scaling.

Things this lab made harder than Lab 04:
- Two IAM roles plus a node group to set up, compared to one task role in Lab 04.
- A separate access path (kubeconfig and the API server on its own port) on top of the AWS CLI.
- A lot more YAML to write and get the indentation right.
- On Floci, the cluster did not survive a restart, and IRSA was not available, so pods share the node role's permissions.

What Kubernetes gave me that ECS could not: the whole application came back from `kubectl apply -f manifests/lab-07/` with one command, and those same manifests would work on any conformant cluster. Service discovery by DNS name was built in, and rollout history with undo and PodDisruptionBudgets were there without extra AWS services.

For a bigger team running many services, or one that needs to move between clouds, Kubernetes would be worth it. For USMS it is more to run than the problem needs.