# DCC Kubernetes Project — FastAPI · Docker · Kubernetes

A small FastAPI website packaged in a Docker container and deployed on a local
3-node Kubernetes cluster (kind). It demonstrates the three features required
by the assignment, **visibly, live in the browser**:

| # | Requirement | How this project shows it |
|---|-------------|---------------------------|
| 1 | **Scalability** of Kubernetes Pods | Scale 3 → 6 pods with one command; the web page shows new pod names receiving traffic within seconds. Bonus: automatic scaling with an HPA. |
| 2 | **Self-healing** (recovery after pod deletion) | Delete a pod (or press the "Crash a pod" button in the UI) — Kubernetes replaces/restarts it automatically while the site stays up. |
| 3 | **Rolling update** of Pods | Update the image v1.0.0 → v2.0.0 with zero downtime; the page changes color from blue to green pod-by-pod. **Measured: 350 requests during the update, 0 failures.** |

The trick that makes everything visible: every response includes the **pod
name** and **app version**, and the web page polls the API every 0.7 s and
draws a live per-pod traffic chart. When you scale, kill, or update pods, the
audience watches it happen.

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Repository structure](#2-repository-structure)
3. [Kubernetes concepts you need for the presentation](#3-kubernetes-concepts-you-need-for-the-presentation)
4. [Prerequisites](#4-prerequisites)
5. [Step 1 — Run the app directly (no containers)](#5-step-1--run-the-app-directly-no-containers)
6. [Step 2 — Build and run with Docker](#6-step-2--build-and-run-with-docker)
7. [Step 3 — Create the Kubernetes cluster (kind)](#7-step-3--create-the-kubernetes-cluster-kind)
8. [Step 4 — Deploy the app to Kubernetes](#8-step-4--deploy-the-app-to-kubernetes)
9. [Demo 1 — Scalability](#9-demo-1--scalability)
10. [Demo 2 — Self-healing](#10-demo-2--self-healing)
11. [Demo 3 — Rolling update & rollback](#11-demo-3--rolling-update--rollback)
12. [Bonus demo — Autoscaling with HPA](#12-bonus-demo--autoscaling-with-hpa)
13. [Presentation script (run of show)](#13-presentation-script-run-of-show)
14. [Getting a public online link](#14-getting-a-public-online-link)
15. [Cleanup](#15-cleanup)
16. [Troubleshooting](#16-troubleshooting)
17. [kubectl cheat sheet](#17-kubectl-cheat-sheet)
18. [Q&A preparation — questions your professor may ask](#18-qa-preparation--questions-your-professor-may-ask)

---

## 1. Architecture

```
                         your Mac (browser)
                                │
                        http://localhost:8080
                                │  (kind maps host port 8080 → node port 30080)
┌───────────────────────────────▼──────────────────────────────────┐
│  kind cluster "dcc"  (each node = a Docker container)            │
│                                                                  │
│  ┌────────────────────┐   Service "dcc-web" (NodePort 30080)     │
│  │ dcc-control-plane  │   stable virtual IP, load-balances       │
│  │ api-server, etcd,  │   across all pods with label app=dcc-web │
│  │ scheduler, ...     │            │                             │
│  └────────────────────┘   ┌────────┴─────────┐                   │
│                           ▼                  ▼                   │
│  ┌────────────────────┐      ┌────────────────────┐              │
│  │ dcc-worker         │      │ dcc-worker2        │              │
│  │  ┌──────┐ ┌──────┐ │      │  ┌──────┐          │              │
│  │  │ pod  │ │ pod  │ │      │  │ pod  │   ...    │              │
│  │  │ dcc- │ │ dcc- │ │      │  │ dcc- │          │              │
│  │  │ web  │ │ web  │ │      │  │ web  │          │              │
│  │  └──────┘ └──────┘ │      │  └──────┘          │              │
│  └────────────────────┘      └────────────────────┘              │
│                                                                  │
│  Deployment "dcc-web" (replicas: 3) → ReplicaSet → Pods          │
└──────────────────────────────────────────────────────────────────┘
```

**The app** (FastAPI, Python 3.12):

| Endpoint | Purpose |
|----------|---------|
| `GET /` | Demo web page — polls `/api/info` every 0.7 s, shows which pod answered, live per-pod traffic bars, request log |
| `GET /api/info` | JSON: pod name, version, accent color, uptime, per-pod request counter |
| `GET /healthz` | Health check used by Kubernetes liveness & readiness probes |
| `GET /crash` | Kills the pod's process — self-healing demo |
| `GET /load?seconds=N` | Burns CPU for N seconds — autoscaling demo |

---

## 2. Repository structure

```
DCC/
├── app/
│   ├── main.py            # FastAPI application
│   ├── index.html         # live demo page (polls the API, draws charts)
│   └── requirements.txt   # fastapi + uvicorn, pinned versions
├── k8s/
│   ├── deployment.yaml    # Deployment: 3 replicas, probes, rolling-update strategy
│   ├── service.yaml       # Service: NodePort 30080 → container port 8000
│   └── hpa.yaml           # HorizontalPodAutoscaler (bonus)
├── Dockerfile             # container image definition
├── .dockerignore          # keeps the build context small
├── kind-config.yaml       # 3-node local cluster + port mapping 8080→30080
├── Makefile               # shortcuts (make build / cluster / deploy / ...)
└── README.md              # this file
```

Every YAML file is commented line-by-line — read them, the comments are the
study material for the Q&A session.

---

## 3. Kubernetes concepts you need for the presentation

Read this section once before the demo; it is everything the demos rely on.

**Container image vs container.** An *image* is a frozen, portable package of
your app + runtime + dependencies (built from the `Dockerfile`). A *container*
is a running instance of an image. Same relationship as class → object.

**Cluster & nodes.** A Kubernetes *cluster* is a set of machines (*nodes*)
managed as one unit. The *control-plane* node runs the brain of Kubernetes;
*worker* nodes run your application. With kind, each "node" is actually a
Docker container on your laptop — a real multi-node cluster without real
machines.

**Control plane components** (run on the control-plane node):
- **kube-apiserver** — the front door; every `kubectl` command talks to it.
- **etcd** — the database storing the entire desired state of the cluster.
- **kube-scheduler** — decides *which node* each new pod should run on.
- **controller-manager** — runs reconciliation loops that constantly compare
  *desired state* (what you declared) with *actual state* (what is running)
  and fix any difference. **This loop is what self-healing actually is.**

**On every node:** **kubelet** (starts/stops containers the scheduler assigns
to that node, runs the health probes) and **kube-proxy** (programs the
network rules that make Services load-balance).

**Pod.** The smallest deployable unit — one or more containers sharing an IP
and lifecycle. Usually one container per pod (as here). Pods are *ephemeral*:
they are never repaired, only replaced, and each replacement gets a new name
and IP. That is why you never point users at a pod directly.

**ReplicaSet.** "Keep exactly N copies of this pod running." Kill a pod and
the ReplicaSet immediately creates a replacement — self-healing.

**Deployment.** The object you actually work with. It manages ReplicaSets and
adds *versioned rollouts*: change the pod template (e.g. new image tag) and
the Deployment creates a **new** ReplicaSet, then gradually shifts pods from
old to new (rolling update). Rollback = shift back to the old ReplicaSet.

**Service.** Pods come and go with changing IPs, so a Service provides one
stable virtual IP + DNS name and load-balances across all pods matching its
label selector. Types: `ClusterIP` (internal only), `NodePort` (opens a port
on every node — what we use), `LoadBalancer` (cloud provider gives a public
IP).

**Labels & selectors.** Key/value tags on objects (`app: dcc-web`). The
Service and the Deployment find "their" pods purely by label match — this
loose coupling is core Kubernetes design.

**Probes.**
- *Readiness probe*: "may this pod receive traffic?" Failing pods are removed
  from the Service until they pass — this is what makes rolling updates
  zero-downtime.
- *Liveness probe*: "is this pod alive at all?" After repeated failures the
  container is killed and restarted — self-healing for hung processes.

**Declarative model — the single most important idea.** You never tell
Kubernetes *how* to do things. You declare a target state ("3 replicas of
image X") in YAML, apply it, and controllers work continuously to make
reality match. Scaling, self-healing and rolling updates are all just
consequences of this one idea.

---

## 4. Prerequisites

macOS with [Homebrew](https://brew.sh). Windows/Linux equivalents exist for
every tool.

```bash
# 1. Docker Desktop — runs containers (and the kind "nodes")
brew install --cask docker
open -a Docker        # wait until the whale icon says "running"

# 2. kubectl — the Kubernetes CLI
brew install kubectl

# 3. kind — runs a Kubernetes cluster inside Docker containers
brew install kind
```

Verify:

```bash
docker --version    # Docker version 29.x
kubectl version --client
kind version
```

### Why kind — and how it relates to kubeadm and Docker Desktop's Kubernetes

Three ways you could get a cluster, and why we picked kind:

| Tool | What it is | When to use |
|------|-----------|-------------|
| **kubeadm** | The official bootstrapper for **production** clusters. You run it on real Linux servers/VMs to initialize the control plane and join worker nodes. | Real datacenter/cloud VMs. Not practical on a laptop — you'd have to create and manage the VMs yourself. |
| **Docker Desktop's built-in Kubernetes** (Settings → Kubernetes → Enable) | A convenience **single-node** cluster. | Quick dev testing. Too limited for this assignment: with one node you cannot show pods spreading across nodes. **Leave this toggle OFF** — it would create a second cluster and confuse your kubectl context. |
| **kind** (what we use) | Runs each cluster *node* as a Docker container. You don't enable anything in Docker Desktop — kind is a separate CLI that just needs the Docker daemon running. | Local **multi-node** clusters. Fast, disposable, realistic. |

Two facts worth saying in the Q&A:
- **kind actually runs kubeadm internally** — inside each node container,
  kind bootstraps stock Kubernetes with kubeadm. So this project *is* a
  kubeadm-initialized cluster; the only difference from production is that
  nodes are containers instead of physical machines/VMs.
- **How many nodes?** We use **3: 1 control-plane + 2 workers** — the minimum
  that looks like production: the control plane stays dedicated to managing
  the cluster (like real clusters, it has a taint that keeps app pods off
  it), and *two* workers are needed to show pods spreading across nodes
  during the scaling demo. One node would work but every pod would land in
  the same place; more than 3 only burns laptop RAM (each node is a full
  container running kubelet + containerd) with no extra demo value.

> **minikube?** Also fine, same niche as kind. kind starts faster, needs no
> VM, and does multi-node trivially.

---

## 5. Step 1 — Run the app directly (no containers)

Optional, but it proves the app is just normal Python before any
containerization magic.

```bash
cd app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --port 8000
```

Open <http://localhost:8000> — the page works, but shows only **one**
"pod" (your machine's hostname). Stop it with `Ctrl+C`.

---

## 6. Step 2 — Build and run with Docker

### Build the image

```bash
# from the repository root
docker build -t dcc-web:1.0.0 --build-arg APP_VERSION=1.0.0 .
```

Flag by flag:
- `docker build` — execute the `Dockerfile` and produce an image.
- `-t dcc-web:1.0.0` — name (**t**ag) the image `dcc-web`, version `1.0.0`.
  Never use `:latest` for deployments — you can't roll back to "latest".
- `--build-arg APP_VERSION=1.0.0` — bakes the version into the image
  (the app reads it from the environment and shows it in the UI).
- `.` — the *build context*: which directory is sent to Docker.

Also build **v2.0.0** now — same code, different baked version. This is the
image we will roll out live during the presentation:

```bash
docker build -t dcc-web:2.0.0 --build-arg APP_VERSION=2.0.0 .
docker images | grep dcc-web
```

### Run one container (Docker only, no Kubernetes yet)

```bash
docker run --rm -d -p 8000:8000 --name dcc dcc-web:1.0.0
```

- `-d` — detached (background).
- `--rm` — delete the container when it stops.
- `-p 8000:8000` — publish: host port 8000 → container port 8000.
- `--name dcc` — a handle for `docker logs dcc`, `docker stop dcc`.

Open <http://localhost:8000>, then:

```bash
curl http://localhost:8000/api/info
docker logs dcc        # uvicorn access logs
docker stop dcc
```

**What Docker alone cannot do:** run several copies with load balancing,
restart on crash*, update without downtime. One `docker run` = one container
on one machine. That gap is exactly what Kubernetes fills.
(*`--restart=always` exists, but only on that single machine and with no
health checks, no load balancing, no rollouts.)

---

## 7. Step 3 — Create the Kubernetes cluster (kind)

[`kind-config.yaml`](kind-config.yaml) defines 1 control-plane + 2 workers,
and maps your Mac's port **8080** into the control-plane node's port
**30080** (where our Service will listen):

```bash
kind create cluster --name dcc --config kind-config.yaml
```

Takes ~1 minute. Verify:

```bash
kubectl cluster-info --context kind-dcc
kubectl get nodes
```

Expected:

```
NAME                STATUS   ROLES           AGE   VERSION
dcc-control-plane   Ready    control-plane   1m    v1.36.1
dcc-worker          Ready    <none>          1m    v1.36.1
dcc-worker2         Ready    <none>          1m    v1.36.1
```

Fun fact worth showing: `docker ps` now lists three containers — those *are*
your "nodes".

---

## 8. Step 4 — Deploy the app to Kubernetes

### 8.1 Load the images into the cluster

The cluster cannot see images that only exist in your local Docker — there is
no registry in between. `kind load` copies them onto every node:

```bash
kind load docker-image dcc-web:1.0.0 dcc-web:2.0.0 --name dcc
```

(That is also why the Deployment sets `imagePullPolicy: IfNotPresent` —
otherwise Kubernetes would try to pull `dcc-web` from Docker Hub and fail
with `ErrImagePull`.)

### 8.2 Apply the manifests

```bash
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
kubectl rollout status deployment/dcc-web
```

`kubectl apply` sends the desired state to the API server; the controllers do
the rest: Deployment → creates a ReplicaSet → creates 3 Pods → scheduler
assigns them to nodes → kubelets start the containers.

### 8.3 Verify

```bash
kubectl get deploy,rs,pods,svc -o wide
```

You should see the 3 pods spread across `dcc-worker` and `dcc-worker2`, and
the Service:

```
NAME             TYPE       CLUSTER-IP      PORT(S)        SELECTOR
service/dcc-web  NodePort   10.96.132.200   80:30080/TCP   app=dcc-web
```

**Open <http://localhost:8080>.** Within seconds the "Load balancing" chart
fills with all 3 pod names — one Service URL, three pods answering.

Command-line proof of load balancing:

```bash
for i in $(seq 1 12); do curl -s http://localhost:8080/api/info | grep -o '"pod":"[^"]*"'; done | sort | uniq -c
```

```
   2 "pod":"dcc-web-9fc94f7cd-6fj5b"
   6 "pod":"dcc-web-9fc94f7cd-mptp9"
   4 "pod":"dcc-web-9fc94f7cd-rblw4"
```

---

## 9. Demo 1 — Scalability

> **Setup for all demos:** Terminal A runs `kubectl get pods -w` (`-w` =
> watch, streams every pod change live). Terminal B is for commands. Keep the
> browser on <http://localhost:8080> visible.

Scale from 3 to 6 replicas — one command, no downtime, no config edits:

```bash
kubectl scale deployment dcc-web --replicas=6
```

What happens, in order:
1. The Deployment's desired replica count changes in etcd.
2. The ReplicaSet controller sees `actual (3) ≠ desired (6)` → creates 3 pods.
3. The scheduler places them on the least-loaded nodes.
4. As each pod passes its **readiness probe**, the Service starts sending it
   traffic — watch the new pod names appear in the browser chart within
   seconds.

```bash
kubectl get pods -o wide     # 6 pods, spread across both workers
```

Scale down — Kubernetes gracefully terminates the excess pods:

```bash
kubectl scale deployment dcc-web --replicas=2
```

The browser keeps working throughout: traffic is simply redistributed to the
survivors. Reset for the next demo:

```bash
kubectl scale deployment dcc-web --replicas=3
```

**The message of this demo:** capacity is a *number in a declaration*, not a
provisioning project. (Note: `kubectl scale` changes desired state at
runtime; the permanent way is editing `replicas:` in `deployment.yaml` and
re-applying.)

---

## 10. Demo 2 — Self-healing

### 10.1 Kill a pod — Kubernetes replaces it

```bash
kubectl get pods                      # pick any pod name
kubectl delete pod <POD-NAME>
```

Watch Terminal A: **while** the old pod is still `Terminating`, a brand-new
pod is already `ContainerCreating`. Typical replacement time: 2–4 seconds.

```
dcc-web-9fc94f7cd-6fj5b   1/1   Terminating
dcc-web-9fc94f7cd-jqwkw   0/1   ContainerCreating
dcc-web-9fc94f7cd-jqwkw   1/1   Running
```

Nobody restarted anything manually. The ReplicaSet controller saw
`actual (2) ≠ desired (3)` and reconciled. To Kubernetes, a pod deleted by an
admin, killed by a crash, or lost with a dead node are all the same
situation: actual ≠ desired → fix it.

Kill all three at once if you want drama — the site degrades for a moment,
then fully recovers:

```bash
kubectl delete pods -l app=dcc-web
```

### 10.2 Crash the app from inside — Kubernetes restarts the container

Click **"Crash a pod"** on the web page (or `curl http://localhost:8080/crash`).
The pod's process exits with a non-zero code, and the kubelet restarts the
container *in place* (same pod name, `RESTARTS` counter +1):

```bash
kubectl get pods
NAME                      READY   STATUS    RESTARTS      AGE
dcc-web-9fc94f7cd-mptp9   1/1     Running   1 (6s ago)    5m
```

Two different healing mechanisms, both automatic:

| Failure | Healed by | Evidence |
|---------|-----------|----------|
| Pod deleted | ReplicaSet controller creates a **new pod** | new name in pod list |
| Process crashes | kubelet **restarts the container** | `RESTARTS` +1 |
| Process hangs (no crash) | **liveness probe** fails → kubelet restarts it | `RESTARTS` +1 |

---

## 11. Demo 3 — Rolling update & rollback

We deployed `dcc-web:1.0.0` (blue UI). Now upgrade to `2.0.0` (green UI)
**with zero downtime**:

```bash
kubectl set image deployment/dcc-web web=dcc-web:2.0.0
kubectl rollout status deployment/dcc-web
```

(`web` is the container's name inside the pod template.)

Because the strategy is `maxSurge: 1, maxUnavailable: 0`, the Deployment
replaces pods **one at a time**, and only after the new pod passes its
readiness probe does an old one get terminated:

```
Waiting for deployment "dcc-web" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "dcc-web" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "dcc-web" successfully rolled out
```

**Watch the browser during the rollout:** responses alternate between
v1.0.0/blue and v2.0.0/green pods, then turn fully green. The site never goes
down.

Proof it is truly zero-downtime — hammer the service during an update and
count failures (measured on this exact setup):

```bash
while true; do curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 \
  http://localhost:8080/api/info; sleep 0.1; done
# result during a full rollout: 350 requests, 350 × HTTP 200, 0 failures
```

Under the hood there is no "image swap": the Deployment created a **second
ReplicaSet** for v2 and walked the counts (v1: 3→2→1→0, v2: 0→1→2→3). The old
ReplicaSet is kept at 0 — it *is* the rollback plan:

```bash
kubectl get rs                              # both ReplicaSets, old one at 0
kubectl rollout history deployment/dcc-web  # revision list
```

### Rollback

Bad release? One command, same zero-downtime mechanics in reverse:

```bash
kubectl rollout undo deployment/dcc-web
kubectl rollout status deployment/dcc-web
```

The browser turns blue again. (`--to-revision=N` picks a specific revision.)

> **Zero-downtime detail worth mentioning in the Q&A:** new pods receive
> traffic only after passing the readiness probe, and terminating pods get a
> 5-second `preStop` sleep (see `deployment.yaml`) so every node's routing
> rules update before the old process receives SIGTERM. Without the preStop
> hook a handful of requests can hit a dying pod — we measured exactly that,
> added the hook, and re-measured 0 failures.

---

## 12. Bonus demo — Autoscaling with HPA

Manual scaling is you deciding N. A **HorizontalPodAutoscaler** measures load
and decides N for you.

### 12.1 Install metrics-server (the HPA's eyes)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# kind's kubelets use self-signed certificates; tell metrics-server to accept them
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl rollout status deployment/metrics-server -n kube-system
sleep 30 && kubectl top pods    # per-pod CPU/memory now visible
```

### 12.2 Apply the HPA and generate load

```bash
kubectl apply -f k8s/hpa.yaml
kubectl get hpa dcc-web -w      # leave watching
```

Click **"Generate CPU load"** on the web page, or:

```bash
for i in $(seq 1 10); do curl -s "http://localhost:8080/load?seconds=25" > /dev/null & done
```

Within ~30–60 s (measured on this setup):

```
NAME      REFERENCE            TARGETS         MINPODS   MAXPODS   REPLICAS
dcc-web   Deployment/dcc-web   cpu: 6%/50%     2         10        3        ← idle
dcc-web   Deployment/dcc-web   cpu: 334%/50%   2         10        8        ← under load
```

The HPA compares actual CPU against each pod's `resources.requests.cpu` and
scales the Deployment: 3 → 8 pods automatically. When the load stops, it
scales back down to `minReplicas` after a 60 s stabilization window.

> **Warning: delete the HPA before doing the *manual* scaling demo** — the HPA
> continuously enforces its own replica count and will silently override your
> `kubectl scale`:
>
> ```bash
> kubectl delete hpa dcc-web
> ```

---

## 13. Presentation script (run of show)

Total ≈ 7 minutes. Prepare **before** the call:

```bash
# 0. One-time prep (do this before the presentation!)
docker build -t dcc-web:1.0.0 --build-arg APP_VERSION=1.0.0 .
docker build -t dcc-web:2.0.0 --build-arg APP_VERSION=2.0.0 .
kind create cluster --name dcc --config kind-config.yaml
kind load docker-image dcc-web:1.0.0 dcc-web:2.0.0 --name dcc
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
kubectl rollout status deployment/dcc-web
open http://localhost:8080
```

Screen layout: browser left, two terminals right.
Terminal A: `kubectl get pods -w` · Terminal B: your commands.

| Min | Say | Do (Terminal B) |
|-----|-----|-----------------|
| 0–1 | "FastAPI app in Docker, on a 3-node Kubernetes cluster. Every response shows which pod served it — one URL, three pods, load-balanced by a Service." | point at the browser's per-pod chart |
| 1–2 | "**Scalability**: I declare 6 replicas; Kubernetes creates the pods and the Service adds them to rotation automatically." | `kubectl scale deployment dcc-web --replicas=6` → new names appear in browser |
| 2–3 | "Scaling down is just as easy — traffic redistributes, no downtime." | `kubectl scale deployment dcc-web --replicas=3` |
| 3–4 | "**Self-healing**: I delete a pod. Kubernetes notices 2 ≠ 3 and replaces it in seconds. Nobody restarts anything by hand." | `kubectl delete pod <name>` → watch Terminal A |
| 4–5 | "It also heals crashes: this button kills the process inside a pod — the restart counter goes up, the site stays up." | click "Crash a pod" in the browser, then `kubectl get pods` |
| 5–6 | "**Rolling update** to v2: pods are replaced one by one; new ones take traffic only after passing health checks. Watch the page turn green — zero requests dropped." | `kubectl set image deployment/dcc-web web=dcc-web:2.0.0` |
| 6–7 | "A bad release is one command to undo — same mechanism in reverse." | `kubectl rollout undo deployment/dcc-web` → page turns blue |

If time allows, finish with the HPA demo (section 12) — it always impresses.

---

## 14. Getting a public online link

The assignment asks for an *online link*. Two options:

### Option A — Tunnel to your laptop (5 minutes, free, recommended)

A tunnel gives your local cluster a public HTTPS URL. Keep your laptop
running during the presentation.

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:8080
# → prints e.g. https://random-words-1234.trycloudflare.com  ← your online link
```

(Alternative: `ngrok http 8080` — requires a free account.)

### Option B — Real cloud Kubernetes

The **same manifests** work on any managed Kubernetes (DigitalOcean, GKE,
EKS, AKS) — that portability is itself a Kubernetes selling point. Steps:
push the images to a registry (`docker push <youruser>/dcc-web:1.0.0` after
`docker login`), update `image:` in `deployment.yaml` to the registry path,
change the Service type to `LoadBalancer`, and `kubectl apply` with your
cloud kubeconfig. The cloud assigns a public IP to the Service.

---

## 15. Cleanup

```bash
kind delete cluster --name dcc     # removes the whole cluster (3 containers)
docker rmi dcc-web:1.0.0 dcc-web:2.0.0
```

---

## 16. Troubleshooting

| Symptom | Cause → Fix |
|---------|-------------|
| `ErrImagePull` / `ImagePullBackOff` | The cluster can't find the image — you forgot `kind load docker-image ... --name dcc`, or `imagePullPolicy` isn't `IfNotPresent`. |
| `localhost:8080` refuses connection | Cluster created **without** `--config kind-config.yaml` (no port mapping). Recreate it: `kind delete cluster --name dcc && kind create cluster --name dcc --config kind-config.yaml`. |
| Pods stuck `Pending` | `kubectl describe pod <name>` → look at Events. Usually not enough CPU/memory — give Docker Desktop more resources (Settings → Resources). |
| `kubectl` talks to the wrong cluster | `kubectl config use-context kind-dcc` |
| HPA shows `<unknown>` targets | metrics-server missing or not patched (section 12.1); wait 30–60 s after install. |
| Manual scaling "doesn't stick" | An active HPA overrides it — `kubectl delete hpa dcc-web`. |
| Docker daemon not running | `open -a Docker` and wait for the whale. |
| Port 8080 already in use | Change `hostPort` in `kind-config.yaml`, recreate the cluster. |

Debugging anything: `kubectl describe pod <name>` (events at the bottom) and
`kubectl logs <name>` are the first two commands to run, always.

---

## 17. kubectl cheat sheet

```bash
# inspect
kubectl get pods -o wide                 # pods + which node they run on
kubectl get deploy,rs,pods,svc           # everything at once
kubectl get pods -w                      # live watch (Ctrl+C to stop)
kubectl describe pod <name>              # full detail + event log
kubectl logs <name>                      # container stdout
kubectl logs -f deployment/dcc-web       # follow logs of the whole app

# the three demos
kubectl scale deployment dcc-web --replicas=6        # scalability
kubectl delete pod <name>                            # self-healing
kubectl set image deployment/dcc-web web=dcc-web:2.0.0   # rolling update
kubectl rollout status deployment/dcc-web            # watch the rollout
kubectl rollout history deployment/dcc-web           # list revisions
kubectl rollout undo deployment/dcc-web              # rollback

# exec into a pod / quick port access
kubectl exec -it <pod> -- sh
kubectl port-forward svc/dcc-web 9000:80             # alternative to NodePort

# via the Makefile
make build cluster load deploy      # full setup
make status / scale-up / update / rollback / clean
```

---

## 18. Q&A preparation — questions your professor may ask

**Q: What is the difference between Docker and Kubernetes?**
Docker builds and runs single containers on one machine. Kubernetes
*orchestrates* many containers across many machines: replication, load
balancing, self-healing, rolling updates, autoscaling. Docker is the engine;
Kubernetes is the fleet management.

**Q: What is a pod, and why not just say "container"?**
A pod is the smallest schedulable unit: one or more containers that share an
IP, ports, and lifecycle. Kubernetes schedules, heals, and scales pods, not
raw containers. Most pods (like ours) hold exactly one container.

**Q: How does self-healing actually work?**
Reconciliation. Desired state lives in etcd ("3 replicas"). The ReplicaSet
controller loops forever comparing desired vs actual; any gap — deleted pod,
crashed pod, dead node — is corrected by creating/removing pods. The kubelet
additionally restarts containers that exit or fail their liveness probe.

**Q: Why does the Service exist? Why not connect to pods directly?**
Pods are ephemeral — every replacement has a new IP. The Service is a stable
virtual IP/DNS name that load-balances across whatever pods currently match
its label selector. Clients never need to know which or how many pods exist.

**Q: How does the rolling update achieve zero downtime?**
`maxUnavailable: 0` guarantees full capacity at all times; `maxSurge: 1`
creates one new pod at a time; the readiness probe gates traffic so a new pod
serves only when actually ready; a `preStop` delay lets routing rules drain
before an old pod's process is stopped. We verified: 350 requests during a
rollout, 0 failures.

**Q: What happens on rollback?**
Nothing special — the old ReplicaSet (kept at 0 replicas) is scaled back up
and the new one down, with the same zero-downtime choreography. Every rollout
is versioned (`kubectl rollout history`).

**Q: Difference between readiness and liveness probes?**
Readiness = "can I take traffic *right now*?" — failing removes the pod from
the Service, no restart. Liveness = "am I alive at all?" — failing repeatedly
gets the container restarted. Ours both hit `GET /healthz`.

**Q: Manual scaling vs HPA?**
`kubectl scale` sets a fixed replica count. The HPA adjusts the count
automatically to hold a target metric (here: 50% average CPU of each pod's
request, between 2 and 10 replicas), using metrics-server data.

**Q: What are resource requests vs limits?**
Requests are reserved capacity used by the scheduler for placement (and by
the HPA as the 100% baseline); limits are a hard cap enforced at runtime.
Ours: request 50m CPU / 64Mi, limit 250m / 128Mi.

**Q: Is your app running on Docker or on Kubernetes? Prove it.**
Only on Kubernetes. `docker ps` on the host shows exactly three containers —
the cluster *nodes* (`kindest/node` images) — and zero `dcc-web` containers:
Docker never runs the app directly. The app containers live *inside* the
nodes, created and managed by Kubernetes' kubelet through **containerd** (not
through Docker at all): `docker exec dcc-worker crictl ps` lists them. Docker
on the host has only two jobs here: it built the image, and it hosts the node
containers. Start/stop/restart/scale of the app is 100% Kubernetes.

**Q: Is your kind cluster "real" Kubernetes?**
Yes — stock upstream Kubernetes (v1.36); only the nodes are Docker containers
instead of VMs. The manifests deploy unchanged to any cloud provider.

**Q: Where does the app's state live? What if a pod dies mid-request?**
The app is stateless — each pod only keeps a cosmetic request counter in
memory, lost on restart by design. That statelessness is what makes free
scaling/healing possible; real state belongs in a database, in Kubernetes
terms a StatefulSet + PersistentVolume.
