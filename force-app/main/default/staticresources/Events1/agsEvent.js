var app = angular.module('event', []);

function queryfy(lim, dys, cat) {
	params = {
		limit : lim,
		days : dys,
		eventCategory : cat,
		callback : "JSON_CALLBACK"

	};
	var str = $.param(params);
	return str;
}

app.factory('eventFactory', function($http) {
	var eventFactory = {
		getEvents : function(limit, days, category) {
			var url = 'https://orlandohealthgyn.secure.force.com/GetEventsPage?' + queryfy(limit, days, category);
			var promise = $http.jsonp(url).then(function(response) {
				return response.data;
			});
			return promise;
		}
	};
	return eventFactory;
});

app.directive('optionsDisabled', function($parse) {
	var disableOptions = function(scope, attr, element, data, fnDisableIfTrue) {
		// refresh the disabled options in the select element.
		var options = element.find("option");
		for (var pos = 0, index = 0; pos < options.length; pos++) {
			var elem = angular.element(options[pos]);
			if (elem.val() != "") {
				var locals = {};
				locals[attr] = data[index];
				elem.attr("disabled", fnDisableIfTrue(scope, locals));
				index++;
			}
		}
	};
	return {
		priority : 0,
		require : 'ngModel',
		link : function(scope, iElement, iAttrs, ctrl) {
			// parse expression and build array of disabled options
			var expElements = iAttrs.optionsDisabled.match(/^\s*(.+)\s+for\s+(.+)\s+in\s+(.+)?\s*/);
			var attrToWatch = expElements[3];
			var fnDisableIfTrue = $parse(expElements[1]);
			scope.$watch(attrToWatch, function(newValue, oldValue) {
				if (newValue)
					disableOptions(scope, expElements[2], iElement, newValue, fnDisableIfTrue);
			}, true);
			// handle model updates properly
			scope.$watch(iAttrs.ngModel, function(newValue, oldValue) {
				var disOptions = $parse(attrToWatch)(scope);
				if (newValue)
					disableOptions(scope, expElements[2], iElement, disOptions, fnDisableIfTrue);
			});
		}
	};
});

function formatTime(s) {
	if (s != null) {
		var a = s.split('T');
		a = a[1].split("-");
		a = a[0].substring(0, a[0].length - 9);
		var hours = a.split(":")[0];
		var minutes = a.split(":")[1];
		var ampm = hours >= 12 ? 'PM' : 'AM';
		hours = hours % 12;
		hours = hours ? hours : 12;
		// the hour '0' should be '12'
		var strTime = hours + ':' + minutes + ' ' + ampm;
		return strTime;
	} else {
		return null;
	}
}

function formatTime2(s) {
	if (s != null) {
		var a = s.split(' ');
		var strTime = a[1] + ' ' + a[2];
		return strTime;
	} else {
		return null;
	}
}

function formatDate(s) {
	if (s != null) {
		var a = s.split('T')[0];
		a = Date.parse(a);
		day = a.getDay();
		switch(day) {
			case 0:
				day = "Sun";
				break;
			case 1:
				day = "Mon";
				break;
			case 2:
				day = "Tue";
				break;
			case 3:
				day = "Wed";
				break;
			case 4:
				day = "Thu";
				break;
			case 5:
				day = "Fri";
				break;
			case 6:
				day = "Sat";
				break;
		}
		return day + ", " + (a.getMonth() + 1) + "/" + a.getDate() + "/" + a.getFullYear();
	} else {
		return null;
	}
}

function formatDate2(s, s2) {
	if (s != null) {
		var a = s.split(' ')[0];
		a = Date.parse(a);
		day = a.getDay();
		switch(day) {
			case 0:
				day = "Sunday";
				break;
			case 1:
				day = "Monday";
				break;
			case 2:
				day = "Tuesday";
				break;
			case 3:
				day = "Wednesday";
				break;
			case 4:
				day = "Thursday";
				break;
			case 5:
				day = "Friday";
				break;
			case 6:
				day = "Saturday";
				break;
		}
		month = (a.getMonth());
		switch(month) {
			case 0:
				month = "January";
				break;
			case 1:
				month = "February";
				break;
			case 2:
				month = "March";
				break;
			case 3:
				month = "April";
				break;
			case 4:
				month = "May";
				break;
			case 5:
				month = "June";
				break;
			case 6:
				month = "July";
				break;
			case 7:
				month = "August";
				break;
			case 8:
				month = "September";
				break;
			case 9:
				month = "October";
				break;
			case 10:
				month = "November";
				break;
			case 11:
				month = "December";
				break;
		}
		return day + ", " + month + " " + a.getDate() + ", " + s.split(' ')[1] + " " + s.split(' ')[2] + " - " + s2.split(' ')[1] + " " + s2.split(' ')[2];
	} else {
		return null;
	}
}

function formatDay(event) {
	var days = [];
	if (event.HC4__Sunday__c == true) {
		days.push("Sunday");
	}
	if (event.HC4__Monday__c == true) {
		days.push("Monday");
	}
	if (event.HC4__Tuesday__c == true) {
		days.push("Tuesday");
	}
	if (event.HC4__Wednesday__c == true) {
		days.push("Wednesday");
	}
	if (event.HC4__Thursday__c == true) {
		days.push("Thursday");
	}
	if (event.HC4__Friday__c == true) {
		days.push("Friday");
	}
	if (event.HC4__Saturday__c == true) {
		days.push("saturday");
	}
	return days;

}

if ( (typeof format == 'undefined') || format == false){
	formatName = function($scope, event, d) {
		angular.forEach(d.EventLocations, function(location) {
			if (event.event.HC4__EventLocations__r) {
				if (location.Id == event.event.HC4__EventLocations__r.records[0].HC4__Location__c) {
					event.locationName = location.Name;
					if (event.maxed)
						event.newString = "* " + event.locationName + " - " + event.newDate;
					else
						event.newString = event.locationName + " - " + event.newDate;
					if (!$scope.cityMap[location.HC4__MailingCity__c]) {
						$scope.cityMap[location.HC4__MailingCity__c] = [];
						$scope.cityArray.push(location.HC4__MailingCity__c);
					}
					$scope.cityMap[location.HC4__MailingCity__c].push(event);
				}
			}
		});
	};
	
} else {
	formatName = format;
}

function getEvents($scope, $filter, eventFactory, func) {
	eventFactory.getEvents($scope.limit, $scope.days, $scope.category).then(function(d) {
		angular.forEach(d.EventInfo, function(event) {
			event.newDate = formatDate2(event.eventStartTime, event.eventEndTime);
			formatName($scope, event, d);
		});
		$scope.allEvents = d.EventInfo;
		$scope.allLocations = d.EventLocations;
		$scope.theLocation = event.locationName;
		$scope.theStartDate = event.eventStartTime;
	});
}

function rootController($scope, $filter, eventFactory) {
	$scope.cityMap = {};
	$scope.cityArray = [];
	if ( typeof (limit) != "undefined")
		$scope.limit = limit;
	if ( typeof (days) != "undefined")
		$scope.days = days;
	if ( typeof (category) != "undefined")
		$scope.category = category;
	getEvents($scope, $filter, eventFactory);
}
