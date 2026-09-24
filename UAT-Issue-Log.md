# UAT issue log — use-case testing through the UI

Problems found while testing the system through its normal user flows (the use cases in
`Neurosurgery_EMR_PACS_OHIF_Use_Cases_and_User_Guide_Test_Plan.pdf`), one entry per problem.
Work happens on the `develop` branch, created from `main` on 2026-09-24.

Each entry records the symptom as the tester saw it, the evidence, the root cause, and the
fix with its status. **Status values:** `Diagnosed` (cause proven, no change made yet) ·
`Fix proposed` (awaiting the maintainer's approval) · `Deployed` (applied, functional UI
check pending) · `Fixed` (applied **and** verified) ·
`Not a bug` (behaviour is by design; documented instead).

Screenshots referenced below live on the server under `~/Pictures/Screenshots/<topic>/`.

| # | Summary | Status |
| --- | --- | --- |
| 1 | Retiring a provider from **Gérer les comptes** fails with "Échec de l'enregistrement" | Fixed |

---

## 1. Provider account cannot be retired from Manage Accounts

**Reported:** 2026-09-24, account *10 Achour* (person 34, user `Achour` / id 15, provider
identifier 14 / id 10, role *Clerk*).
**Screenshots:** `~/Pictures/Screenshots/delete user achour 10/`.

### Symptom

On *Administration du système → Gérer les comptes → (edit) 10 Achour*
(`/openmrs/adminui/systemadmin/accounts/account.page?personId=34`):

1. **Provider → Retire** → red toast **"Échec de l'enregistrement"**; the provider is not
   retired. Tried three times (13:13:43, 13:13:54, 13:29:49).
2. **User → Retire** → success; the user tab shows struck-through with a **Restore** button.
3. Back on *Gérer les comptes*, the row *10 Achour* still shows **1** user account and
   **1** provider account.

Symptoms 1 and 3 are unrelated. Symptom 1 is a real bug. Symptom 3 is by design.

### Evidence

| Source | What it shows |
| --- | --- |
| MySQL `users` | user 15: `retired=1`, `date_retired=2026-09-24 12:14:09` (UTC = 13:14 local). The user retire worked. |
| MySQL `provider` | provider 10: `retired=0`. The provider retire did not. |
| Tomcat `localhost_access_log.2026-09-24.txt` | all three `POST /openmrs/adminui/systemadmin/accounts/providerTabContentPane/process.action` → **HTTP 400**, 92 bytes. |
| `docker logs openmrs-app` | `UserService.retireUser` is logged at 13:14:09. **No `ProviderService.retireProvider` call is logged at all**, so the controller never reached the retire. Instead, each 400 coincides to the second with `WARN Provider.getName … providers who are not linked to person`. That warning fires only for a provider object **with no person**. Achour's provider does have a person (34), so the server was handling an **empty** provider. |

### Root cause — adminui 1.6.0 incompatible with the AngularJS 1.5.8 shipped by uicommons 2.19.0

The two retire buttons use different mechanisms:

- **User → Retire** calls the REST API (`DELETE /ws/rest/v1/user/<uuid>?reason=…`) with its
  parameters in the URL. It works.
- **Provider → Retire / Restore / Save** calls the fragment action
  `providerTabContentPane/process.action` through `PmProvider.process(...)` in
  `adminui/resources/scripts/fragments/systemadmin/providerDetails.js`. It sends
  `uuid`, `action` and `reason` in the POST **body**, which it form-encodes with a custom
  `transformRequest`:

  ```js
  function transformRequest(data, getHeaders){
      var headers = getHeaders();
      headers[ "Content-Type" ] = "application/x-www-form-urlencoded; charset=utf-8";
      return serialize(data);
  }
  ```

In AngularJS ≥ 1.3, `getHeaders()` returns a **lower-cased copy** of the request headers.
This is confirmed in the shipped `uicommons/resources/scripts/angular.min.js` (v1.5.8):
`fd(c)` returns `ed(c)`, which builds a new map (`b=U()`). The assignment above changes only
that copy, and the request still goes out as `Content-Type: application/json`. Tomcat parses
POST bodies into request parameters only for `application/x-www-form-urlencoded`, so the
controller receives `uuid=null`, `action=null` and `reason=null`. Here is what
`ProviderTabContentPaneFragmentController.process` then does:

1. `action` is neither `retire` nor `restore`, so it takes the **edit/save** branch.
2. It binds a new, empty `Provider`. `ProviderValidator` calls `getName()`, which produces
   the WARN, and rejects it with `Provider.error.personOrName.required`.
3. It returns `FailureResult`, which gives HTTP 400 and the generic toast.

The same bug breaks **Provider → Restore** and **Provider → edit (pencil) → Save** on the
same page, because all three use `PmProvider.process`. **Adding** a provider to a new account
is unaffected, because it goes through the server-side `account.page` form POST. Upstream
`openmrs-module-adminui` `master` still carries the identical code (checked 2026-09-24), so
no newer adminui release fixes it.

### Symptom 3 is not a bug: the list counts retired accounts

`manageAccounts.gsp` prints `it.userAccounts.size` and `it.providerAccounts.size`.
**Retired accounts are included.** OpenMRS **retires** accounts. It does not delete them,
because encounters, appointments and every `creator`/`changed_by` column keep referring to
them. Corroboration: *Houda Houda* shows **2** user accounts, and both (`16-6` and `HoudaH`)
are retired. To see whether an account is active, open it. Retired accounts are struck
through and offer **Restore**.

A retired user **cannot log in**. OpenMRS core 2.4.3 `HibernateContextDAO.authenticate`
looks users up with `… and u.retired = false`. Achour's login is therefore already disabled.

Side observation: the user's retire reason was stored as `Facultatif`, which is the
placeholder word in the reason box. When the box is left empty, REST stores
`web service call` instead, as seen for `HoudaH`. So `Facultatif` was typed into the box.
This is harmless.

### Workaround (no code change; only needed if the patch is rolled back)

Retire the provider from the legacy admin page. It is a server-side form and works: open
`http://10.0.211.249:8080/openmrs/admin/provider/index.htm` (linked in legacy
*Administration* as **Prestataire en Charge**, the French label for *Manage Providers*),
search `14`, open the provider, fill **Raison supprimé** (*Retired Reason*) and click
**Retire**. The reason is **required**, because `ProviderValidator` rejects a retired
provider with a blank `retireReason`. **Do not** use **Delete forever** (purge). It is
irreversible, and it fails anyway for a provider referenced by appointment blocks.

### Fix — deployed 2026-09-24 14:14

The fix is `patches/adminui-provider-retire-fix/` (README, apply, verify, rollback). It is
**cumulative**. It was built from the deployed omod, so it keeps the force-password fix,
and it changes only `providerDetails.js`:

1. The `PmProvider.process` action declares the form-urlencoded `Content-Type` itself,
   where Angular honours it.
2. `serialize()` skips unset values. A blank (optional) reason is stored as `NULL`, not as
   the text `undefined`. Core's retire path runs no validation, so `NULL` is accepted.

Deployed with `apply.sh` (restart ≈ 65 s). Checks run so far:

- `verify.sh`: **PASS**. The patched JS is served, and the force-password fix is still
  intact. Before deployment it returned **FAIL**.
- All 48 modules report started. The startup log carries only the 11 `ERROR -` lines
  that appear at every startup since 2026-08-30 (metadata-package imports, DWR config).
  None is new.

**UI test, 2026-09-24 (maintainer):**

- Provider **Retire** on *10 Achour* at 14:19:06 → **200**, and
  `ProviderService.retireProvider` was logged. Before the patch, the same action returned
  400 and never reached the service.
- Provider **Restore** at 14:19:45 → **200**, `unretireProvider` was logged, and the DB
  shows `retired=0`.

**Not yet exercised:** retire with a blank reason, and edit → Save. Both go through the
same corrected request path. Test them when convenient; the table is in the patch README.
*State after the test:* Achour's user and provider are both **active** again, because
both were restored during the test.

### Offboarding note: retiring the provider does not clear the provider's schedule

Provider 10 still has an **active** recurring template, *consultation neurochergie* (template
4, valid 2026-09-20 → 2026-12-31). `chuschedules` does not check whether the provider is
retired. Nothing generates blocks for this provider **today**: the remaining future blocks are all
voided, and the nightly task *CHU Recurring Schedules – génération glissante* is stopped.
But a manual *Générer* on that template, or enabling the nightly task, would create new
bookable blocks for a retired provider. Until `chuschedules` skips retired providers (not
yet decided), offboarding a provider is a two-step procedure:

1. Retire the provider (and the user, if they have one).
2. In *Horaires récurrents*, deactivate that provider's templates.

The provider's two past appointments (10 and 20 Sept, status `SCHEDULED`) are history and are left as is.
