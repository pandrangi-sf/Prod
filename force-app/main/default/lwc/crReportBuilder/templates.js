// ─────────────────────────────────────────────────────────────────────────────
// SOURCE OF TRUTH WARNING — Phase 1 v2 allowlist
//
// The objects referenced by these templates (every `primaryObject` plus every
// object reachable via `fieldPaths`) form the framework's default allowlist.
// Apex mirrors them in `CR_AllowlistService.TEMPLATE_PRIMARY_OBJECTS` and
// `CR_AllowlistService.TEMPLATE_TRAVERSED_OBJECTS`.
//
// WHEN ADDING OR MODIFYING A TEMPLATE: update those Apex constants too.
// Phase 1.5 will move templates to a JSON static resource so both sides read
// one file. Until then, drifting these two will silently break the dataset /
// object pickers in fresh orgs.
// ─────────────────────────────────────────────────────────────────────────────

const OPP_DATASET = {
    datasetKey: 'Opportunity_Hybrid',
    mode: 'hybrid',
    objectApiName: 'Fact_Opportunity__c',
    primaryObject: 'Fact_Opportunity__c',
    relatedObjects: [],
    fieldPaths: []
};

const CASE_DATASET = {
    datasetKey: 'Case_Hybrid',
    mode: 'hybrid',
    objectApiName: 'Fact_Case__c',
    primaryObject: 'Fact_Case__c',
    relatedObjects: [],
    fieldPaths: []
};

const ACTIVITY_BASE_FIELD_LABELS = {
    'Activity_Id__c': 'Activity ID',
    'Subject__c': 'Subject',
    'Record_Type__c': 'Record Type',
    'Visit_Category__c': 'Visit Category',
    'Assigned_To__c': 'Assigned To',
    'Date_Of_Meeting__c': 'Date of Meeting/Call',
    'Provider_Id__c': 'Provider ID',
    'Provider_First_Name__c': 'Provider First Name',
    'Provider_Last_Name__c': 'Provider Last Name',
    'Provider_Full_Name__c': 'Provider Full Name',
    'Practice_Group_Name__c': 'Practice & Group Name',
    'Visit_Report_Number__c': 'Visit Report Number',
    'Activity_Created_Date__c': 'Activity Created Date',
    'Activity_Created_By__c': 'Activity Created By'
};

const VISIT_ACTIVITY_COLLATERAL_FIELD_PATHS = [
    'Activity_Id__c', 'Subject__c', 'Record_Type__c', 'Visit_Category__c',
    'Assigned_To__c', 'Date_Of_Meeting__c',
    'Provider_Id__c', 'Provider_First_Name__c', 'Provider_Last_Name__c', 'Provider_Full_Name__c',
    'Practice_Group_Name__c', 'Visit_Report_Number__c',
    'Activity_Created_Date__c', 'Activity_Created_By__c',
    'Collateral__c'
];
const VISIT_ACTIVITY_COLLATERAL_FIELD_LABELS = { ...ACTIVITY_BASE_FIELD_LABELS, 'Collateral__c': 'Collateral' };

const COLLATERAL_BY_LOCATION_FIELD_PATHS = [
    'Date_Of_Meeting__c', 'Assigned_To__c', 'Related_To__c',
    'Provider_Id__c', 'Provider_Full_Name__c',
    'Collateral__c', 'Visit_Report_Number__c'
];
const COLLATERAL_BY_LOCATION_FIELD_LABELS = {
    'Date_Of_Meeting__c': 'Date',
    'Assigned_To__c': 'PRM Rep',
    'Related_To__c': 'Location',
    'Provider_Id__c': 'Provider ID',
    'Provider_Full_Name__c': 'Provider Visited',
    'Collateral__c': 'Collateral',
    'Visit_Report_Number__c': 'Visit Report Number'
};

const VISIT_ACTIVITY_OBJECTION_FIELD_PATHS = [
    'Activity_Id__c', 'Subject__c', 'Record_Type__c', 'Visit_Category__c',
    'Assigned_To__c', 'Date_Of_Meeting__c',
    'Provider_Id__c', 'Provider_First_Name__c', 'Provider_Last_Name__c', 'Provider_Full_Name__c',
    'Practice_Group_Name__c', 'Visit_Report_Number__c',
    'Activity_Created_Date__c', 'Activity_Created_By__c',
    'Facility__c', 'Objection__c', 'Objection_Notes__c'
];
const VISIT_ACTIVITY_OBJECTION_FIELD_LABELS = {
    ...ACTIVITY_BASE_FIELD_LABELS,
    'Facility__c': 'Facility',
    'Objection__c': 'Objection',
    'Objection_Notes__c': 'Objection Notes'
};

const TARGET_COVERAGE_FIELD_PATHS = [
    'Target_Id__c', 'Target_Name__c', 'Territory_Name__c', 'PRM__c', 'Provider_NPI__c',
    'Provider_Id__c', 'Provider_Full_Name__c', 'Provider_Link__c',
    'Rank__c', 'Primary_Specialty__c', 'Practice_Group_Name__c',
    'Location_Id__c', 'Location_Name__c', 'Location_Address__c', 'City__c', 'State__c', 'Zip__c',
    'Alabama_Sub_Region__c'
];
const TARGET_COVERAGE_FIELD_LABELS = {
    'Target_Id__c': 'Target ID',
    'Target_Name__c': 'Target Name',
    'Territory_Name__c': 'Territory Name',
    'PRM__c': 'PRM',
    'Provider_NPI__c': 'Provider NPI',
    'Provider_Id__c': 'Provider ID',
    'Provider_Full_Name__c': 'Provider Full Name',
    'Provider_Link__c': 'Provider Link',
    'Rank__c': 'Rank',
    'Primary_Specialty__c': 'Primary Specialty',
    'Practice_Group_Name__c': 'Practice & Group Name',
    'Location_Id__c': 'Location ID',
    'Location_Name__c': 'Location Name',
    'Location_Address__c': 'Location Address',
    'City__c': 'City',
    'State__c': 'State',
    'Zip__c': 'Zip',
    'Alabama_Sub_Region__c': 'Alabama Sub-Region'
};

const UNZONED_TARGET_FIELD_PATHS = [
    'Target_Name__c', 'Region__c', 'Territory_Name__c', 'Owner_Name__c',
    'Target_Provider_Name__c', 'Sub_Region__c', 'Rank__c',
    'Last_Visit_Date__c', 'Last_Visit_Group__c', 'Days_Since_Last_Visit__c', 'Visits_Last_90_Days__c',
    'Target_Specialty__c', 'Target_Affiliation__c', 'Target_Practice__c',
    'Target_NPI__c', 'Target_Provider_Id__c',
    'Created_By__c', 'Created_Date__c', 'Target_Id__c'
];
const UNZONED_TARGET_FIELD_LABELS = {
    'Target_Name__c': 'Name',
    'Region__c': 'Region',
    'Territory_Name__c': 'Territory Name',
    'Owner_Name__c': 'Owner',
    'Target_Provider_Name__c': 'Target Provider Name',
    'Sub_Region__c': 'Sub Region',
    'Rank__c': 'Rank',
    'Last_Visit_Date__c': 'Last Visit Date',
    'Last_Visit_Group__c': 'Last Visit Group',
    'Days_Since_Last_Visit__c': 'Days Since Last Visit',
    'Visits_Last_90_Days__c': 'Visits Last 90 Days',
    'Target_Specialty__c': 'Target Specialty',
    'Target_Affiliation__c': 'Target Affiliation',
    'Target_Practice__c': 'Target Practice',
    'Target_NPI__c': 'Target NPI',
    'Target_Provider_Id__c': 'Target Provider',
    'Created_By__c': 'Created By',
    'Created_Date__c': 'Created Date',
    'Target_Id__c': 'Record ID'
};

const ZONED_LOCATION_GAP_FIELD_PATHS = [
    'ZonedLocation_Id__c', 'Owner_Name__c', 'Territory_Name__c', 'State__c',
    'Location_Name_Text__c', 'Location_City__c', 'Location_Zip__c',
    'Location_Practice_Group__c', 'Zone_Name__c',
    'Last_Visit_Date__c', 'Last_Visit_Group__c',
    'Days_Since_Last_Visit__c', 'Visits_Last_90_Days__c'
];
const ZONED_LOCATION_GAP_FIELD_LABELS = {
    'ZonedLocation_Id__c': 'Record ID',
    'Owner_Name__c': 'Owner',
    'Territory_Name__c': 'Territory Name',
    'State__c': 'State',
    'Location_Name_Text__c': 'Location Name Text',
    'Location_City__c': 'Location City',
    'Location_Zip__c': 'Location Zip',
    'Location_Practice_Group__c': 'Location Practice & Group',
    'Zone_Name__c': 'Zone Name',
    'Last_Visit_Date__c': 'Last Visit Date',
    'Last_Visit_Group__c': 'Last Visit Group',
    'Days_Since_Last_Visit__c': 'Days Since Last Visit',
    'Visits_Last_90_Days__c': 'Visits Last 90 Days'
};

const VISIT_ACTIVITY_SERVICE_FIELD_PATHS = [
    'Activity_Id__c',
    'Subject__c',
    'Record_Type__c',
    'Visit_Category__c',
    'Assigned_To__c',
    'Date_Of_Meeting__c',
    'Provider_Id__c',
    'Provider_First_Name__c',
    'Provider_Last_Name__c',
    'Provider_Full_Name__c',
    'Practice_Group_Name__c',
    'Visit_Report_Number__c',
    'Activity_Created_Date__c',
    'Activity_Created_By__c',
    'Service__c'
];

const VISIT_ACTIVITY_SERVICE_FIELD_LABELS = {
    'Activity_Id__c': 'Activity ID',
    'Subject__c': 'Subject',
    'Record_Type__c': 'Record Type',
    'Visit_Category__c': 'Visit Category',
    'Assigned_To__c': 'Assigned To',
    'Date_Of_Meeting__c': 'Date of Meeting/Call',
    'Provider_Id__c': 'Provider ID',
    'Provider_First_Name__c': 'Provider First Name',
    'Provider_Last_Name__c': 'Provider Last Name',
    'Provider_Full_Name__c': 'Provider Full Name',
    'Practice_Group_Name__c': 'Practice & Group Name',
    'Visit_Report_Number__c': 'Visit Report Number',
    'Activity_Created_Date__c': 'Activity Created Date',
    'Activity_Created_By__c': 'Activity Created By',
    'Service__c': 'Service'
};

const ACTIVITIES_VISITS_DATASET = {
    datasetKey: 'Task_AdHoc',
    mode: 'live',
    objectApiName: 'Task',
    primaryObject: 'Task',
    relatedObjects: ['TaskRelation', 'Visit_Report__c', 'Visit_Service__c'],
    fieldPaths: [
        'Task.Id',
        'Task.Subject',
        'Task.RecordType.Name',
        'Task.Visit_Category__c',
        'Task.Owner.Name',
        'Task.Date_Meeting_Call__c',
        'Task.Who.FirstName',
        'Task.Who.LastName',
        'Task.Account.Name',
        'Task.Visit_Report__r.Name',
        'Task.CreatedDate',
        'Task.CreatedBy.Name'
    ],
    fieldLabels: {
        'Task.Id': 'Activity ID',
        'Task.Subject': 'Subject',
        'Task.RecordType.Name': 'Record Type',
        'Task.Visit_Category__c': 'Visit Category',
        'Task.Owner.Name': 'Assigned To',
        'Task.Date_Meeting_Call__c': 'Date of Meeting/Call',
        'Task.Who.FirstName': 'First Name',
        'Task.Who.LastName': 'Last Name',
        'Task.Account.Name': 'Practice & Group Name',
        'Task.Visit_Report__r.Name': 'Visit Report Number',
        'Task.CreatedDate': 'Activity Created Date',
        'Task.CreatedBy.Name': 'Activity Created By'
    }
};

export const TEMPLATES = [
    {
        value: 'pipeline_by_stage',
        label: 'Pipeline by Stage',
        reportName: 'Pipeline by Stage',
        dataset: { ...OPP_DATASET, fieldPaths: ['Opportunity_Name__c', 'Amount__c', 'Stage_Name__c'] },
        filters: [],
        groupings: [{ field: 'Stage_Name__c' }],
        aggregations: [{ function: 'SUM', field: 'Amount__c' }, { function: 'COUNT' }],
        formulas: [],
        buckets: [],
        chartType: 'bar'
    },
    {
        value: 'won_by_owner',
        label: 'Won Opportunities by Owner',
        reportName: 'Won Opportunities by Owner',
        dataset: { ...OPP_DATASET, fieldPaths: ['Opportunity_Name__c', 'Amount__c', 'Stage_Name__c'] },
        filters: [{ field: 'Stage_Name__c', operator: '=', value: 'Closed Won' }],
        groupings: [{ field: 'Dim_Owner__c' }],
        aggregations: [{ function: 'SUM', field: 'Amount__c' }],
        formulas: [],
        buckets: [],
        chartType: 'pivot'
    },
    {
        value: 'cases_by_priority',
        label: 'Open Cases by Priority',
        reportName: 'Open Cases by Priority',
        dataset: { ...CASE_DATASET, fieldPaths: ['Case_Number__c', 'Status__c', 'Priority__c', 'Age_Days__c'] },
        filters: [{ field: 'Status__c', operator: '!=', value: 'Closed' }],
        groupings: [{ field: 'Priority__c' }],
        aggregations: [{ function: 'COUNT' }, { function: 'AVG', field: 'Age_Days__c' }],
        formulas: [],
        buckets: [],
        chartType: 'bar'
    },
    {
        value: 'activities_visits',
        label: 'Activities & Visits (Task, TaskRelation, Visit Report, Visit Service)',
        reportName: 'Activities & Visits',
        dataset: { ...ACTIVITIES_VISITS_DATASET },
        filters: [],
        groupings: [],
        aggregations: [],
        formulas: [],
        buckets: [],
        chartType: 'bar',
        startStep: 'filters'
    },
    {
        value: 'al_activities_with_services',
        label: 'Alabama — Activities with Services',
        reportName: 'Alabama Activities with Services',
        dataset: {
            datasetKey: 'Fact_VisitActivityService_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityService__c',
            primaryObject: 'Fact_VisitActivityService__c',
            relatedObjects: [],
            fieldPaths: VISIT_ACTIVITY_SERVICE_FIELD_PATHS,
            fieldLabels: VISIT_ACTIVITY_SERVICE_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Alabama' }],
        groupings: [],
        aggregations: [],
        formulas: [],
        buckets: [],
        chartType: 'bar',
        startStep: 'filters'
    },
    {
        value: 'fl_activities_with_services',
        label: 'Florida — Activities with Services',
        reportName: 'Florida Activities with Services',
        dataset: {
            datasetKey: 'Fact_VisitActivityService_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityService__c',
            primaryObject: 'Fact_VisitActivityService__c',
            relatedObjects: [],
            fieldPaths: VISIT_ACTIVITY_SERVICE_FIELD_PATHS,
            fieldLabels: VISIT_ACTIVITY_SERVICE_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Florida' }],
        groupings: [],
        aggregations: [],
        formulas: [],
        buckets: [],
        chartType: 'bar',
        startStep: 'filters'
    },
    {
        value: 'al_activities_with_collateral',
        label: 'Alabama — Activities with Collateral',
        reportName: 'Alabama Activities with Collateral',
        dataset: {
            datasetKey: 'Fact_VisitActivityCollateral_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityCollateral__c',
            primaryObject: 'Fact_VisitActivityCollateral__c',
            relatedObjects: [],
            fieldPaths: VISIT_ACTIVITY_COLLATERAL_FIELD_PATHS,
            fieldLabels: VISIT_ACTIVITY_COLLATERAL_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Alabama' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'fl_activities_with_collateral',
        label: 'Florida — Activities with Collateral',
        reportName: 'Florida Activities with Collateral',
        dataset: {
            datasetKey: 'Fact_VisitActivityCollateral_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityCollateral__c',
            primaryObject: 'Fact_VisitActivityCollateral__c',
            relatedObjects: [],
            fieldPaths: VISIT_ACTIVITY_COLLATERAL_FIELD_PATHS,
            fieldLabels: VISIT_ACTIVITY_COLLATERAL_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Florida' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'al_collateral_by_location',
        label: 'Alabama — Collateral by Location',
        reportName: 'Alabama Collateral by Location',
        dataset: {
            datasetKey: 'Fact_VisitActivityCollateral_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityCollateral__c',
            primaryObject: 'Fact_VisitActivityCollateral__c',
            relatedObjects: [],
            fieldPaths: COLLATERAL_BY_LOCATION_FIELD_PATHS,
            fieldLabels: COLLATERAL_BY_LOCATION_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Alabama' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'al_activities_with_objections',
        label: 'Alabama — Activities with Objections',
        reportName: 'Alabama Activities with Objections',
        dataset: {
            datasetKey: 'Fact_VisitActivityObjection_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityObjection__c',
            primaryObject: 'Fact_VisitActivityObjection__c',
            relatedObjects: [],
            fieldPaths: VISIT_ACTIVITY_OBJECTION_FIELD_PATHS,
            fieldLabels: VISIT_ACTIVITY_OBJECTION_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Alabama' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'fl_activities_with_objections',
        label: 'Florida — Activities with Objections',
        reportName: 'Florida Activities with Objections',
        dataset: {
            datasetKey: 'Fact_VisitActivityObjection_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_VisitActivityObjection__c',
            primaryObject: 'Fact_VisitActivityObjection__c',
            relatedObjects: [],
            fieldPaths: VISIT_ACTIVITY_OBJECTION_FIELD_PATHS,
            fieldLabels: VISIT_ACTIVITY_OBJECTION_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Florida' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'al_target_report',
        label: 'Alabama — Target Report (Coverage)',
        reportName: 'Alabama Target Report',
        dataset: {
            datasetKey: 'Fact_TargetCoverage_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_TargetCoverage__c',
            primaryObject: 'Fact_TargetCoverage__c',
            relatedObjects: [],
            fieldPaths: TARGET_COVERAGE_FIELD_PATHS,
            fieldLabels: TARGET_COVERAGE_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Alabama' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'fl_unzoned_targets',
        label: 'Florida Targets WithOut Zone Location',
        reportName: 'Florida Targets WithOut Zone Location',
        dataset: {
            datasetKey: 'Fact_UnzonedTarget_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_UnzonedTarget__c',
            primaryObject: 'Fact_UnzonedTarget__c',
            relatedObjects: [],
            fieldPaths: UNZONED_TARGET_FIELD_PATHS,
            fieldLabels: UNZONED_TARGET_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Florida' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'al_unzoned_targets',
        label: 'Alabama Targets WithOut Zone Locations',
        reportName: 'Alabama Targets WithOut Zone Locations',
        dataset: {
            datasetKey: 'Fact_UnzonedTarget_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_UnzonedTarget__c',
            primaryObject: 'Fact_UnzonedTarget__c',
            relatedObjects: [],
            fieldPaths: UNZONED_TARGET_FIELD_PATHS,
            fieldLabels: UNZONED_TARGET_FIELD_LABELS
        },
        filters: [{ field: 'Region__c', operator: '=', value: 'Alabama' }],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    },
    {
        value: 'zoned_location_gaps',
        label: 'Zoned Locations Without Targets',
        reportName: 'Zoned Locations Without Targets',
        dataset: {
            datasetKey: 'Fact_ZonedLocationGap_AdHoc',
            mode: 'live',
            objectApiName: 'Fact_ZonedLocationGap__c',
            primaryObject: 'Fact_ZonedLocationGap__c',
            relatedObjects: [],
            fieldPaths: ZONED_LOCATION_GAP_FIELD_PATHS,
            fieldLabels: ZONED_LOCATION_GAP_FIELD_LABELS
        },
        filters: [],
        groupings: [], aggregations: [], formulas: [], buckets: [],
        chartType: 'bar', startStep: 'filters'
    }
];