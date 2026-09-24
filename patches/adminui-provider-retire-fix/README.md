# adminui provider retire/restore/save fix (HTTP 400 "Échec de l'enregistrement")

Applied: 2026-09-24. Target: `openmrs-app` (openmrs/openmrs-reference-application-distro
2.12.2), OpenMRS 2.4.3, adminui 1.6.0, uicommons 2.19.0 (AngularJS 1.5.8).
Found in UAT: `../../UAT-Issue-Log.md` #1. The full evidence trail is there.

**This patch is cumulative.** Its omod contains the `../adminui-forcepassword-fix/` change as
well. It was built from the deployed force-password-patched omod, not from the upstream
original. That older patch's `apply.sh` now refuses to run, because installing it would
silently undo this fix.

## Symptom

*Gérer les comptes → edit an account → Détails du prestataire*: **Retire**, **Restore** and
**edit (pencil) → Save** all fail with the toast "Échec de l'enregistrement". The access log
shows `POST /openmrs/adminui/systemadmin/accounts/providerTabContentPane/process.action`
→ **400**. The user-account buttons on the same page work, because they use REST.

## Root cause

`providerDetails.js` form-encodes the request body in a custom `transformRequest` and sets
`Content-Type: application/x-www-form-urlencoded` on the headers object it receives. In
AngularJS ≥ 1.3, that object is a **lower-cased copy**: `fd()`/`ed()` in the shipped
`angular.min.js` build a new map. So the header never reaches the request, and it goes out
as `application/json`. Tomcat does not parse a JSON-labelled body into request parameters,
so the fragment controller receives `uuid`, `action` and `reason` as `null`. It then tries
to save an empty provider, `ProviderValidator` rejects it
(`Provider.error.personOrName.required`), and the controller returns HTTP 400. Upstream
adminui `master` still has the same code (checked 2026-09-24).

A second, smaller defect sat behind it. `serialize()` turned unset values into the literal
string `undefined`. A blank (optional) retire reason would have been stored as `undefined`,
and a blank field on edit would have been saved as `undefined`.

## The fix

One file changes, `web/module/resources/scripts/fragments/systemadmin/providerDetails.js`.
220 entries in, 220 out, and only that entry differs.

1. The `PmProvider.process` `$resource` action declares
   `headers: { "Content-Type": "application/x-www-form-urlencoded; charset=utf-8" }`.
   Angular honours action-level headers.
2. `serialize()` skips `undefined`/`null` values. A blank retire reason is therefore stored
   as `NULL`, which core accepts: the retire path runs `RetireHandler` only, with no
   validation.

The diff is `providerDetails.js.original` → `providerDetails.js.patched`. Both versions were
syntax-checked with Nashorn, and `serialize()` was exercised on the three real payloads:

```
before  retire, blank reason : uuid=u-1&reason=undefined&action=retire&
after   retire, blank reason : uuid=u-1&action=retire&
both    retire, with reason  : uuid=u-1&reason=D%C3%A9part&action=retire&
both    restore              : uuid=u-1&action=restore&
```

## Files here

| File | Purpose |
|---|---|
| `adminui-1.6.0.omod` | **patched, cumulative** module. This is the one deployed. md5 `db7365645e8b9f70c62c1bc38b1822d2`, sha256 `8b3379b0…ecb9810` |
| `providerDetails.js.original` / `.patched` | the changed file before and after, for diffing |
| `apply.sh` | installs the omod into the `.OpenMRS` volume, checks its md5, restarts, runs `verify.sh` |
| `verify.sh` | credential-free: checks that the patched JS is served, then runs the force-password `verify.sh` |
| `rollback.sh` | reinstalls `../adminui-forcepassword-fix/adminui-1.6.0.omod` (the previously deployed build, md5 `7ae48f68…`) |

It is installed in the same place as the force-password fix
(`/usr/local/tomcat/.OpenMRS/modules/adminui-1.6.0.omod`, in the named volume), and it
survives container recreation for the same reason. The same caveat also applies: a distro
image carrying adminui > 1.6.0 would replace it. Run `verify.sh` after any such change.

## Verification

Deployment, 2026-09-24 14:11–14:14 (restart ≈ 65 s until the login page answered):

- `apply.sh`: md5 matched. `verify.sh` → **PASS** (patched JS served) and **PASS**
  (force-password fix intact). `verify.sh` had returned **FAIL** before deployment, so the
  check does discriminate.
- All 48 `*.started` global properties are `true`.
- Startup log: 11 `ERROR -` lines. There are 8 `Failed to install metadata package
  Reference_Application_*` (xstream `EnumMapper`), 3 DWR `dwr.xml` parse errors, and the
  misleading `ImagingActivator … Started Imaging`. **All are pre-existing.** The same set
  appears at every startup in `docker logs` back to 2026-08-30. *(An earlier version of this
  note said "no ERROR entries". That was wrong: the filter used `" ERROR "`, which cannot
  match lines that begin `ERROR -`. Use `grep -E '^ERROR - '`.)*

Functional check, done in the UI because it needs a logged-in session. Hard-refresh first
(Ctrl+Shift+R) so the browser drops the cached old JS. Each action should return **200** in
`/usr/local/tomcat/logs/localhost_access_log.<date>.txt`, and log
`ProviderService.retireProvider` / `unretireProvider` / `saveProvider` in
`docker logs openmrs-app`:

| Action | Expected DB result (`provider` row) | Result |
|---|---|---|
| Retire *10 Achour* (id 10) with a reason | 14:19:06 → **200**, `ProviderService.retireProvider(provider 10, "facultatif")` logged | **PASS** |
| Restore *10 Achour* | 14:19:45 → **200**, `unretireProvider` + `saveProvider` logged, DB `retired=0` | **PASS** |
| Retire, blank reason | `retired=1`, `retire_reason` NULL | not yet tested |
| Edit → Save | changed field saved | not yet tested |

Tested 2026-09-24 by the maintainer. Before the patch, the same button returned **400** and
never reached `retireProvider`. The same session also restored Achour's *user* account
(14:19:40, REST, 200). That path does not use this patch.
