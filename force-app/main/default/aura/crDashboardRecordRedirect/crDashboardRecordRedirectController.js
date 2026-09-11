({
    doInit: function(component) {
        var recordId = component.get('v.recordId');
        var navService = component.find('navService');
        var pageReference = {
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'Custom_Dashboard_Viewer'
            },
            state: {}
        };

        if (recordId) {
            pageReference.state.c__dashboardId = recordId;
        }

        navService.navigate(pageReference, true);
    }
})