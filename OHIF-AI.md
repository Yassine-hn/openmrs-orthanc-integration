# OHIF-AI — adding an AI imaging viewer alongside the existing one

**Project:** openmrs-orthanc-integration — Neurosurgery EMR, CHU Blida
**Upstream:** [CCI-Bonn/OHIF-AI](https://github.com/CCI-Bonn/OHIF-AI) (Apache 2.0)
**Status:** **PLANNING / NOT DEPLOYED.** Nothing in this document has been built or run yet.
Section 4 (hardware survey) is *measured*; everything else is *designed*.
**Applies to:** OHIF-AI `main` as of 2026-09-17, MONAI Label fork, OHIF `3.10.4`

> **Read the status line above before acting on anything here.** This project's
> convention is that a claim is not true until it has been demonstrated. Sections marked
> **PLANNED** have not been. They will be marked **VERIFIED** with a date as each is proven.

---

## 1. What this adds — and what it does not change

OHIF-AI is an OHIF viewer with two AI features built in:

- **interactive segmentation** — click, scribble or type a prompt, get a 3D mask
  (nnInteractive, SAM2, MedSAM2, SAM3, VoxTell);
- **report generation** — a vision-language model reads the volume and drafts a report.

We are **adding it as a second, independent viewer**, not replacing the current one.

| | Current viewer | New AI viewer |
| --- | --- | --- |
| URL | `https://viewer.hospital.lan` | `https://ai-viewer.hospital.lan` |
| Image | `ohif/app:v3.9.2` (prebuilt) | built from the OHIF-AI fork (OHIF 3.10.4) |
| Runs on | Server 1 (`10.0.211.249`) | Server 2 (`10.0.211.250`) |
| Needs a GPU | no | **yes** |
| Purpose | routine reading, MPR, volume rendering | segmentation, volumetry, draft reports |
| Changed by this work | **nothing at all** | — |

**Nothing about the existing viewer changes.** Same image, same `ohif-app-config.js`,
same NPM proxy host, same Orthanc, same auth injection. The OpenMRS imaging module's
`imaging.ohifBaseUrl` global property still points at `viewer.hospital.lan`.

### 1.1 Why side by side rather than replacing

The AI features live in a compiled-in OHIF extension (`Viewers/extensions/monai-label`),
not a runtime plugin. Using them means running a **source fork of OHIF**. Making that
fork the hospital's only viewer would mean every future OHIF upgrade becomes a merge
against someone else's tree — on the tool radiologists use every day.

Keeping it separate means:

- routine reading can never be broken by an AI experiment;
- the AI viewer can be stopped, rebuilt or abandoned with no clinical impact;
- both viewers read the **same** Orthanc, so a segmentation saved from one is visible
  from the other;
- the fork can lag or lead upstream OHIF without anyone caring.

The cost is two viewers to explain to users, and two frontends to keep alive. That is a
much smaller cost than a forked production viewer.

---

## 2. What OHIF-AI actually is

Two halves that can be adopted independently:

| Half | Directory | What it is | Port |
| --- | --- | --- | --- |
| Frontend | `Viewers/` | fork of OHIF **3.10.4** plus `extensions/monai-label` | 1026 (HTTP), 1025 (TLS) |
| Backend | `monai-label/` | fork of the MONAI Label server; models + report generation | 8002 |

Upstream's `docker-compose.yml` also starts **its own Orthanc**
(`jodogne/orthanc-plugins`, container `PACS`, ports 4242/8042). We use it during
evaluation and drop it afterwards — see §6.

### 2.1 How the backend exposes models

The backend is an ordinary MONAI Label application. Models are `TaskConfig` classes in
`monai-label/sample-apps/radiology/lib/configs/`, selected at launch:

```
--conf models nninteractive,sam2,medsam2,voxtell
```

`nnInteractive` additionally implements a **session-lease** protocol for multi-user
safety: a client `POST`s to `/monai/nninter/session/` for a lease token and sends that
token with every subsequent prompt. A GPU lock serialises predictions while
preprocessing overlaps. Tuned by `NNINTER_MAX_SESSIONS` (default 10) and
`NNINTER_SESSION_IDLE_TIMEOUT` (default 600 s).

**This matters for replacing their models with ours.** How hard the swap is depends
entirely on interaction shape, not on the model:

| Our model's shape | Work required |
| --- | --- |
| Automatic (nnU-Net style: volume in, mask out) | **Easy** — one `TaskConfig` + one `InferTask`. No frontend change. |
| Click / scribble driven | **Hard** — must implement the lease protocol above, or the panel needs rewriting. |
| Text-prompted (VoxTell style) | Medium — model must accept a text prompt. |

### 2.2 How report generation is wired

`monai-label/.../basic_infer.py` resolves the model from the request body first, then
from environment variables, in three possible paths:

1. **local MedGemma** inside the MONAI container (costs VRAM);
2. **provider APIs** — `GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`;
3. **self-hosted vLLM** at `VLLM_BASE_URL`.

We use path 3, against the MedGemma vLLM **already running on Server 2**. That is a
single environment variable, not an integration. See §6.2 for the correction it needs.

---

## 3. Target architecture — one origin per viewer

The browser must see **one origin** for the AI viewer. Splitting the viewer and its
DICOMweb across two origins reintroduces CORS preflights and breaks the server-side
Basic Auth injection that stops Orthanc prompting for a password.

So Server 2's own nginx — already part of the upstream recipe, already routing
`/monai/` — fronts everything:

```
browser
  └── https://ai-viewer.hospital.lan            NPM on Server 1, TLS terminated here
        └── 10.0.211.250:1026                   OHIF-AI nginx on Server 2
              ├── /            → static OHIF-AI viewer   (local)
              ├── /monai/      → monai_server:8002       (Docker network, never on the LAN)
              ├── /dicom-web/  → 10.0.211.249:8043       (orthanc-cors-proxy → orthanc:8042)
              └── /wado/       → 10.0.211.249:8043       (same)
```

Consequences, each deliberate:

- **One origin in the browser.** No CORS, no preflight, no credentials in any JS file.
- **`orthanc-cors-proxy` keeps doing the auth injection**, exactly as it does for the
  current viewer. Orthanc still answers only authenticated requests, and the browser
  never sees a password prompt.
- **The MONAI API is never published on the hospital LAN.** It is reachable only from
  inside Server 2's Docker network, through the viewer's own origin.
- **Server 2 publishes exactly one new port (1026)**, and only NPM on Server 1 needs to
  reach it.

> **Test the finished viewer in a private/incognito window.** Seeing images after typing
> a password is a **failure**, not a pass — it means the auth-injection proxy was
> bypassed. This is a standing rule for this stack.

### 3.1 Body size limits

Saving a DICOM SEG is a large upload. Three places must allow it:

| Hop | Setting | Note |
| --- | --- | --- |
| NPM proxy host (new) | `client_max_body_size 0;` | in Advanced; default 1M will fail |
| OHIF-AI nginx on Server 2 | `client_max_body_size 500M;` | already in the upstream recipe |
| `orthanc-cors-proxy` on Server 1 | `client_max_body_size 0;` | **already set** (2026-09-01) |

---

## 4. Server 2 — measured, 2026-09-22

**VERIFIED.** Host `Cerist-Neurochir`, `10.0.211.250`, known to Server 1 as
`stt.hospital.lan`. Ubuntu 26.04.1 LTS, kernel 7.0.0-31.

| | |
| --- | --- |
| GPU | **NVIDIA RTX 5070 Ti, 16303 MiB**, driver 595.84, **compute capability 12.0 (sm_120, Blackwell)** |
| CPU / RAM | 20 cores, 30 GB (19 GB available) |
| Disk | 824 GB, **663 GB free** |
| Docker | 29.1.3, Compose 2.40.3, NVIDIA Container Toolkit 1.20.1 |
| Runtimes | `io.containerd.runc.v2`, **`nvidia`**, `runc` — default `runc`; CDI at `/var/run/cdi/nvidia.yaml` |
| Networks | `server2_net` (vLLM, clinical-agent, proxy), `stt_net` |
| Free ports | **1025, 1026, 4242, 8002, 8042** — no collisions. `server2-proxy` holds 80/443. |
| Node / yarn | **absent — and not needed.** The viewer builds inside Docker. |

Existing containers: `server2-proxy`, `clinical-agent`, `vllm`, `stt-gateway`, `stt-engine`.

### 4.1 The VRAM constraint — the only real limit

```
16303 MiB total | 12774 MiB used | 3047 MiB free
  vllm        (MedGemma)    8260 MiB
  stt-engine  (vllm-audio)  3668 MiB
  desktop session            177 MiB
```

One 16 GB card is doing three jobs. The segmentation models need roughly 8–12 GB loaded
together. **They do not fit in 3 GB**, and no tuning changes that.

Authorised by the maintainer on 2026-09-22: `vllm` and `stt-engine` **may be stopped**
for as long as the evaluation needs, freeing ~15 GB. Understand what stops with them:

| Stopped | Clinical effect | Recovery |
| --- | --- | --- |
| `vllm` | agentgateway chat NLU degrades to the rules engine — by design, `app/nlu/medgemma.py` falls back on any model failure. Not an outage. | `docker start vllm` |
| `stt-engine` | voice dictation unavailable. | `docker start stt-engine` |

Upstream gives us a lever for this. `start.sh` takes `-n`, which loads **no** optional
model at boot — `nnInteractive` always loads, while SAM2, SAM3, MedSAM2 and VoxTell stay
lazy until first use (per-model override: `LOAD_SAM2=eager|lazy` and friends). On a 16 GB
card shared with vLLM that is the setting to start from; `-y` loads everything eagerly
and is the one most likely to exhaust VRAM.

> Server 2 is also somebody's **desktop** (a Wayland session and Claude Desktop hold
> ~180 MiB of VRAM). A long GPU-saturating run will be felt by whoever is sitting at it.
> Agree a window rather than starting unannounced.

### 4.2 GPU passthrough

Upstream's compose uses `runtime: nvidia`. That runtime **is** registered here, so it
would work — but the existing `vllm` container uses the modern form
(`runtime=runc` plus a device request, i.e. compose's
`deploy.resources.reservations.devices`). We use the modern form for consistency with
the rest of Server 2, and delete the `runtime: nvidia` line. Upstream's compose already
contains both; only one is needed.

Also: upstream sets `CUDA_VISIBLE_DEVICES=0,1`. **There is one GPU here.** Set it to `0`.

---

## 5. Evaluation plan

Four phases. **Only phase 3 touches the GPU**, so phases 1–2 can run at any time with
nothing at stake.

| # | What | GPU | Production impact | Verify by |
| --- | --- | --- | --- | --- |
| 1 | Clone OHIF-AI; build the `monai` image; download checkpoints | no | **none** | `docker images` shows `monai`; `checkpoints/` populated |
| 2 | Build the OHIF-AI viewer image | no | **none** | `docker images` shows `webapp:latest` |
| 3 | **GPU window:** stop `vllm` + `stt-engine`; start `monai_server`; segment upstream's `sample-data` | yes | NLU → rules fallback; dictation off | a mask appears in the viewer and saves as DICOM SEG |
| 4 | Restart `vllm`; generate a report against our own MedGemma | shared | minimal | a drafted report returns from `http://vllm:8000/v1` |

Phase 3 runs against **upstream's bundled Orthanc**, not the production PACS. That is
the isolation: `orthanc-pacs` on Server 1 is never touched, and its ports are free on
Server 2 anyway.

### 5.1 Test data

Start with upstream's `sample-data/`. It separates *"does OHIF-AI work"* from *"does it
work on our scanner's images"* and moves no patient data.

Only after that passes, decide between real studies (a second copy of patient data on a
second machine — a decision for the maintainer, not for this document) or Orthanc's
anonymised export.

### 5.2 Progress log

Facts only, dated. A line appears here when something has been *done*, not planned.

| Date | What | Result |
| --- | --- | --- |
| 2026-09-22 | Server 2 surveyed (§4) | **VERIFIED** |
| 2026-09-22 | Unattended SSH from Server 1 to Server 2 established | **VERIFIED** — see §5.3 |
| 2026-09-22 | Cloned to `/home/cerist/ohif-ai-eval` on Server 2, `--depth 1`, HEAD `78d0101` (2026-09-17), 304 MB | **VERIFIED** |
| 2026-09-22 | `cp .env-sample .env` — all API keys left empty (§6.5) | **VERIFIED** |
| 2026-09-22 | `scripts/download_weights.sh` | **VERIFIED** — 298 MB: `sam2.1_hiera_tiny.pt`, `MedSAM2_latest.pt` |
| 2026-09-22 | `from="10.0.211.249"` restriction on the automation key | **VERIFIED** — reconnected after the edit |
| 2026-09-22 | `docker compose build monai_server` | **VERIFIED** — `monai:latest`, **23.6 GB** |
| 2026-09-22 | `docker compose build ohif_viewer` | **VERIFIED** — `webapp:latest`, 373 MB; 213 MB of bundles present in the image |
| 2026-09-22 | GPU capability probe (`torch.cuda`, sm_120, matmul) | **VERIFIED** — §7; ~400 MB VRAM used and fully released, no service stopped |

Notes on the above:

- The clone is **shallow** (`--depth 1`). Enough to evaluate and build; run
  `git fetch --unshallow` if history or other branches are ever needed.
- **The viewer image serves from `/var/www/html`, not nginx's default
  `/usr/share/nginx/html`.** The latter still holds nginx's stock placeholder pages, so
  looking there gives the false impression of an empty build. The recipe's `nginx.conf`
  sets `root /var/www/html;`, and the Dockerfile's final stage does
  `COPY --from=builder /usr/src/app/platform/app/dist /var/www/html`. Verify a build with
  `docker run --rm --entrypoint sh webapp -c "du -sh /var/www/html"` — expect ~213 MB.
- **The frontend's data-source config is baked in at build time**, not mounted:
  `ENV APP_CONFIG=config/docker-nginx-orthanc.js` in the recipe's Dockerfile. That file
  points at the bundled Orthanc via `/pacs/`. Pointing the viewer at the production PACS
  therefore means supplying our own config file and **rebuilding the image** — it is not
  a bind-mount change like `ohif-app-config.js` is on Server 1. See §6.4.
- **The `monai` image is 23.6 GB.** With build cache, phase 1 consumed roughly 43 GB of
  disk (663 GB free before, 620 GB after). Budget for it; on a smaller disk this is the
  constraint that bites first. Most of it is the CUDA runtime plus torch 2.8 and its
  dependencies, which is why upstream's Dockerfile comment notes the switch from
  `cuda:devel` to `cuda:runtime` — inference needs no compiler.
- `scripts/download_weights.sh` fetches **only** SAM2.1-tiny and MedSAM2 (~300 MB total).
  nnInteractive and VoxTell download their own weights from Hugging Face on first use, so
  the machine needs outbound internet at first run, not just at install time. SAM3 is
  skipped (§7).

### 5.3 Access between the servers

Unattended commands run from Server 1 to Server 2 over a dedicated key:

```
Server 1: ~/.ssh/id_ed25519_server2   →   Server 2: cerist@10.0.211.250
```

A separate key exists because Server 1's interactive key `id_rsa` is
passphrase-protected and the only agent available is **gnome-keyring**, which needs a
graphical prompt to sign. In a headless session it answers `agent refused operation`, so
that key cannot be used for automation. The dedicated key has **no passphrase**.

**Mitigation — applied 2026-09-22, VERIFIED.** That key's line in Server 2's
`~/.ssh/authorized_keys` is prefixed with `from="10.0.211.249"`, so it is accepted only
from Server 1. Presented from any other address it is refused, passphrase or not.

```
from="10.0.211.249" ssh-ed25519 AAAA... server1-automation
```

The interactive `ssh-rsa` key on line 1 is deliberately **left unrestricted**: it is
passphrase-protected, so it does not carry the same exposure, and restricting it would
break its use from anywhere other than Server 1. The restriction exists specifically
because the automation key has no passphrase.

A timestamped backup was taken before the edit
(`~/.ssh/authorized_keys.bak-<timestamp>` on Server 2). Password authentication remains
enabled on Server 2, so a mistake here could not have locked anyone out.

---

## 6. Deviations from upstream — and why

Upstream's `docker-compose.yml` assumes it owns the machine. It does not. Each change
below is deliberate.

### 6.1 Drop the bundled Orthanc (after phase 3)

Upstream starts `jodogne/orthanc-plugins` as container `PACS` on 4242/8042. Useful as a
throwaway PACS during evaluation; **removed for real use**, where the viewer reads the
production Orthanc on Server 1 via `/dicom-web` (§3). Two sources of truth for studies
in a hospital is not an option.

### 6.2 Correct `VLLM_BASE_URL`

Upstream defaults to `http://host.docker.internal:8000/v1`. **That will not work here.**
Server 2 publishes nothing on host port 8000 — `docker ps` shows `8000/tcp` with no host
binding, and `curl localhost:8000/v1/models` returns nothing. vLLM is reachable only on
the Docker network:

```
VLLM_BASE_URL=http://vllm:8000/v1
```

…and `monai_server` must be attached to the **external** network `server2_net`. This is
exactly what `services/clinical-agent-service/app/config.py:79` already does.

### 6.3 One GPU, modern passthrough

`CUDA_VISIBLE_DEVICES=0` (not `0,1`); drop `runtime: nvidia`, keep the `deploy` device
reservation. See §4.2.

### 6.4 Our own viewer config and nginx

Upstream's nginx recipe ships a `.htpasswd` and routes `/pacs/` to its own Orthanc. We
replace both: no `.htpasswd` (authentication is Basic-Auth injection at
`orthanc-cors-proxy`, and TLS/access control at NPM), and DICOMweb routed to Server 1
per §3.

### 6.5 No third-party API keys

`.env-sample` offers `GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`. **Leave
them empty.** Patient imaging does not leave the hospital network. Report generation
uses the local vLLM only.

---

## 7. Watch-items

| Item | Why it matters | What to do |
| --- | --- | --- |
| ~~**sm_120 / Blackwell**~~ | **RESOLVED — VERIFIED 2026-09-22.** The installed wheel is `torch 2.8.0+cu128` (CUDA 12.8), whose architecture list is `['sm_70','sm_75','sm_80','sm_86','sm_90','sm_100','sm_120']`. The RTX 5070 Ti reports capability `(12, 0)` and a GPU matmul returns the correct result. The `cuda:12.1.1` base image is irrelevant, as expected: the wheel carries its own CUDA libraries. | Nothing to do. Re-check only if `monai-label/requirements.txt` ever pins an older torch. |
| **VRAM** | 16 GB shared across three services. | Never assume segmentation and both vLLM engines coexist. §4.1. |
| **`host.docker.internal`** | Upstream's default; wrong here. | §6.2. |
| **SAM3 checkpoint** | Requires manual access approval; place as `sam3.pt` in `monai-label/checkpoints/`. Missing checkpoints warn but do not stop other models. | Skip SAM3 unless needed. |
| **Internal vs published ports** | The standing trap in this stack. | NPM targets Server 2's **published** 1026 over the LAN; inside Server 2, nginx targets `monai_server:8002` on the Docker network. |
| **Browser caching of credentials** | Masks a broken auth chain. | Test in a private window. A password prompt is a failure. |
| **Second viewer, same Orthanc** | Segmentations written from the AI viewer land in the production PACS. | Intended — but it means AI output is real clinical data from day one. Agree a labelling convention before phase 4. |

---

## 8. Rollback

Because nothing on Server 1 changes, rollback is removal:

1. `docker compose -f <ohif-ai compose> down` on Server 2.
2. `docker start vllm stt-engine` — confirm with `nvidia-smi` that both engines are back.
3. Delete the NPM proxy host for `ai-viewer.hospital.lan` (if created).
4. Remove the `ai-viewer.hospital.lan` DNS record (if created).

The current viewer, Orthanc, OpenMRS and the imaging module are untouched throughout, so
there is nothing to restore.

---

## 9. Open decisions

| Decision | Status |
| --- | --- |
| Which segmentation models are "ours", and their interaction shape (§2.1) | **open** — decides whether the swap is a day or a project |
| GPU window for phase 3 | **granted** 2026-09-22, timing to be agreed with Server 2's desk user |
| Real vs anonymised test studies (§5.1) | **open** — deferred until after phase 3 |
| Labelling convention for AI-generated segmentations | **open** — needed before phase 4 |
| Whether report drafts are ever stored in OpenMRS | **open** — out of scope for evaluation |
