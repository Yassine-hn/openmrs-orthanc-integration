# OHIF-AI — adding an AI imaging viewer alongside the existing one

**Project:** openmrs-orthanc-integration — Neurosurgery EMR, CHU Blida
**Upstream:** [CCI-Bonn/OHIF-AI](https://github.com/CCI-Bonn/OHIF-AI) (Apache 2.0)
**Status (2026-09-23):** **NOT DEPLOYED — evaluation running on Server 2.** Phases 1–3 are
done and **phase 3 passed**: nnInteractive produced a valid DICOM SEG and a volumetry
report from a real study (§5.2). Phase 4 is wired and the model path is proven, but the
browser round-trip is not (§10.4). Sections 4, 5.2, 5.3 and 10 are *measured*; sections 1,
3, 6 and 8 are *designed* and not yet proven. **Server 1 has been untouched throughout.**
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
| Runs on | Server 1 (`10.0.211.249`) | viewer on Server 1; MONAI backend on Server 2 (`10.0.211.250`) — see §3 |
| Needs a GPU | no | **the backend does**; the viewer is static files |
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

**Only the MONAI backend needs the GPU. The viewer is static files.** So the viewer
stays on Server 1 beside Orthanc, and exactly one API route crosses to Server 2:

```
browser
  └── https://ai-viewer.hospital.lan        NPM on Server 1, TLS terminated here
        ├── /            → ohif-ai-viewer:80        Server 1, static bundles
        ├── /dicom-web/  → orthanc-cors-proxy:80    Server 1, unchanged, injects Basic auth
        ├── /wado/       → orthanc-cors-proxy:80    Server 1, unchanged
        └── /monai/      → Server 2, monai_server:8002 behind server2-proxy (TLS + IP allowlist)
```

Consequences, each deliberate:

- **One origin in the browser.** No CORS, no preflight, no credentials in any JS file.
- **The imaging path never leaves Server 1.** DICOM does not traverse Server 2 at all.
- **`orthanc-cors-proxy` keeps doing the auth injection**, exactly as it does for the
  current viewer. Orthanc still answers only authenticated requests, and the browser
  never sees a password prompt.
- **The MONAI API is never published on the hospital LAN.** On Server 2 it is reached
  through `server2-proxy` using that stack's documented pattern — an overlay plus a vhost
  template, `expose:` and never `ports:`.
- **Server 1 gains one small nginx container** (`webapp:latest`, 373 MB) beside the
  existing `ohif-viewer`. No GPU is needed to serve static files.

### 3.1 Why not host the viewer on Server 2 — a decision already made

An earlier draft of this section put the whole OHIF-AI stack on Server 2 and proxied
DICOMweb back to Server 1. **That is the shape `server2-stack/README.md` explicitly
rejected on 2026-08-18**, under "Why there is no viewer here":

> the viewer belongs on **Server 1**, next to Orthanc. […] Putting the viewer on the GPU
> host would mean either widening those CORS rules or proxying DICOM through Server 2,
> and both add a moving part to the imaging path in exchange for nothing.

The reasoning still holds, and the layout above honours it. What changed is only the
"in exchange for nothing" clause: OHIF-AI buys GPU-backed segmentation, which the plain
viewer removed in August did not. But that purchase is made by `monai_server`, not by the
frontend — so there is no reason for the imaging path to move. Splitting the two gets the
GPU without touching what August protected.

> **Test the finished viewer in a private/incognito window.** Seeing images after typing
> a password is a **failure**, not a pass — it means the auth-injection proxy was
> bypassed. This is a standing rule for this stack.

### 3.2 Body size limits

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
| 2026-09-23 | vLLM switched to `medgemma-1.5-4b-it` | **VERIFIED** — `eval_nlu` UNSAFE = 0, 27/28; 7582 MiB. Two checkpoint repairs needed; see `server2-stack/README.md` on Server 2 |
| 2026-09-23 | **Phase 3 — GPU window opened.** `vllm` + `stt-engine` stopped | **VERIFIED** — 15023 MiB free (was 3640) |
| 2026-09-23 | OHIF-AI stack up (`PACS`, `ohif_viewer`, `monai_server`) | **VERIFIED** — nnInteractive loaded and cuDNN-warmed; 2649 MiB GPU |
| 2026-09-23 | Sample study loaded into the bundled Orthanc | **VERIFIED** — 43 instances, `HCC_001`, CT-C/A/P W/WO CON |
| 2026-09-23 | Viewer routes | **VERIFIED** — `/` 200 html, `/pacs/dicom-web/studies` 200 (1 study), `/monai/info/` 200 |
| 2026-09-23 | **Interactive segmentation in a browser** | **VERIFIED — PHASE 3 PASSED.** 4 positive clicks, `nninter_core_elapsed 0.140s`. Output is a valid DICOM SEG (`SOPClassUID 1.2.840.10008.5.1.4.1.1.66.4`, 512×512×7, segment `nninter_pred_20260923131611`) correctly referencing the source series, plus a volumetry CSV: **155.47 cm³**, 50 943 voxels, mean 26.7 HU |
| 2026-09-23 | Saving a segmentation **back into the PACS** | **NOT VERIFIED** — the SEG was downloaded to disk; the bundled Orthanc still holds only the CT series. The store path matters for the target design (§1.1) and still needs exercising |
| 2026-09-23 | Phase 4 — report generation wiring | **VERIFIED to the model**, not through the browser — §10 |
| 2026-09-23 | `vllm` + `stt-engine` restarted; GPU window closed | **VERIFIED** — both healthy; §10.5 shows the window need not have been exclusive |

A caveat on the volumetry above, for a clinician rather than an engineer: HU ranged −496 to
178 with skewness −4.4 and kurtosis 28.9, so a small tail of fat- or air-density voxels sits
inside the mask. The bulk (median 36 HU) is liver-like. Whether the margin matters is a
clinical judgement, not a technical failure.

Two deviations were required to get the stack up, both in the eval clone only:

- **`CUDA_VISIBLE_DEVICES=0,1` → `0`.** One GPU here (§4.2).
- **Orthanc would not start:** the `jodogne/orthanc-plugins` image ships *both*
  `/etc/orthanc/orthanc.json` and `/etc/orthanc/advanced.json`. The recipe's bind-mount
  replaces only the first, and recent Orthanc **refuses a configuration section defined in
  two files** — it died on `DicomAssociationCloseDelay`, one of eleven overlapping keys.
  Fixed by masking `advanced.json` with `{}` via a second bind-mount; every value in it is
  a tuning default Orthanc also holds internally. Fixing keys one at a time would not have
  worked.

Also found, and worth reporting upstream: **`start.sh`'s `-y` / `LOAD_*` eager-loading is
inert.** The script `export`s `LOAD_SAM2` and friends, but `docker-compose.yml` never
declares them, so they never reach the container. `basic_infer.py` defaults to `lazy`, so
the optional models stay off the GPU regardless of the flag — which is what we wanted, but
not what the flag claims to do.

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

What that endpoint actually serves, measured 2026-09-22:

| | |
| --- | --- |
| Served model name | **`medgemma-4b-it`** — this is the string report requests must use |
| Weights | `/models/medgemma-4b-it`, quantised **fp8** on the fly by vLLM |
| Context | `--max-model-len 4096` |
| VRAM | `--gpu-memory-utilization 0.50` ≈ 8.15 GB; the STT engine takes 0.25 ≈ 4.08 GB |

Two things follow. First, a **4096-token context** is small for a radiology report
prompt that carries instructions, a slice range and a query — if report generation
truncates, that limit is the first thing to check, and raising it costs KV cache on an
already-full card. Second, `~/models/` on Server 2 also holds
`medgemma-1.5-4b-it-variant-C-fp8`, which is **not** what vLLM is currently serving; if
the intent is to draft reports with MedGemma 1.5, that is a separate change to
`server2-stack/docker-compose.vllm.yml`, not to anything here.

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
| Which segmentation models are "ours", and their interaction shape (§2.1) | **open, and the premise is in doubt** — see §9.1 |
| GPU window for phase 3 | **granted** 2026-09-22, timing to be agreed with Server 2's desk user |
| Real vs anonymised test studies (§5.1) | **open** — deferred until after phase 3 |
| Labelling convention for AI-generated segmentations | **open** — needed before phase 4 |
| Whether report drafts are ever stored in OpenMRS | **open** — out of scope for evaluation |

### 9.1 "Our own segmentation models" — searched for, not found

The original goal was to keep OHIF-AI's frontend but substitute our own segmentation
models for nnInteractive / SAM2 / MedSAM2 / VoxTell. A search on 2026-09-22 found **no
segmentation model anywhere in this system**:

| Searched | Result |
| --- | --- |
| `openmrs-orthanc-integration/` and `report-generation-service/` — `*.py`, `*.java`, `*.yml`, `*.md` for `nnunet`, `totalsegmentator`, `monai`, `onnx`, `*.pth` | nothing. Every occurrence of "segmentation" refers to **OHIF's manual brush tool** and saving the result as DICOM SEG. |
| Server 2 — `/home/cerist`, `/opt`, `/srv` for `*.pt`, `*.pth`, `*.onnx`, `*.safetensors`, `*nnunet*` | only `medgemma-4b-it` and `medgemma-1.5-4b-it-variant-C-fp8` — both language/vision-language models, neither a segmentation model. |
| Hugging Face cache on Server 2 | empty. |

So there is presently nothing to substitute. Unless models exist somewhere this search
could not reach — a collaborator's machine, a partner institution, or models not yet
trained — **the simplest path is to use OHIF-AI's four models as shipped.** They are
already integrated, already have a working UI, and nnInteractive already implements the
multi-user session-lease protocol that any replacement would otherwise have to
reimplement (§2.1).

This does not block anything. Phase 3 evaluates the shipped models; substitution, if it
ever happens, is a later and separate piece of work.

---

## 10. Phase 4 — report generation against our own MedGemma

**Status: wired and verified as far as it can be without a browser (2026-09-23).** The model,
the transport and the token budget are proven; the OHIF toolbox round-trip is not yet.

Your first attempt returned **HTTP 500**. It was not a vLLM connection problem, and four
independent defects sat between the viewer and the model. Each is recorded because each
would otherwise be rediscovered the hard way.

### 10.1 The four problems

| # | What was wrong | Evidence | Fix |
| --- | --- | --- | --- |
| 1 | The toolbox has **two separate operations**: `medGemma` loads MedGemma *inside* the MONAI container from Hugging Face; `vllm` calls an OpenAI-compatible server. The first was used. | `huggingface_hub.errors.GatedRepoError: 401 … You are trying to access a gated repo` — `google/medgemma-*` is gated and `HF_TOKEN` is deliberately empty (§6.5) | Use the **`vllm`** operation. Nothing to change; the local path stays unusable by design, and that is correct — patient imaging must not depend on a Hugging Face download. |
| 2 | The viewer **always sends `vllm_base_url`**, defaulting to `http://host.docker.internal:8000/v1`, and the backend prefers the request value over the environment. Setting `VLLM_BASE_URL` alone does nothing. | `commandsModule.ts` builds `vllm_base_url: baseUrl`; `toolboxState.ts:69` held the default; `basic_infer.py:2164` reads `data.get("vllm_base_url")` first | Toolbox default changed to `http://vllm:8000/v1` and the viewer rebuilt. `VLLM_BASE_URL` is also set, for any caller that omits the field. |
| 3 | `vllm_max_tokens` defaults to **8192**, and the `vllm` op never sends it. vLLM rejects `prompt + max_tokens > context`, and ours is **4096**. | `basic_infer.py`; measured `GPU KV cache size: 9,072 tokens` — so even `--max-model-len 8192` could not have absorbed it | Backend default → **1536**. A radiology report is a few hundred tokens; 8192 was never reachable. |
| 4 | `OpenAI(api_key="", …)` **always raises** on the installed SDK. The vLLM path could not construct a client at all, whatever the configuration. | `openai 3.17.0`, `_client.py:274`: `not self.api_key` → `OpenAIError: Missing credentials` | `api_key=os.environ.get("VLLM_API_KEY") or "EMPTY"`. vLLM ignores the value unless started with `--api-key`, and a real key can now be supplied if it ever is. |

Problems 3 and 4 are **upstream bugs**, not environment mismatches: #4 breaks the vLLM path
for every user on a modern SDK, and #3 breaks it for any server with a context under
~9k tokens. Both are worth reporting to CCI-Bonn, along with the inert `start.sh -y`
noted in §5.2.

### 10.2 How the backend reaches vLLM

`monai_server` joins Server 2's own stack network. Note the second entry:

```yaml
    networks:
      - default        # MUST stay: naming any network replaces the implicit
      - server2_net    # default, where orthanc and ohif_viewer live
```

Verified after the change: `monai → vllm` lists `['medgemma-1.5-4b-it']`, and
`monai → orthanc` still returns HTTP 200. Losing the second is the obvious way to get this
wrong, so it is checked explicitly.

vLLM is **not** published on the host — `host.docker.internal` cannot reach it, and it must
not be exposed on the LAN to make it so.

### 10.3 The token budget, measured

A synthetic 512×512 slice sent through the real path:

```
model          : medgemma-1.5-4b-it
prompt_tokens  : 276      (one image + a one-line instruction)
completion     : 22
total          : 298 / 4096
```

So **one 512×512 slice costs roughly 256 tokens**. With `max_tokens=1536` reserved for the
report, about 2,500 tokens remain for the prompt — **nine or ten slices at most.** A report
over a wider slice range will fail on context, not on quality.

Raising it is a decision for `server2-stack`, not for this evaluation, and it is not free:
at `--gpu-memory-utilization 0.50` the KV cache measures 9,072 tokens total, shared across
`--max-num-seqs 8`. Raising `--max-model-len` buys prompt room and costs concurrency.

### 10.4 What is proven, and what is not

**Proven:** MedGemma 1.5 answers a vision+text request through `http://vllm:8000/v1` from
inside `monai_server`, within budget, returning sensible text about the image it was shown.
The transport, the model, the network and the token arithmetic all work.

**Not proven:** the OHIF toolbox round-trip — a real study, a real instruction, a real
slice range, through the `vllm` operation. That needs a browser.

### 10.5 VRAM — read this before testing

With vLLM, the STT engine and nnInteractive all resident:

```
13998 MiB used | 1823 MiB free
  vllm 7718 | stt-engine 3668 | nnInteractive 1882 | desktop ~233
```

**Report generation is safe** — it reuses the already-resident vLLM. **Loading another
segmentation model is not.** SAM2, MedSAM2 and VoxTell are lazy (§4.1) and will try to
allocate on first use; 1.8 GB is unlikely to be enough, and **text-prompt segmentation is
VoxTell**, not the report path — an easy confusion given both take text.

To exercise those, free memory first: `docker stop stt-engine` returns 3.6 GB, at the cost
of dictation.

This also corrects an assumption in §4.1: the GPU window does **not** have to be exclusive.
nnInteractive costs under 2 GB and coexists with both engines comfortably. Only the
SAM-family and VoxTell need the room.

### 10.6 Reverting

Everything in phase 4 is inside `~/ohif-ai-eval`, backed up with `.bak-<timestamp>` and
`.bak2-<timestamp>` suffixes beside each file. Production was not modified: `vllm` and
`stt-engine` were stopped and restarted, nothing in `server2-stack` was edited.

The backend patches are applied by **bind-mounting** the single patched
`basic_infer.py` over the image's copy, rather than rebuilding 23.6 GB. Removing the mount
restores upstream behaviour — at which point the vLLM path breaks again on #4.
**Any rebuild of the `monai` image must carry these patches forward**, or they will be
silently lost while the mount keeps them looking present.
