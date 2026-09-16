# Recurring provider schedules — design

**Project:** openmrs-orthanc-integration — Neurosurgery EMR, CHU Blida
**Status:** **phase 1 + 2 built and deployed 2026-09-16** as `chuschedules` 1.0.0
(source in `chuschedules/`, artifacts in `module-backups/chuschedules/`). The §2 facts were
re-verified against the deployed binaries on 2026-09-16 and still hold; they were also
checked against `appointmentscheduling`/`appointmentschedulingui` **2.0.0**, which add no
recurrence and leave `ProviderSchedule` unchanged, so upgrading is not an alternative.
Open item 1 below is **resolved: both rotation shapes are required and implemented.**
**Applies to:** OpenMRS 2.4.3 refapp distro, `appointmentscheduling` **1.16.0**,
`appointmentschedulingui` **1.12.0**, both **bundled inside the WAR**
(`WEB-INF/bundledModules/`), timezone `Africa/Algiers`.

This document specifies a new module that gives providers recurring weekly schedules,
so clinic hours are defined once instead of clicked in day by day.

---

## 1. The problem

`appointmentschedulingui/scheduleProviders.page` ("Gérer les tranches de rendez-vous")
creates **one appointment block per provider per day**, by hand, forever. There is no
recurrence anywhere in the shipped stack:

- `scheduleProvidersController.js` reacts to `dayClick` only; the calendar is not
  `selectable`, so a range cannot even be dragged.
- On save it rebuilds the end timestamp from the **start** date, keeping only the time
  component — so a single block cannot span two days by construction.
- The legacy JSP form (`appointmentBlockForm.jsp`) carries `startDate`, `endDate`,
  `timeSlotLength`, `types`. No recurrence field.

For a department running six weekday clinics, that is roughly 250 manual blocks per
provider per year.

---

## 2. What the shipped module already does

Read from `appointmentscheduling-1.16.0.omod` and its API jar. These facts constrain
the design and are worth re-checking after any module upgrade.

### 2.1 The data model that everything else reads

```
AppointmentBlock (provider, location, types, startDate, endDate)
   └── TimeSlot (startDate, endDate)          ← ONE slot spanning the whole block
          └── Appointment (patient, type, status)
```

`AppointmentBlockWithTimeSlotResource1_9` — the resource the Angular UI posts to —
creates exactly **one time slot covering the whole block**, adjusts that slot on edit,
and voids any extras. There is no slot splitting. Booking capacity is decided at
booking time from the time left in the slot versus the service's duration
(`getTimeLeftInTimeSlot`, `TimeSlotFullException`).

**Consequence:** a generated day needs one block plus one whole-block time slot. Do
that and generated availability is indistinguishable from hand-made availability, and
the calendar, booking grid, daily lists, reports and REST all work unchanged.

### 2.2 The API surface the generator needs

```java
AppointmentBlock  saveAppointmentBlock(AppointmentBlock)
AppointmentBlock  voidAppointmentBlock(AppointmentBlock, String reason)
List<AppointmentBlock> getOverlappingAppointmentBlocks(AppointmentBlock candidate)
List<AppointmentBlock> getAppointmentBlocks(Date from, Date to, String locations,
                                            Provider, AppointmentType)
TimeSlot          saveTimeSlot(TimeSlot)
List<TimeSlot>    getTimeSlotsInAppointmentBlock(AppointmentBlock)
List<Appointment> getAppointmentsInTimeSlotThatAreNotCancelled(TimeSlot)
```

All public on `AppointmentService`. `getOverlappingAppointmentBlocks` takes an unsaved
candidate, which is exactly the collision check §5 needs, and
`getAppointmentsInTimeSlotThatAreNotCancelled` is what protects booked clinics.

### 2.3 `ProviderSchedule` — upstream's abandoned attempt, and why we must not use it

The module ships a `ProviderSchedule` entity: provider, location, service types,
`start_date`/`end_date`, `start_time`/`end_time`. Table
`appointmentscheduling_provider_schedule` **exists in this database and holds 0 rows.**
It has service CRUD, a Hibernate mapping, a validator, a REST resource, and a
materialiser:

```java
TimeSlot createTimeSlotUsingProviderSchedule(Date date, Provider, Location)
```

which looks up schedules matching (location, provider, date), takes **the first**,
combines the requested date with the schedule's start/end times, creates an
AppointmentBlock and one whole-block TimeSlot, and saves both. Nothing calls it except
the appointment-request path (`getTimeslotForAppointment`).

It has **no day-of-week column**, no idempotency, and no exception handling.

> **Do not store recurring schedules in this table.** Its lookup filters on the date
> range alone. Writing rows into it silently arms `createTimeSlotUsingProviderSchedule`
> in the requisition flow, which would manufacture availability on Fridays, Saturdays
> and public holidays — the exact days a recurring schedule exists to exclude. The
> entity is a useful reference for how upstream materialises a slot; it is not a
> storage location.

---

## 3. Decisions

| # | Decision | Choice |
| --- | --- | --- |
| 1 | Weekly pattern shape | **Per-day time ranges, several ranges per day.** Sunday 08:00–12:00 + 13:00–16:00 and Thursday 08:00–12:00 are both expressible. A split day generates two blocks, which is also how staff read a morning/afternoon clinic. |
| 2 | Days off | **Exception calendar in phase 1.** Global exclusions (public holidays, including the lunar ones that move each year) and per-provider exclusions (leave, conference, sick). |
| 3 | Horizon and trigger | **Manual now, nightly rolling later.** Phase 1 ships preview-then-generate over a chosen range; the nightly rolling-horizon task lands in phase 3, once the generator has run clean. |
| 4 | Access | **A dedicated privilege** (`Manage Recurring Schedules`) on its own page, granted deliberately — a template sets months of hospital-wide availability. |

---

## 4. Architecture

```
chu_schedule_template   ──┐
                          ├──▶  generator  ──▶  AppointmentBlock + TimeSlot  ──▶  existing UI
chu_schedule_exception  ──┘     (idempotent)         (upstream tables)             (unchanged)
                                     │
                          chu_generated_block  ◀── provenance: what we created, from what
```

A new module, `chuschedules`, in the api/omod Maven layout already used by
`custom-imaging-openmrs/` and `neuro-patientview/`, with its own git repository and
built `.omod` history under `module-backups/`.

Three properties are deliberate:

1. **One source of truth.** Availability lives in `AppointmentBlock`/`TimeSlot`, as it
   does today. The templates are an input to generation, never a parallel model that
   the booking UI would have to learn.
2. **No upstream change.** `appointmentscheduling` and `appointmentschedulingui` are
   bundled inside the WAR, so any patch to them lives in the container's writable layer
   and is lost the moment the container is recreated. We add a module instead; nothing
   to re-apply after `docker compose up --force-recreate`.
3. **Stopping the module stops the feature.** No blocks are lost when it is disabled;
   generation simply stops. Same charter as `chublidatheme`.

---

## 5. Data model

Liquibase in the new module. Standard OpenMRS audit columns
(`creator`, `date_created`, `changed_by`, `date_changed`, `voided`, `voided_by`,
`date_voided`, `void_reason`, `uuid`) on all three tables; omitted below for brevity.

```sql
chu_schedule_template
  template_id        int       pk
  name               varchar   -- "Consultation Neurochirurgie - Dr X"
  provider_id        int       fk provider          not null
  location_id        int       fk location          not null
  valid_from         date                           not null
  valid_to           date      null                 -- null = open-ended
  active             boolean                        not null

chu_schedule_template_range          -- decision 1: several ranges per weekday
  range_id           int       pk
  template_id        int       fk chu_schedule_template
  day_of_week        tinyint   -- 1=Sunday .. 7=Saturday (java.util.Calendar)
  start_time         time                           not null
  end_time           time                           not null

chu_schedule_template_type           -- services offered, mirrors the block's types
  template_id        int       fk chu_schedule_template
  appointment_type_id int      fk appointmentscheduling_appointment_type

chu_schedule_exception               -- decision 2
  exception_id       int       pk
  exception_date     date                           not null
  provider_id        int       fk provider  null    -- null = applies to everyone
  reason             varchar                        -- "Aïd el-Fitr", "congé annuel"

chu_generated_block                  -- provenance and idempotency key
  generated_id       int       pk
  template_id        int       fk chu_schedule_template
  range_id           int       fk chu_schedule_template_range
  target_date        date                           not null
  block_uuid         char(38)                       not null   -- NO fk, see below
  unique (range_id, target_date)
```

`block_uuid` carries **no foreign key** to `appointmentscheduling_appointment_block`.
That table belongs to another module: a constraint would couple our schema to its
liquibase and could block its upgrades. We resolve the block by uuid and treat "block
no longer exists" as an ordinary, expected case.

The `unique (range_id, target_date)` constraint is what makes double-generation
impossible at the database level, not merely unlikely in code.

---

## 6. The generator

One class, one entry point, two modes. Dry run and real run walk identical code paths;
only the final write is suppressed. This is what makes the behaviour verifiable before
it ever touches production data.

```
generate(template, from, to, dryRun) -> Report

for each date D in [from, to]:
    if D < today                                  -> skip  (reason: past)
    if D outside [valid_from, valid_to]           -> skip  (reason: out of validity)
    if D excluded globally or for this provider   -> skip  (reason: exception + label)
    for each range R on weekday(D):
        if (R, D) already in chu_generated_block  -> skip  (reason: already generated)
        candidate = block(provider, location, types,
                          D + R.start_time, D + R.end_time)
        if getOverlappingAppointmentBlocks(candidate) is not empty
                                                  -> skip  (reason: conflicts with
                                                            existing block <uuid>)
        if not dryRun:
            block = saveAppointmentBlock(candidate)
            saveTimeSlot(slot spanning block.start .. block.end)
            record (template, R, D, block.uuid) in chu_generated_block
        report.created += D + R
```

### Invariants

These are the rules that matter in a hospital, and each one gets a unit test:

| Invariant | Why |
| --- | --- |
| Never writes to a date before today | The past is a record, not a schedule. |
| Never creates a block overlapping an existing one | `getOverlappingAppointmentBlocks` is checked for every candidate, so the two blocks already in the calendar and anything a clerk adds by hand stay authoritative. Manual work is never silently duplicated or shadowed. |
| Never deletes or alters a block whose slot has appointments | Deactivating or narrowing a template voids only **future, generated, empty** blocks — verified through `getAppointmentsInTimeSlotThatAreNotCancelled`. Anything booked is left standing and listed in the report for a human to resolve. A silently deleted booked clinic is the worst outcome this feature could produce. |
| Idempotent | Guaranteed by `unique (range_id, target_date)`, not by luck of timing. Re-running over the same range creates nothing and reports "already generated". |
| Every run reports created / skipped / refused, with reasons | Both the manual action and the nightly task must be auditable after the fact. |

### On timezone

`Africa/Algiers` is UTC+1 year-round with no DST, and the container is pinned to it
(`TZ`, plus `-Duser.timezone`). Local wall-clock times therefore convert to instants
unambiguously, and the whole class of DST scheduling bugs — a clinic that gains or
loses an hour twice a year, a duplicated or missing 02:00 — does not arise. **If this
system is ever deployed somewhere with DST, the generator must be revisited**: storing
`java.sql.Time` and combining it with a date is only safe under this assumption.

---

## 7. REST surface

Under the module's own namespace, so nothing collides with
`ws/rest/v1/appointmentscheduling/*`:

| Method | Path | Purpose |
| --- | --- | --- |
| GET/POST/DELETE | `ws/rest/v1/chuschedules/template` | template CRUD (with ranges and types) |
| GET/POST/DELETE | `ws/rest/v1/chuschedules/exception` | exception calendar |
| POST | `ws/rest/v1/chuschedules/generate` | `{template, from, to, dryRun}` → report |

`dryRun: true` is the default in the resource. Generation must be asked for explicitly.

---

## 8. UI — "Horaires récurrents"

One page, French, styled by `chublidatheme` like the rest of the app, behind the
`Manage Recurring Schedules` privilege.

- **List:** templates by provider and location, with their weekly pattern rendered as a
  one-line summary ("Dim, Lun, Mar 08:00–12:00 · 13:00–16:00 | Jeu 08:00–12:00") and
  the horizon each one has already generated to.
- **Edit:** provider, location, services, validity range, and a weekday grid where each
  day holds zero or more time ranges.
- **Exceptions:** dated exclusions, global or per provider, with a reason.
- **Preview then generate:** pick an end date, see exactly which days would be created
  and which would be skipped and why, then confirm. The preview is the same generator
  in dry-run mode — never a separate estimate that could disagree with the write.

---

## 9. Phasing

Each phase is independently verifiable and independently deployable.

| Phase | Content | Verified by |
| --- | --- | --- |
| **1** | Liquibase, entities, DAO, service, generator, `generate` + template/exception REST, privilege | Unit tests for every §6 invariant (the generator is pure logic and needs no server). Then a dry run against production data whose report is checked by eye — **no writes**. |
| **2** | The "Horaires récurrents" page, preview-then-generate | One real template for one provider, generated over one month, compared against the calendar. Blocks must be indistinguishable from hand-made ones and bookable. |
| **3** | Nightly rolling-horizon task (90 days, configurable), exceptions screen, generation log view | The task's report for several consecutive nights, plus a deliberate re-run proving idempotency. |

Deployment follows the existing protocol: one change at a time, `.omod` archived under
`module-backups/`, backup before install, verify after.

---

## 10. Known limitations

- **Per-day granularity, not per-week.** "Every other Tuesday" and "first Monday of the
  month" are not expressible. If rotating on-call schedules need that, it is a
  recurrence-rule field, not an extension of the weekday grid — say so before phase 1.
- **Templates do not retro-adjust.** Editing a template does not rewrite blocks already
  generated; it changes what future generation produces, and the report names the
  future generated-and-empty blocks it voided. Changing next week's clinic hours after
  patients are booked stays a human decision.
- **No capacity model.** Booking capacity remains the upstream rule (time left in the
  slot versus service duration). Templates set *when* a clinic is open, not how many
  patients fit.
- **Lunar holidays need entering each year.** Eid dates move; the exception calendar is
  data, not an algorithm. A yearly reminder is cheaper than an Islamic-calendar
  dependency.
- **An `appointmentscheduling` upgrade could change §2.1.** If a future version splits
  blocks into multiple slots, the generator's slot creation must follow. The facts in §2
  are the contract to re-verify.

---

## 11. Rollback

| Situation | Action |
| --- | --- |
| Generator produced wrong blocks | The report names every block it created; `chu_generated_block` is the authoritative list. Void the generated, empty ones by uuid. Booked ones were never touched. |
| Feature not wanted | Stop the module. All generated blocks stay valid and editable in the existing UI — they are ordinary appointment blocks. Nothing to migrate back. |
| Schema removal | Drop the three `chu_schedule_*` tables and `chu_generated_block`. No upstream table is modified, so nothing else is affected. |

---

## 12. Open items

1. ~~Rotating patterns (§10, item 1) — needed, or out of scope?~~ **Resolved
   2026-09-16: both shapes needed.** Implemented as a per-range rule: `WEEKLY` with a
   week interval and an anchor (every other Tuesday, one week in three), and
   `MONTHLY_NTH` with a position (first/2nd/3rd/4th/last Monday of the month). The anchor
   is normalised onto the range's weekday, which removes any week-start convention from
   the arithmetic.
2. ~~Default rolling horizon: 90 days assumed.~~ **Resolved 2026-09-16: tomorrow to one
   year ahead.** A single run is capped at 366 days (`MAX_HORIZON_DAYS`).
3. Who holds `Manage Recurring Schedules` — which existing role?
4. Do provider-leave exclusions need to reach anything beyond appointment
   generation (e.g. the daily lists), or is skipping generation sufficient?


---

## 13. Traps found during implementation (2026-09-16)

Both of these were found the hard way and are cheap to re-introduce.

| Trap | Rule |
| --- | --- |
| **A `--` inside an XML comment in `webModuleApplicationContext.xml` took the whole application UI down.** Spring refreshes *every* module's web context together, so one malformed file stops the entire OpenMRS web layer, not just this module — the login page 404s and the app looks dead. Neither Maven nor the omod packaging parses these files. | Run `chuschedules/validate-xml.sh` before every deploy. It parses every XML file in the module. |
| **Calendar dates mapped as `java.util.Date` land on the wrong day.** The app JVM runs `Africa/Algiers` (UTC+1) while the MySQL container runs UTC, so binding a date as a *timestamp* turns local midnight into 23:00 the previous day, and a `DATE` column silently keeps the earlier day. A template saved as valid from 1 Sept was stored as 31 Aug. | Map calendar dates as Hibernate `type="date"` (binds `java.sql.Date`, timezone-free). Only genuine instants — the audit columns — stay timestamps. |

**Readiness check after a restart:** `/openmrs/` returns 200 while modules are still
loading. The honest signal is
`/openmrs/referenceapplication/login.page` returning **200**; until then a working module
will still 404.
