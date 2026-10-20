# Log a Visit → Objection Cases: verification and implementation plan

Ticket: **Update Log a Visit to create objection Cases** (Phase 1 of *Objection Tracking Re-Design*, Workfront project "Objection Tracking Re-design")
Design baseline: *Objection Tracking Re-Design: Business Process*, Eyad Abuimaish, 2026-10-09 ("the design document")
Org inspected: Hunter sandbox (alias `hunter`, `orlandohealth--hunter.sandbox.my.salesforce.com`)
Date: 2026-10-19 (revised the same day against the design document)
Mode: read-only. Metadata was retrieved in metadata-API format to a scratch folder outside the project, and only read-only SOQL was run. Nothing was deployed, and no org metadata or records were changed.

---

## Summary

- **The design document settles most of what the first draft left open:**
  - Cases **replace** `Visit_Objection__c` for PRM logging (decisions 1, 13).
  - The Case **owner is the liaison who logged it** and the status is **New** (decision 10, future-state process).
  - **Region comes from the provider** (decision 8).
  - Network Team keeps today's logging (decision 12).
  - Liaisons cannot delete Cases (decision 11, proposed).

  This plan now follows those decisions. The weekly manual grouping step (PRM Objection Triage queue, Group Into Issue) is superseded; grouping returns in Phase 2 as parent and child Cases.
- **Most of Eyad's Case foundation is in Hunter and matches.** The record type, support process, the "Log A Visit" origin, the 7 categories, Region, Visit Report, Resolution (including "Logged in Error"), Resolution Notes, the closing rule, and the permission set with its three groups all exist.
- **Four findings change the build:**
  1. **`Visit_Date__c` is a formula** (`Visit_Report__r.Visit_Date__c`). It fills in from the Visit Report, so the flow doesn't set it.
  2. **"Practice & Group" is the standard `AccountId` field**, relabelled. Eyad's build puts the *facility* there and hides `Facility__c`, but the design document says the Case carries both *practice and facility*. That needs one decision (Q2).
  3. **In user mode, no liaison could save the Case.** Log a Visit runs in user mode, and `Region__c` is read-only for every PRM user (and `Origin` for Alabama users). The Case insert goes in a small subflow that runs in system mode.
  4. **Alabama access to Cases exists in Hunter only through the new permission set.** The design document's "Alabama liaisons have no access to Cases today" is still true in prod, and the fix has to ship in the same release.
- **Blocked until decided:** the status list and the closing requirements (design: "Decisions needed", first two rows). Eyad's Hunter build already has 7 statuses and a closing rule. If Kim changes either, the flow's `Status = New` and the closing tests change with it.
- **Two existing flow defects are fixed in this ticket.** The design document lists the first itself ("Partial saves").
  - There is no rollback on save errors, while the error screen says "Nothing was recorded".
  - The Back button can save the same objection twice, which would mean duplicate Cases.
- **Phase 1 needs work in other tickets:** the provider Objections tab, 5 reports, 2 dashboards, Vital Reports, the data warehouse feed, and the Field Visit Assistant. Log a Visit's switch to Cases should go live at the agreed quarter boundary (suggested 2027-01-04), together with those changes.

---

## Design document → build impact

| # | Design decision (status) | What it means for this ticket |
|---|---|---|
| 1 | Objections logged as Cases, **replacing** today's records (Agreed) | Log a Visit stops creating `Visit_Objection__c` and creates Cases instead (§3.3). |
| 2 | Logging works as today, with enhancements (Agreed) | Same screens and order. Enhancements: category definitions, note prompt and no-PHI warning, rollback on errors. |
| 3–4 | Everyone in PRM can see and work every objection (Agreed) | Case sharing is already Public Read/Write/Transfer, so any PRM user with Case Edit can edit and reassign. Alabama needs Case access in prod (R1). |
| 5 | Short list of categories, each with a definition (Agreed) | The 7 OH/BH `Objection__c` rows match `Objection_Category__c`. The logging screen's **Description** column reads `Objection__c.Description__c`, which is **blank on all 7** in Hunter. Load the definitions as data (§3.2 step 8). |
| 6 | Free-text notes stay (Agreed) | `S09_LT01_ObjectionNotes` → `Case.Description`. |
| 7 | Facilities selected as today (Agreed) | Keep the single `S08_CL01_Facility` picker per visit. |
| 8 | Region filled in from the **provider** (Agreed) | `Case.Region__c = Contact.Region__c` (`Get_Provider_Record.Region__c`), not the user's profile. |
| 9 | Cannot close without a resolution (Agreed) | Validation rule `Resolution_Required` exists. Its detail depends on the pending "what must be recorded before closing" decision. |
| 10 | One Case per category, **owned by the logger**; may change to one Case per visit (Proposed) | `OwnerId = $User.Id`, one Case per selected category. The Case-building loop is kept self-contained so a per-visit switch changes only that loop (§3.2). |
| 11 | Liaisons cannot delete objection Cases; a mistaken one is closed as "Logged in error / duplicate" (Proposed) | Remove Case Delete from the **PRM User** profile. **PRM Manager** waits on the "Delete rights for managers" decision. The design names one value, but Resolution has two ("Logged in Error", "Duplicate"); see Q6. |
| 12 | Network Team keeps today's logging for now (Proposed) | `Practice_Group_Network_Log_Visit_Report` and Network access to `Visit_Objection__c` are left alone. |
| 13 | Pre-go-live objections stay as **read-only history**, not converted (Proposed) | PRM users lose Create/Edit/Delete on `Visit_Objection__c` at go-live; Network keeps them. The provider Objections tab must show old and new (other ticket). |
| — | Partial saves (today's problem) | Roll Back Records on every save fault (§3.2 step 6). |
| — | Notes must not contain patient information | Add a one-line prompt and warning to S09 (subject to the pending "note per category" decision). |
| — | Alabama access in the same release (risk: certain) | BH PRM User needs Case access, the Provider Objection record type, and the system-mode subflow. Test as an Alabama user in UAT. |

---

## Step 1 — Foundation verification

### 1.1 Case configuration

| Item | Expected | Found (API name / value) | Match? | Notes |
|---|---|---|---|---|
| Record type | "Provider Objection" | `Provider_Objection` (Id `012dy000001zBHJAA2`), active | ✅ | The only Case record type besides Master. |
| Support process | Reused from earlier work | `Provider Objection Process` (`019dy000001YNmPAAW`), active | ✅ | Statuses: **New** (default), Triage, In Progress, On Hold, Escalated, Resolved, Closed - No Action. The design document still lists the **status list as an open decision** (suggested: open, closed, plus "waiting on someone else"). |
| Status picklist (master) | — | On Hold, Escalated, **Closed**, New (default), Triage, In Progress, Resolved, Closed - No Action | ℹ️ | Closed statuses (`IsClosed`): Closed, Resolved, Closed - No Action. "Closed" is **not** in the support process. |
| Origin value | "Log A Visit" added | Master: Email, Phone, Web, **Log A Visit**. Provider Objection RT: **Log A Visit only** (record-type default) | ✅ | The master value list has no default. A record-type default applies only in the UI, so the flow must set `Origin` explicitly. |
| Objection Category | 7 values | `Objection_Category__c`, Picklist, **restricted**, history on. Values: Patient Access, Communication, Records, Patient Experience, Insurance, Network Access, Locations. All 7 enabled on the RT. | ✅ | Same 7 as the design document's category table, and the same names as the 7 `Objection__c` rows flagged OH/BH PRM. Payor and Referrals are Network-only. |
| Region | New field | `Region__c`, Picklist, **restricted**, history on. Values: Alabama, Florida. Both on the RT. | ✅ | Same values as `Contact.Region__c`, so a straight copy from the provider works. |
| Visit Report | New field | `Visit_Report__c`, Lookup(`Visit_Report__c`), delete = Set Null, relationship `Objection_Cases`, no history | ✅ | |
| Visit Date | New field | `Visit_Date__c`, **Formula (Date)** = `Visit_Report__r.Visit_Date__c`, not createable | ⚠️ | It fills in automatically. It can't be history-tracked. Reports by visit date work. |
| Resolution | Reused, "Logged in Error" added | `Resolution__c`, Picklist, restricted, history on. Values: Resolved - Fixed, Resolved - Explained to Provider, Referred to Another Team, No Action Required, **Duplicate**, **Logged in Error**. All on the RT. | ✅ | Design decision 11 says "Logged in error / duplicate" (one value?). See Q6. |
| Resolution Notes | Reused | `Resolution_Notes__c`, Long Text Area (32,768), history on | ✅ | The design's "summary of actions taken". |
| Practice & Group holds the facility | — | Standard **`AccountId`**, relabelled **"Practice & Group Name"** (Lookup Account), history on | ✅ (as built) / ❓ (vs design) | `ContactId` is relabelled **"Provider Name"**. The design document says the Case carries *provider, practice, visit, facility*. See Q2. |
| Facility hidden | `Facility__c` hidden | `Facility__c` (Lookup Account) exists. It is **not on `Case-Case Layout`** and not in the new permission set. PRM User and PRM Manager profiles still have Read/Edit. | ✅ | Becomes the facility field again if Q2 goes that way. |
| Other objection fields (pre-existing) | — | `Objection__c` "Objection Theme", `First_Reported__c`, `Last_Reported__c`, `Report_Count__c` | ℹ️ | From the 2026-10-07 grouping build, which exists **only in Hunter and on branch `feature/field-visit-assistant`** (not on `main`, not in prod). Superseded by the design document; see §3.3. |
| Layout | — | `Case-Case Layout` (modified by Eyad 2026-10-16): Owner, Case Number, Region, Objection Category, Visit Report, Visit Date, Practice & Group, Provider, Status, Origin, Priority, Type, Resolution, Resolution Notes, Subject, Description, … | ✅ | |

### 1.2 Validation rule

| Item | Expected | Found | Match? | Notes |
|---|---|---|---|---|
| Closing rule | Cannot close without Resolution; Resolution Notes required unless Resolution = "Logged in Error"; admins exempt | `Resolution_Required`, active, last modified by Eyad Abuimaish 2026-10-16 | ✅ | Formula below. The design document's "what must be recorded before closing" is still an open decision (suggested: outcome + summary of actions). |
| Admin exemption | Admins exempt | `NOT($Profile.Name = "System Administrator")` | ✅ | Profile-name based. |
| Scope | Provider Objection only | `RecordType.DeveloperName = "Provider_Objection"` | ✅ | |
| Closed statuses tested | — | Resolved, Closed - No Action, Closed | ℹ️ | Must be updated if the status list changes. No `errorDisplayField`. |

```
AND(
  RecordType.DeveloperName = "Provider_Objection",
  OR(ISPICKVAL(Status, "Resolved"), ISPICKVAL(Status, "Closed - No Action"), ISPICKVAL(Status, "Closed")),
  NOT($Profile.Name = "System Administrator"),
  OR(
    ISPICKVAL(Resolution__c, ""),
    AND(ISBLANK(Resolution_Notes__c), NOT(ISPICKVAL(Resolution__c, "Logged in Error")))
  )
)
```

**Impact on Log a Visit:** none at insert. Cases are created as New. Validation rules fire in system mode too.

### 1.3 Permission set "PRM Objection Case User"

| Item | Expected | Found | Match? | Notes |
|---|---|---|---|---|
| Permission set | Exists | `PRM_Objection_Case_User` (`0PSdy000000s4MnGAI`) | ✅ | **Not in the repo** (see §3.6). |
| Object access | Case Read/Create/Edit, no Delete | Read ✔ Create ✔ Edit ✔ Delete ✘ | ✅ | ⚠️ **PRM User** and **PRM Manager** profiles grant Case **Delete + View All + Modify All**, so Florida liaisons can still delete. In Hunter these profiles are the only effective delete source for PRM users. `Read_PRM_Team`, `PRMUser2` and `TESTPRMUserProfile` also grant Delete but have no active assignees in Hunter; check prod before go-live. |
| Record type | Provider Objection | `Case.Provider_Objection` visible | ✅ | |
| Field access | All objection fields | **Edit:** `AccountId`, `ContactId`, `Description`, `Objection_Category__c`, `Resolution__c`, `Resolution_Notes__c`, `Subject`, `Visit_Report__c`. **Read-only:** `Origin`, `Region__c`, `Visit_Date__c`. **None:** `Facility__c`, `Objection__c`, `Priority`, `Type`, `Reason` | ⚠️ | If Q2 puts the facility in `Facility__c`, the set needs Read on it. Edit too, if liaisons may correct it. |
| Group assignment | PRM Standard User, BH PRM User, BH PRM Manager | In all three. Active assignees: `PRM_Standard_User` 22, `BH_PRM_User` 3 (Joni Ayers, Virginia Sherrell, Kara Neloms), `BH_PRM_Manager` 1 (Mark Shear, **PRM Manager profile**) | ✅ | |
| Network Team has no access | No access | No Case object permission, RT not visible, not in the groups | ✅ | Matches decision 12. View access is an optional, unapproved item in the design document. |
| Default record type | Not yet default on PRM profiles | **PRM User**: visible + default ✔. **PRM Manager**: visible + default ✔. **BH PRM User**: not visible on the profile (permission set only), so no default | ❌ (differs from brief) | Remaining: the BH PRM User profile only. The flow sets `RecordTypeId` itself. |

**Can the Log a Visit running user write each field the flow needs?** (Profile and permission set FLS combined.)

| Case field | Florida (PRM User / PRM Manager) | Alabama (BH PRM User) | Set by flow? |
|---|---|---|---|
| `RecordTypeId` | ✔ | ✔ | Yes |
| `Origin` | ✔ | **✘ read-only** | Yes |
| `Region__c` | **✘ read-only** | **✘ read-only** | Yes |
| `Objection_Category__c`, `AccountId`, `ContactId`, `Subject`, `Description`, `Visit_Report__c` | ✔ | ✔ | Yes |
| `Status`, `OwnerId` | ✔ | ✔ | Yes |
| `Facility__c` | ✔ (profile) | **✘ no FLS** | Only if Q2 = practice + facility |
| `Priority`, `Objection__c` | ✔ | ✘ | No |

**Conclusion:** a user-mode Case insert fails for every PRM user on `Region__c`, and for Alabama users also on `Origin`.

### 1.4 Field history tracking (Case)

| Item | Expected | Found | Match? | Notes |
|---|---|---|---|---|
| Tracked fields | 13 of 20 | **14**: `ContactId`, `AccountId`, `Type`, `RecordTypeId`, `Status`, `Origin`, `Subject`, `Priority`, `Description`, `OwnerId`, `Resolution_Notes__c`, `Resolution__c`, `Objection_Category__c`, `Region__c` | ⚠️ count | Probably the same set counted with or without `RecordTypeId`. `OwnerId` and `Status` being tracked supports the design's "time to resolve" and "by owner" reporting. |
| Object-level flag | On | `EntityDefinition.IsFieldHistoryTracked` = **false** for Case | ❓ | Confirm in Setup (Q10). |

### 1.5 Other Case automation

- No Apex triggers on Case, Visit_Report__c, Visit_Objection__c or Task.
- No record-triggered flows on Case.
- No Case assignment rules.
- No Case duplicate rules.
- Case sharing: Public Read/Write/Transfer, which satisfies decisions 3–4 for anyone with Case access.
- Hunter data: 0 Cases, 3 Visit Objections, and 7 active providers (3 Alabama, 4 Florida). Facility accounts exist under both Orlando Health and Baptist Health Main.

---

## Step 2 — Current Log a Visit process

### 2.1 Everything behind "Log a Visit"

| Component | Type | Status | Role in Phase 1 |
|---|---|---|---|
| `Contact.Log_a_Visit_OH`, `Contact.Log_a_Visit_BH`, `Contact.Log_a_Visit_TesT` | Quick actions | On the PRM, BH, mobile and admin provider pages | All launch **`Provider_SCR_LogVisitReport_Refined`** |
| **`Provider_SCR_LogVisitReport_Refined`** | Screen flow, API 64.0 | Active; last modified by Sai Pandrangi 2026-10-01; repo copy identical to Hunter | **Changed by this ticket** |
| `Provider_SCR_LogVisitReport_OH` / `_BH` | Screen flows | Obsolete | Ignore |
| `Contact.Log_a_Visit_Flow` → `Provider_SCR_LogVisitReport` | Legacy screen flow | Active (2024) | No objection capture; out of scope |
| `Account.Log_a_Visit` → `Practice_Group_Network_Log_Visit_Report` | Network screen flow | Active | **Unchanged** (decision 12) |
| `Visit_Objection_SCR_GroupIntoCase`, `Visit_Objection_RT_MaintainCaseRollups`, queue `PRM_Objection_Triage`, list views *Ungrouped Objections* / *Open Objection Issues* / *PRM Objection Triage* | Grouping layer (2026-10-02/07) | Hunter only | **Superseded**; retire (§3.3) |
| `CR_FieldAssistant.saveVisit` + `fieldVisitAssistant` LWC (PRM utility bar) | Apex, `with sharing` | Current branch | **Second logging path.** Inserts `Visit_Objection__c`. Fails once PRM users lose Create on it (R7) |
| `providerObjectionSummary` / `ProviderObjectionSummaryController` (provider Objections tab), `CR_VisitActivityObjectionFactBatch` (Vital Reports fact), Visit Objection reports and dashboards, data warehouse feed | Reporting | Prod | **Other Phase 1 tickets.** They must read Cases as well as history |

### 2.2 How objections are captured today (Refined flow)

Objections are stored as **`Visit_Objection__c`** child records of `Visit_Report__c`, one per category selected.

1. **Start.** `Determine_BH_or_OH_Route` uses `fB_IsBHFacilityByProfile = CONTAINS($Profile.Name, "BH")`. Then `Get_Provider_Record` (Contact = `recordId`), then `Get_Provider_Practice_Group` (Account = `Contact.AccountId`).
2. **Screens S02–S07.** Visit type, location, additional providers, visit details (date `fD_DateofMeetingCall`, audience, subject…), services, and collateral (BH only).
3. **`Which_Objections_Catalog`.** `Get_OH_Objections` / `Get_BH_Objections` (`Objection__c` where `Active__c` and the market flag) → `vC_Objections`.
4. **S08 Objections Raised.**
   - Yes / No (`S08_RB01_ObjectionsRaised`).
   - **One facility picker**, `S08_CL01_Facility` (`rcs_OH_Facilities`: Accounts under `$Label.OrlandoHealthAccountId` / `$Label.BaptistHealthAccountId`, chosen by profile).
   - A **multi-select datatable** `S08_DT01_ObjectionsRaised` with columns **Name** and **Description** (`Description__c`, currently blank). Minimum 1 row.
5. **Loop `Add_Objection_Notes`** over the selected rows, one pass per category:
   - Screen **S09** shows "Selected Objection: {Name}" and a required note, `S09_LT01_ObjectionNotes`.
   - `Assign_Objection_Visit_Variables` sets `Objection__c`, `Notes__c` and `Facility__c`.
   - The record is added to `vR_VisitObjectionsNotes`.
6. **S10 Comments**, then `Create_Visit_Report`, then services and collateral.
7. **Objection save.** `Any_Objections_Selected`, then loop `Add_Visit_Report_Id_to_Objections`, which stamps `Visit_Report__c`, `Provider__c` and `Practice_Group__c`. `Facility__c` carries over from step 5 in the reused variable. The loop ends at **`Create_Visit_Objections`**, a single DML.
8. **Finish.** Visit Task, TaskRelations, the physician-to-physician task, then the S11 confirmation.
9. **Faults.**
   - Saves fault to `S11_Error_Saving_Visit` (*"This visit could not be saved. Nothing was recorded…"* + `{!$Flow.FaultMessage}`).
   - There is **no Roll Back Records** element, so already-saved records stay. This is the design document's "partial saves".
   - Lookups fault to `S12_Error_Loading_Data`, which emails the admin.
   - Back is enabled on every screen except the confirmation.

### 2.3 Where each Case value comes from

| Value | Source in the flow | Available after |
|---|---|---|
| Provider | `Get_Provider_Record` (Contact); name `Get_Provider_Record.Name` | Start |
| Provider region | `Get_Provider_Record.Region__c` (Alabama / Florida) | Start |
| Practice (provider's practice group) | `Get_Provider_Practice_Group.Id` | Start |
| Facility | `S08_CL01_Facility.selectedChoiceValues`; label `.selectedChoiceLabels` | S08 |
| Category | `Add_Objection_Notes.Name` | S09 loop |
| Note | `S09_LT01_ObjectionNotes` | S09 loop |
| Visit Report | `vR_VisitReport.Id` | `Create_Visit_Report` |
| Visit Date | `fD_DateofMeetingCall` → `Visit_Report__c.Visit_Date__c` → Case formula | `Create_Visit_Report` |
| Logger (owner) | `$User.Id` | Any time |

### 2.4 Run context

- `runInMode` is not set, so the flow runs in **user context**: CRUD and FLS are enforced on every data element.
- A direct Case insert fails on `Region__c` for everyone, and on `Origin` for Alabama.
- The validation rule does not affect inserts.
- Sharing allows the logger to own the Case and anyone in PRM to reassign it.
- **Recommendation:** keep the parent flow in user mode and do the Case insert in an autolaunched subflow set to **System Context with Sharing** (§3.2). The subflow still runs as the liaison, so the default owner and Created By are the liaison.

---

## Step 3 — Implementation plan

### 3.1 Field mapping (one Case per selected category: decision 10)

| Case field (API) | Source in flow | Notes |
|---|---|---|
| `RecordTypeId` | `Get_Objection_Case_Record_Type.Id`: RecordType where `SobjectType = 'Case'` AND `DeveloperName = 'Provider_Objection'` | No hardcoded Id. |
| `Origin` | `Log A Visit` | Explicit; the master Origin list has no default. |
| `Status` | `New` | Per the design's future-state process. Depends on the **pending status-list decision**. |
| `OwnerId` | `$User.Id` | The liaison who logged it (decision 10). Anyone in PRM can then reassign. |
| `Objection_Category__c` | `Add_Objection_Notes.Name` | Restricted picklist; the 7 names match. A future catalog rename must change both (R5). |
| `Region__c` | `Get_Provider_Record.Region__c` | Decision 8. If the provider's Region is blank the Case Region stays blank; reports should flag it (Q4). |
| `ContactId` (Provider) | `Get_Provider_Record.Id` | Shows on the provider's Cases list and the new Objections tab. |
| `AccountId` (Practice & Group) | **As built by Eyad:** `S08_CL01_Facility.selectedChoiceValues` (the facility). **Per the design document:** `Get_Provider_Practice_Group.Id` (the practice) | Decided by Q2. |
| `Facility__c` | Only if Q2 = "practice and facility": `S08_CL01_Facility.selectedChoiceValues`, and put the field back on the layout and in the permission set | Hidden today. |
| `Visit_Report__c` | `vR_VisitReport.Id` | |
| `Visit_Date__c` | — (formula) | |
| `Subject` | `fT_ObjectionCaseSubject` = `LEFT({!Add_Objection_Notes.Name} & " - " & {!Get_Provider_Record.Name} & " - " & {!S08_CL01_Facility.selectedChoiceLabels}, 255)` | For example `Insurance - Jane Doe, MD - Orlando Health Winnie Palmer Hospital for Women & Babies` (Q5). |
| `Description` | `S09_LT01_ObjectionNotes` | The liaison's note (decision 6). |
| `Priority`, `Type`, `Reason`, `Objection__c` | not set | Severity and service line come in Phase 2. |

### 3.2 Flow changes

**New flow `Case_AL_CreateObjectionCases`** (autolaunched, **System Context with Sharing**):

- One input/output Case collection, `vC_Cases`, and one Create Records element.
- No fault handling inside the subflow; errors pass up to the parent.
- **First build step:** prove the run mode is honoured when called from the user-mode screen flow, by logging an objection as an Alabama user in Hunter. Fallbacks: a small invocable Apex method (`with sharing`; Apex DML does not enforce FLS unless asked to), or making `Region__c`/`Origin` editable in the permission set and read-only on the layout. The second means editing Eyad's set as a full file.

**Changes to `Provider_SCR_LogVisitReport_Refined`:**

1. **New resources:** `vR_ObjectionCase` (Case), `vC_ObjectionCaseDrafts` (Case collection), `vC_ObjectionCases` (Case collection), formula `fT_ObjectionCaseSubject`.
2. **Reset before the S09 loop.** On the Yes outcome of `Were_Objections_Raised`, clear `vC_ObjectionCaseDrafts`. Going Back to S08 and forward then cannot append the same categories twice.
3. **Inside the S09 loop**, add `Assign_Objection_Case_Draft` after S09. Set `Objection_Category__c`, `Description` and `Subject`, then add the record to `vC_ObjectionCaseDrafts`. The existing `Assign_Objection_Visit_Variables` / `Assign_Visit_Objection_to_Collection` pair is removed (step 5).
4. **After `Create_Visit_Report`**, on the Yes path of `Any_Objections_Selected`:
   - `Get_Objection_Case_Record_Type` (fault → rollback).
   - Loop `Stamp_Objection_Cases` over `vC_ObjectionCaseDrafts`:
     - Decision `Category_Already_Added`, backed by a Collection Filter on `vC_ObjectionCases` where `Objection_Category__c` equals the current item. This catches Back from S10 into the last S09 pass.
     - If the category is new, `Assign_Objection_Case_Visit_Fields` sets `RecordTypeId`, `Origin`, `Status`, `OwnerId`, `Region__c`, `ContactId`, `AccountId`, `Facility__c` (if used) and `Visit_Report__c`, then adds the record to `vC_ObjectionCases`.
   - **Subflow `Create_Objection_Cases`** → `Case_AL_CreateObjectionCases`. One DML, outside all loops. Fault → rollback.
   - Continue to `Get_Visit_Task_Record_Type_Id` as today.

   If decision 10 becomes "one Case per visit", only this loop changes: build one Case and combine the categories and notes into its Description, or use child Cases in Phase 2.
5. **Remove the `Visit_Objection__c` creation** from this flow: loop `Add_Visit_Report_Id_to_Objections`, `Assign_Visit_Id_to_Visit_Objection`, `Add_Complete_Visit_Objection_to_Collection` and `Create_Visit_Objections`, plus their variables (decisions 1, 13). The objection summary in the Task's visit-details HTML (`tt_ObjectionFacility`, `tt_Objections`) stays, so the activity timeline still shows what was raised.
6. **Fault handling.** Add **Roll Back Records** (`Roll_Back_Visit`) in front of `S11_Error_Saving_Visit` on every save-phase fault: Visit Report, services, collateral, record-type lookup, Cases subflow, Task, task relations, physician-to-physician task. S11's "Nothing was recorded" then becomes true. Keep Back on S11 so the liaison can retry.
7. **S09 screen** (subject to the pending "note per category" decision; suggested: keep):
   - A one-line prompt, for example *"What did the provider raise? Add the detail for this category."*
   - A visible warning: *"Do not include patient information."*
   - Optionally, show the category's definition under the title (`Add_Objection_Notes.Description__c`).
8. **Category definitions: data, not metadata.** Load the design document's 7 definitions into `Objection__c.Description__c` in Hunter, UAT and prod. The S08 datatable already shows that column. Prod data loads go through release management, never from this workspace. The definitions are long paragraphs and the column wraps text, so check S08 on mobile.

The rep sees the same screens in the same order. The confirmation screen can optionally say "N objection case(s) created".

### 3.3 Existing objection capture: **replace** (decided by the design document)

The first draft compared parallel, linked and replace options. Decisions 1, 12 and 13 settle it:

| Area | Change at go-live | Owner |
|---|---|---|
| Log a Visit (Refined flow) | Creates Cases; no longer creates `Visit_Objection__c` | **This ticket** |
| `Visit_Objection__c` access for PRM | Read-only history: remove Create/Edit/Delete from the PRM User and PRM Manager profiles (both have CRED) and from `Persona_BH_PRM_User` (Create/Edit). Network Team keeps Create/Edit. Admins unchanged. | This ticket or the access ticket. The permission-set change must be a full-file deploy |
| Grouping layer (Group Into Issue, rollups flow, triage queue, Ungrouped / Open Objection Issues / PRM Objection Triage list views, Case `Report_Count__c` / `First_Reported__c` / `Last_Reported__c`, `Objection__c` theme) | **Superseded.** Owner is now the logger, and grouping moves to Phase 2 as parent and child Cases. It is Hunter- and branch-only, so it is simply **not promoted**. Deactivate the two flows in Hunter so they don't confuse UAT testing. | This ticket |
| Field Visit Assistant (`CR_FieldAssistant.saveVisit`) | Must create Cases instead of `Visit_Objection__c` in the same release, or drop objection capture. Otherwise its saves fail once PRM loses Create. | Separate ticket, same release |
| Provider Objections tab (`providerObjectionSummary`), 5 reports, 2 dashboards, Vital Reports (`CR_VisitActivityObjectionFactBatch` → `Fact_VisitActivityObjection__c`), data warehouse feed | Read Cases (Origin = Log A Visit, RT Provider Objection) **plus** the read-only `Visit_Objection__c` history | Separate Phase 1 tickets, same release |
| Network flow | Unchanged | — |

The memory note recording the 2026-10-02 weekly-grouping decision is now out of date and has been marked superseded.

### 3.4 Risks and gaps

| # | Risk / gap | Impact | Mitigation |
|---|---|---|---|
| R1 | **Alabama has no Case access in prod** (design: "certain unless fixed") | Alabama visits with objections cannot save | Ship `PRM_Objection_Case_User` and its groups in the same release. Add Provider Objection visible + default to the **BH PRM User profile** (profile deploys merge, so this is safe). Test as Joni Ayers / Virginia Sherrell / Kara Neloms in UAT. |
| R2 | User-mode flow cannot write `Region__c` (everyone) or `Origin` (Alabama) | Every objection save fails | System-mode subflow; fallbacks in §3.2. |
| R3 | No rollback today | Partial visits while S11 says "Nothing was recorded" | Roll Back Records on every save fault. |
| R4 | Back navigation re-adds categories | Duplicate Cases | Reset before the loop + dedupe by category (§3.2 steps 2 and 4). |
| R5 | `Objection_Category__c` is restricted and copies `Objection__c` names | A renamed or added catalog row makes the save fail and the whole visit roll back | Note the coupling in both descriptions. Change both together. Covered by test T7. |
| R6 | Provider Region blank | Case Region blank; region reports undercount | All 7 Hunter providers have it. Check blanks in UAT with `SELECT COUNT() FROM Contact WHERE Region__c = null AND Active__c = true` (Q4). |
| R7 | Field Visit Assistant writes `Visit_Objection__c` | Breaks when PRM loses Create on it | Same-release ticket (§3.3). |
| R8 | Case **Delete** for liaisons comes from the **PRM User profile** (also PRM Manager; `Read_PRM_Team` / `PRMUser2` / `TESTPRMUserProfile` if assigned in prod) | Decision 11 not enforced | Remove Delete (and Modify All, which implies delete) from PRM User. PRM Manager waits on the "Delete rights for managers" decision. Check prod assignments of the three permission sets. |
| R9 | Status list and closing requirements not approved | Status and closing rule may change after build | Build with New. The flow sets only the opening status, so later changes touch the support process and validation rule, not the flow. |
| R10 | Reporting gap at go-live (design: "High if missed") | Objection numbers drop | Go live at a quarter boundary together with the reporting tickets (§3.3). |
| R11 | Decision 10 may flip to one Case per visit | Rework | The Case-building loop is self-contained (§3.2 step 4). |
| R12 | Eyad's foundation is not in the repo, UAT or prod | Deploy-order dependency | Retrieve it into the issue branch first (§3.6). |
| R13 | Network Team has no Case access | None for this ticket (decision 12) | The Network flow is untouched. |

### 3.5 Test plan

**Hunter (build checks):**
- Hunter has 3 Alabama and 4 Florida providers, plus facilities under both health systems.
- Its Orlando Health hierarchy, `OrlandoHealthAccountId` label and `Visit_Objection__c.Facility__c` lookup filter are Hunter-only overrides. Don't deploy the repo's CustomLabels or that field over them.

**UAT (sign-off):**
- With Kim Solomon, Amy Hodge and liaisons, as the design document specifies.
- UAT is a full prod copy with matching user Ids.

**Users:**
- **Florida:** a PRM User liaison.
- **Alabama:** a BH PRM User liaison.
- **Cross-market:** Mark Shear (PRM Manager profile + BH group).
- **Managers:** a PRM Manager.
- **Negative:** a Network Team user.

| # | Scenario | User | Expected |
|---|---|---|---|
| T1 | One category | FL liaison | 1 Case, **no** new `Visit_Objection__c`. RT Provider Objection, Origin Log A Visit, Status New, **Owner = the liaison**, Region = provider's region, Provider, Practice/Facility per Q2, Visit Report, Visit Date, Subject, Description = note |
| T2 | Three categories | FL liaison | 3 Cases with their own notes; one Case insert (debug log) |
| T3 | No objections | FL liaison | Visit saved as today; 0 Cases |
| T4 | One category | **AL liaison** | Case created with Region **Alabama**, a BH facility, Origin set (proves the system-mode subflow) |
| T5 | Several categories | AL liaison | As T2 |
| T6 | Region from the provider | FL liaison on an **Alabama** provider; Mark Shear on an Alabama provider | Region = Alabama in both (decision 8) |
| T7 | Save failure (for example, temporarily deactivate one category value in Hunter) | FL liaison | S11 shows the error; **nothing** remains (no Visit Report, Task or Case). Fix, go Back, resubmit, and it succeeds |
| T8 | Back navigation: S10 → S09 → Next; S09 → S08 → change selection → forward | FL and AL | No duplicate Cases; Cases match the final selection |
| T9 | Lookup failure before save | — | S12 shown, admin email sent, nothing saved |
| T10 | Work any objection | FL liaison edits and reassigns an AL liaison's Case, and the reverse | Allowed (decisions 3–4); history records Owner and Status |
| T11 | Delete | FL and AL liaisons | **Blocked** (decision 11); manager per decision |
| T12 | Close | Liaison and manager | Blocked without Resolution or Notes; "Logged in Error" closes without notes (per final rule); admin exempt |
| T13 | Logging screen | FL and AL | S08 shows the 7 categories with definitions; S09 shows the prompt and the no-PHI warning |
| T14 | Old objections | FL liaison | Existing `Visit_Objection__c` records are read-only; edit and delete are blocked |
| T15 | Network Team | Network user, Account › Log a Visit | Unchanged; still creates `Visit_Objection__c`; no error |
| T16 | Visibility | FL, AL | Case on the provider page (Objections tab per the reporting ticket, plus the Cases list), on the facility or practice Account, and in Case list views and reports |
| T17 | Mobile | AL liaison | As T4 in the Salesforce mobile app |

### 3.6 Deployment notes

**Components changed by this ticket:**
- `Flow: Provider_SCR_LogVisitReport_Refined` (new version).
- `Flow: Case_AL_CreateObjectionCases` (new).
- `Profile: PRM User`: Case Delete and Modify All off; `Visit_Objection__c` read-only.
- `Profile: PRM Manager`: `Visit_Objection__c` read-only; Case Delete per the manager decision.
- `Profile: BH PRM User`: Provider Objection visible + default.
- `PermissionSet: Persona_BH_PRM_User`: `Visit_Objection__c` read-only. **Full file only**; partial permission-set deploys wipe the set. Dry-run and compare the counts.
- If Q2 = practice + facility: `Case-Case Layout` (add `Facility__c`) and `PermissionSet: PRM_Objection_Case_User` (`Facility__c` Read). The permission set is again a full-file deploy.
- In Hunter only: deactivate `Visit_Objection_SCR_GroupIntoCase` and `Visit_Objection_RT_MaintainCaseRollups`.

**Data** (each org, through release management for prod):
- 7 `Objection__c.Description__c` definitions.

**Dependencies:**
1. Kim's approval of the status list and the closing requirements (blocks the build).
2. Eyad's foundation in the repo: Case fields `Objection_Category__c`, `Region__c`, `Visit_Report__c`, `Visit_Date__c`, `Resolution__c`; the Origin value; the record type and business process; `Resolution_Required`; `Case-Case Layout`; history settings; `PRM_Objection_Case_User` and its 3 groups.
3. Eyad's remaining items (Q1).
4. The reporting and Field Visit Assistant tickets, shipped in the same release.

**Order:**
1. Create the issue branch `feature/log-a-visit-objection-cases` from `main`. The grouping build on `feature/field-visit-assistant` is **not** merged in.
2. Retrieve Eyad's foundation into the branch.
3. Build in Hunter and run the build checks.
4. Deploy to UAT and run T1–T17 with the PRM team.
5. Train liaisons and brief leadership.
6. Prod deploy by release management at the go-live quarter boundary, then two weeks of daily checks and a 30-day adoption check (design document).

**Rollback:** reactivate the previous Refined flow version and restore PRM Create on `Visit_Objection__c`. The Cases already created remain.

---

## Step 4 — Open questions

**Answered by the design document:** Case owner (the logger), initial status (New), region source (provider), what happens to `Visit_Objection__c` (replaced; history read-only), the weekly grouping (superseded by Phase 2), and the Network Team (keeps today's logging).

| # | Question | For |
|---|---|---|
| Q1 | What are Eyad's remaining "1.7" items? In Hunter the default record type is already set on PRM User and PRM Manager; only BH PRM User remains. | Eyad |
| Q2 | **Practice vs facility.** The design document says the Case carries *practice and facility*. Eyad's 10/16 build puts the facility in Practice & Group (`AccountId`) and hides `Facility__c`. Which is intended? Recommendation: `AccountId` = the provider's practice group and `Facility__c` = the selected facility (unhidden), so "by facility" and "by practice" reports both work. | Eyad / Kim |
| Q3 | **Status list** and **what must be recorded before closing.** These block the build. Is the Hunter set (New, Triage, In Progress, On Hold, Escalated, Resolved, Closed - No Action) and the current rule the baseline? | Kim (Amy) |
| Q4 | If a provider has no Region, leave the Case Region blank or fall back to the liaison's market? | Kim |
| Q5 | Is the Subject format `<Category> - <Provider> - <Facility>` acceptable? | Kim |
| Q6 | Decision 11 names one value, "Logged in error / duplicate". Resolution has two ("Logged in Error", "Duplicate"). Merge them or keep both? Only "Logged in Error" is exempt from notes. | Kim / Eyad |
| Q7 | Do managers keep Case Delete? This decides the PRM Manager profile change. | Kim / Mark |
| Q8 | Field Visit Assistant: create Cases, or remove objection capture from it for Phase 1? | Product owner |
| Q9 | The design document's "Log Objection" button for objections raised outside a visit: optional. In or out of Phase 1? (It would reuse `Case_AL_CreateObjectionCases`.) | Kim |
| Q10 | Field history: 13 vs 14 fields, and the object-level flag reads false through the API. Confirm in Setup. | Eyad |
| Q11 | Note per category (suggested) or one per visit? This affects S09 and decision 10. | Kim |
| Q12 | Go-live date: 2027-01-04 suggested. The flow change, access changes, reporting, Vital Reports and data warehouse updates all switch together. | Kim / Mark |
| Q13 | Does prod assign `Read_PRM_Team`, `PRMUser2` or `TESTPRMUserProfile` to liaisons? Any of them would still grant Case Delete. | Eyad |
