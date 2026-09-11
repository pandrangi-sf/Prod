var app = angular.module('event', []);

var __indexOf = [].indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

app.factory('eventFactory', function($http) {
	var eventFactory = {
		getEvents : function() {
			var url = 'https://orlandohealthgyn.secure.force.com/GetEventsPage?eventCategory=Bariatric%20Info%20Session&callback=JSON_CALLBACK&';
			var promise = $http.jsonp(url).then(function(response) {
				return response.data;
			});
			return promise;
		}
	};
	return eventFactory;
});		

app.directive('chosen', [
  '$timeout', function($timeout) {
    var CHOSEN_OPTION_WHITELIST, NG_OPTIONS_REGEXP, isEmpty, snakeCase;
    NG_OPTIONS_REGEXP = /^\s*(.*?)(?:\s+as\s+(.*?))?(?:\s+group\s+by\s+(.*))?\s+for\s+(?:([\$\w][\$\w]*)|(?:\(\s*([\$\w][\$\w]*)\s*,\s*([\$\w][\$\w]*)\s*\)))\s+in\s+(.*?)(?:\s+track\s+by\s+(.*?))?$/;
    CHOSEN_OPTION_WHITELIST = ['noResultsText', 'allowSingleDeselect', 'disableSearchThreshold', 'disableSearch', 'enableSplitWordSearch', 'inheritSelectClasses', 'maxSelectedOptions', 'placeholderTextMultiple', 'placeholderTextSingle', 'searchContains', 'singleBackstrokeDelete', 'displayDisabledOptions', 'displaySelectedOptions', 'width'];
    snakeCase = function(input) {
      return input.replace(/[A-Z]/g, function($1) {
        return "_" + ($1.toLowerCase());
      });
    };
    isEmpty = function(value) {
      var key;
      if (angular.isArray(value)) {
        return value.length === 0;
      } else if (angular.isObject(value)) {
        for (key in value) {
          if (value.hasOwnProperty(key)) {
            return false;
          }
        }
      }
      return true;
    };
    return {
      restrict: 'A',
      require: '?ngModel',
      terminal: true,
      link: function(scope, element, attr, ngModel) {
        var chosen, defaultText, disableWithMessage, empty, initOrUpdate, match, options, origRender, removeEmptyMessage, startLoading, stopLoading, valuesExpr, viewWatch;
        element.addClass('localytics-chosen');
        options = scope.$eval(attr.chosen) || {};
        angular.forEach(attr, function(value, key) {
          if (__indexOf.call(CHOSEN_OPTION_WHITELIST, key) >= 0) {
            return options[snakeCase(key)] = scope.$eval(value);
          }
        });
        startLoading = function() {
          return element.addClass('loading').attr('disabled', true).trigger('chosen:updated');
        };
        stopLoading = function() {
          return element.removeClass('loading').attr('disabled', false).trigger('chosen:updated');
        };
        chosen = null;
        defaultText = null;
        empty = false;
        initOrUpdate = function() {
          if (chosen) {
            return element.trigger('chosen:updated');
          } else {
            chosen = element.chosen(options).data('chosen');
            return defaultText = chosen.default_text;
          }
        };
        removeEmptyMessage = function() {
          empty = false;
          return element.attr('data-placeholder', defaultText);
        };
        disableWithMessage = function() {
          empty = true;
          return element.attr('data-placeholder', chosen.results_none_found).attr('disabled', true).trigger('chosen:updated');
        };
        if (ngModel) {
          origRender = ngModel.$render;
          ngModel.$render = function() {
            origRender();
            return initOrUpdate();
          };
          if (attr.multiple) {
            viewWatch = function() {
              return ngModel.$viewValue;
            };
            scope.$watch(viewWatch, ngModel.$render, true);
          }
        } else {
          initOrUpdate();
        }
        attr.$observe('disabled', function() {
          return element.trigger('chosen:updated');
        });
        if (attr.ngOptions && ngModel) {
          match = attr.ngOptions.match(NG_OPTIONS_REGEXP);
          valuesExpr = match[7];
          scope.$watchCollection(valuesExpr, function(newVal, oldVal) {
            var timer;
            return timer = $timeout(function() {
              if (angular.isUndefined(newVal)) {
                return startLoading();
              } else {
                if (empty) {
                  removeEmptyMessage();
                }
                stopLoading();
                if (isEmpty(newVal)) {
                  return disableWithMessage();
                }
              }
            });
          });
          return scope.$on('$destroy', function(event) {
            if (typeof timer !== "undefined" && timer !== null) {
              return $timeout.cancel(timer);
            }
          });
        }
      }
    };
  }
]);

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

function rootController($scope, $filter, eventFactory) {
	$scope.cityMap = {};
	$scope.cityArray = [];
	eventFactory.getEvents().then(function(d) {
		angular.forEach(d.EventInfo, function(event) {
			event.newDate = formatDate2(event.eventStartTime, event.eventEndTime);
			angular.forEach(d.EventLocations, function(location) {
				if (event.event.HC4__EventLocations__r) {
					if (location.Id == event.event.HC4__EventLocations__r.records[0].HC4__Location__c) {
						event.locationName = location.Name;
						event.newString = event.locationName + " - " + event.newDate;
						if (!$scope.cityMap[location.HC4__MailingCity__c]) {
							$scope.cityMap[location.HC4__MailingCity__c] = [];
							$scope.cityArray.push(location.HC4__MailingCity__c);
						}
						$scope.cityMap[location.HC4__MailingCity__c].push(event);
					}
				}
			});
		});
		$scope.allEvents = d.EventInfo;
		$scope.allLocations = d.EventLocations;
		$scope.theLocation = event.locationName;
		$scope.theStartDate = event.eventStartTime;
	});

}
