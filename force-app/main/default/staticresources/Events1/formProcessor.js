jQueryLoc = 'https://ajax.googleapis.com/ajax/libs/jquery/1.10.2/jquery.min.js'; 
wcLoc = 'https://demandconnect.s3.amazonaws.com/DemandConnect3.min.js';


if (typeof jQuery == 'undefined') {
	getScript(jQueryLoc, function(){
		loadProcessor();
	});
}else{
	loadProcessor();
}

if(typeof WebConnect == 'undefined'){
	getScript(wcLoc, function(){});
}


function getScript(url, success) {
	var script = document.createElement('script');
	    script.src = url;
	var head = document.getElementsByTagName('head')[0],
	done = false;
	// Attach handlers for all browsers
	script.onload = script.onreadystatechange = function() {
		if (!done && (!this.readyState || this.readyState == 'loaded' || this.readyState == 'complete')) {
			done = true;
			success();
			script.onload = script.onreadystatechange = null;
			head.removeChild(script);
		};
	};
		head.appendChild(script);
};

//all the code wrapped to be called after jquery is added to page if needed
function loadProcessor(){
	if (typeof jQuery == 'undefined') {
		document.write('<scr' + 'ipt type="text/javascript" src="'+jQueryLoc+'"></scr' + 'ipt>');
		setTimeout("loadProcessor()", 50);
	}

		/*!
		 * jQuery Validation Plugin 1.11.1
		 *
		 * http://bassistance.de/jquery-plugins/jquery-plugin-validation/
		 * http://docs.jquery.com/Plugins/Validation
		 *
		 * Copyright 2013 JÃ¶rn Zaefferer
		 * Released under the MIT license:
		 *   http://www.opensource.org/licenses/mit-license.php
		 */

		(function($) {

		$.extend($.fn, {
			// http://docs.jquery.com/Plugins/Validation/validate
			validate: function( options ) {

				// if nothing is selected, return nothing; can't chain anyway
				if ( !this.length ) {
					if ( options && options.debug && window.console ) {
						console.warn( "Nothing selected, can't validate, returning nothing." );
					}
					return;
				}

				// check if a validator for this form was already created
				var validator = $.data( this[0], "validator" );
				if ( validator ) {
					return validator;
				}

				// Add novalidate tag if HTML5.
				this.attr( "novalidate", "novalidate" );

				validator = new $.validator( options, this[0] );
				$.data( this[0], "validator", validator );

				if ( validator.settings.onsubmit ) {

					this.validateDelegate( ":submit", "click", function( event ) {
						if ( validator.settings.submitHandler ) {
							validator.submitButton = event.target;
						}
						// allow suppressing validation by adding a cancel class to the submit button
						if ( $(event.target).hasClass("cancel") ) {
							validator.cancelSubmit = true;
						}

						// allow suppressing validation by adding the html5 formnovalidate attribute to the submit button
						if ( $(event.target).attr("formnovalidate") !== undefined ) {
							validator.cancelSubmit = true;
						}
					});

					// validate the form on submit
					this.submit( function( event ) {
						if ( validator.settings.debug ) {
							// prevent form submit to be able to see console output
							event.preventDefault();
						}
						function handle() {
							var hidden;
							if ( validator.settings.submitHandler ) {
								if ( validator.submitButton ) {
									// insert a hidden input as a replacement for the missing submit button
									hidden = $("<input type='hidden'/>").attr("name", validator.submitButton.name).val( $(validator.submitButton).val() ).appendTo(validator.currentForm);
								}
								validator.settings.submitHandler.call( validator, validator.currentForm, event );
								if ( validator.submitButton ) {
									// and clean up afterwards; thanks to no-block-scope, hidden can be referenced
									hidden.remove();
								}
								return false;
							}
							return true;
						}

						// prevent submit for invalid forms or custom submit handlers
						if ( validator.cancelSubmit ) {
							validator.cancelSubmit = false;
							return handle();
						}
						if ( validator.form() ) {
							if ( validator.pendingRequest ) {
								validator.formSubmitted = true;
								return false;
							}
							return handle();
						} else {
							validator.focusInvalid();
							return false;
						}
					});
				}

				return validator;
			},
			// http://docs.jquery.com/Plugins/Validation/valid
			valid: function() {
				if ( $(this[0]).is("form")) {
					return this.validate().form();
				} else {
					var valid = true;
					var validator = $(this[0].form).validate();
					this.each(function() {
						valid = valid && validator.element(this);
					});
					return valid;
				}
			},
			// attributes: space seperated list of attributes to retrieve and remove
			removeAttrs: function( attributes ) {
				var result = {},
					$element = this;
				$.each(attributes.split(/\s/), function( index, value ) {
					result[value] = $element.attr(value);
					$element.removeAttr(value);
				});
				return result;
			},
			// http://docs.jquery.com/Plugins/Validation/rules
			rules: function( command, argument ) {
				var element = this[0];

				if ( command ) {
					var settings = $.data(element.form, "validator").settings;
					var staticRules = settings.rules;
					var existingRules = $.validator.staticRules(element);
					switch(command) {
					case "add":
						$.extend(existingRules, $.validator.normalizeRule(argument));
						// remove messages from rules, but allow them to be set separetely
						delete existingRules.messages;
						staticRules[element.name] = existingRules;
						if ( argument.messages ) {
							settings.messages[element.name] = $.extend( settings.messages[element.name], argument.messages );
						}
						break;
					case "remove":
						if ( !argument ) {
							delete staticRules[element.name];
							return existingRules;
						}
						var filtered = {};
						$.each(argument.split(/\s/), function( index, method ) {
							filtered[method] = existingRules[method];
							delete existingRules[method];
						});
						return filtered;
					}
				}

				var data = $.validator.normalizeRules(
				$.extend(
					{},
					$.validator.classRules(element),
					$.validator.attributeRules(element),
					$.validator.dataRules(element),
					$.validator.staticRules(element)
				), element);

				// make sure required is at front
				if ( data.required ) {
					var param = data.required;
					delete data.required;
					data = $.extend({required: param}, data);
				}

				return data;
			}
		});

		// Custom selectors
		$.extend($.expr[":"], {
			// http://docs.jquery.com/Plugins/Validation/blank
			blank: function( a ) { return !$.trim("" + $(a).val()); },
			// http://docs.jquery.com/Plugins/Validation/filled
			filled: function( a ) { return !!$.trim("" + $(a).val()); },
			// http://docs.jquery.com/Plugins/Validation/unchecked
			unchecked: function( a ) { return !$(a).prop("checked"); }
		});

		// constructor for validator
		$.validator = function( options, form ) {
			this.settings = $.extend( true, {}, $.validator.defaults, options );
			this.currentForm = form;
			this.init();
		};

		$.validator.format = function( source, params ) {
			if ( arguments.length === 1 ) {
				return function() {
					var args = $.makeArray(arguments);
					args.unshift(source);
					return $.validator.format.apply( this, args );
				};
			}
			if ( arguments.length > 2 && params.constructor !== Array  ) {
				params = $.makeArray(arguments).slice(1);
			}
			if ( params.constructor !== Array ) {
				params = [ params ];
			}
			$.each(params, function( i, n ) {
				source = source.replace( new RegExp("\\{" + i + "\\}", "g"), function() {
					return n;
				});
			});
			return source;
		};

		$.extend($.validator, {

			defaults: {
				messages: {},
				groups: {},
				rules: {},
				errorClass: "error",
				validClass: "valid",
				errorElement: "label",
				focusInvalid: true,
				errorContainer: $([]),
				errorLabelContainer: $([]),
				onsubmit: true,
				ignore: ":hidden",
				ignoreTitle: false,
				onfocusin: function( element, event ) {
					this.lastActive = element;

					// hide error label and remove error class on focus if enabled
					if ( this.settings.focusCleanup && !this.blockFocusCleanup ) {
						if ( this.settings.unhighlight ) {
							this.settings.unhighlight.call( this, element, this.settings.errorClass, this.settings.validClass );
						}
						this.addWrapper(this.errorsFor(element)).hide();
					}
				},
				onfocusout: function( element, event ) {
					if ( !this.checkable(element) && (element.name in this.submitted || !this.optional(element)) ) {
						this.element(element);
					}
				},
				onkeyup: function( element, event ) {
					if ( event.which === 9 && this.elementValue(element) === "" ) {
						return;
					} else if ( element.name in this.submitted || element === this.lastElement ) {
						this.element(element);
					}
				},
				onclick: function( element, event ) {
					// click on selects, radiobuttons and checkboxes
					if ( element.name in this.submitted ) {
						this.element(element);
					}
					// or option elements, check parent select in that case
					else if ( element.parentNode.name in this.submitted ) {
						this.element(element.parentNode);
					}
				},
				highlight: function( element, errorClass, validClass ) {
					if ( element.type === "radio" ) {
						this.findByName(element.name).addClass(errorClass).removeClass(validClass);
					} else {
						$(element).addClass(errorClass).removeClass(validClass);
					}
				},
				unhighlight: function( element, errorClass, validClass ) {
					if ( element.type === "radio" ) {
						this.findByName(element.name).removeClass(errorClass).addClass(validClass);
					} else {
						$(element).removeClass(errorClass).addClass(validClass);
					}
				}
			},

			// http://docs.jquery.com/Plugins/Validation/Validator/setDefaults
			setDefaults: function( settings ) {
				$.extend( $.validator.defaults, settings );
			},

			messages: {
				required: "This field is required.",
				remote: "Please fix this field.",
				email: "Please enter a valid email address.",
				url: "Please enter a valid URL.",
				date: "Please enter a valid date.",
				dateISO: "Please enter a valid date (ISO).",
				number: "Please enter a valid number.",
				digits: "Please enter only digits.",
				creditcard: "Please enter a valid credit card number.",
				equalTo: "Please enter the same value again.",
				maxlength: $.validator.format("Please enter no more than {0} characters."),
				minlength: $.validator.format("Please enter at least {0} characters."),
				rangelength: $.validator.format("Please enter a value between {0} and {1} characters long."),
				range: $.validator.format("Please enter a value between {0} and {1}."),
				max: $.validator.format("Please enter a value less than or equal to {0}."),
				min: $.validator.format("Please enter a value greater than or equal to {0}.")
			},

			autoCreateRanges: false,

			prototype: {

				init: function() {
					this.labelContainer = $(this.settings.errorLabelContainer);
					this.errorContext = this.labelContainer.length && this.labelContainer || $(this.currentForm);
					this.containers = $(this.settings.errorContainer).add( this.settings.errorLabelContainer );
					this.submitted = {};
					this.valueCache = {};
					this.pendingRequest = 0;
					this.pending = {};
					this.invalid = {};
					this.reset();

					var groups = (this.groups = {});
					$.each(this.settings.groups, function( key, value ) {
						if ( typeof value === "string" ) {
							value = value.split(/\s/);
						}
						$.each(value, function( index, name ) {
							groups[name] = key;
						});
					});
					var rules = this.settings.rules;
					$.each(rules, function( key, value ) {
						rules[key] = $.validator.normalizeRule(value);
					});

					function delegate(event) {
						var validator = $.data(this[0].form, "validator"),
							eventType = "on" + event.type.replace(/^validate/, "");
						if ( validator.settings[eventType] ) {
							validator.settings[eventType].call(validator, this[0], event);
						}
					}
					$(this.currentForm)
						.validateDelegate(":text, [type='password'], [type='file'], select, textarea, " +
							"[type='number'], [type='search'] ,[type='tel'], [type='url'], " +
							"[type='email'], [type='datetime'], [type='date'], [type='month'], " +
							"[type='week'], [type='time'], [type='datetime-local'], " +
							"[type='range'], [type='color'] ",
							"focusin focusout keyup", delegate)
						.validateDelegate("[type='radio'], [type='checkbox'], select, option", "click", delegate);

					if ( this.settings.invalidHandler ) {
						$(this.currentForm).bind("invalid-form.validate", this.settings.invalidHandler);
					}
				},

				// http://docs.jquery.com/Plugins/Validation/Validator/form
				form: function() {
					this.checkForm();
					$.extend(this.submitted, this.errorMap);
					this.invalid = $.extend({}, this.errorMap);
					if ( !this.valid() ) {
						$(this.currentForm).triggerHandler("invalid-form", [this]);
					}
					this.showErrors();
					return this.valid();
				},

				checkForm: function() {
					this.prepareForm();
					for ( var i = 0, elements = (this.currentElements = this.elements()); elements[i]; i++ ) {
						this.check( elements[i] );
					}
					return this.valid();
				},

				// http://docs.jquery.com/Plugins/Validation/Validator/element
				element: function( element ) {
					element = this.validationTargetFor( this.clean( element ) );
					this.lastElement = element;
					this.prepareElement( element );
					this.currentElements = $(element);
					var result = this.check( element ) !== false;
					if ( result ) {
						delete this.invalid[element.name];
					} else {
						this.invalid[element.name] = true;
					}
					if ( !this.numberOfInvalids() ) {
						// Hide error containers on last error
						this.toHide = this.toHide.add( this.containers );
					}
					this.showErrors();
					return result;
				},

				// http://docs.jquery.com/Plugins/Validation/Validator/showErrors
				showErrors: function( errors ) {
					if ( errors ) {
						// add items to error list and map
						$.extend( this.errorMap, errors );
						this.errorList = [];
						for ( var name in errors ) {
							this.errorList.push({
								message: errors[name],
								element: this.findByName(name)[0]
							});
						}
						// remove items from success list
						this.successList = $.grep( this.successList, function( element ) {
							return !(element.name in errors);
						});
					}
					if ( this.settings.showErrors ) {
						this.settings.showErrors.call( this, this.errorMap, this.errorList );
					} else {
						this.defaultShowErrors();
					}
				},

				// http://docs.jquery.com/Plugins/Validation/Validator/resetForm
				resetForm: function() {
					if ( $.fn.resetForm ) {
						$(this.currentForm).resetForm();
					}
					this.submitted = {};
					this.lastElement = null;
					this.prepareForm();
					this.hideErrors();
					this.elements().removeClass( this.settings.errorClass ).removeData( "previousValue" );
				},

				numberOfInvalids: function() {
					return this.objectLength(this.invalid);
				},

				objectLength: function( obj ) {
					var count = 0;
					for ( var i in obj ) {
						count++;
					}
					return count;
				},

				hideErrors: function() {
					this.addWrapper( this.toHide ).hide();
				},

				valid: function() {
					return this.size() === 0;
				},

				size: function() {
					return this.errorList.length;
				},

				focusInvalid: function() {
					if ( this.settings.focusInvalid ) {
						try {
							$(this.findLastActive() || this.errorList.length && this.errorList[0].element || [])
							.filter(":visible")
							.focus()
							// manually trigger focusin event; without it, focusin handler isn't called, findLastActive won't have anything to find
							.trigger("focusin");
						} catch(e) {
							// ignore IE throwing errors when focusing hidden elements
						}
					}
				},

				findLastActive: function() {
					var lastActive = this.lastActive;
					return lastActive && $.grep(this.errorList, function( n ) {
						return n.element.name === lastActive.name;
					}).length === 1 && lastActive;
				},

				elements: function() {
					var validator = this,
						rulesCache = {};

					// select all valid inputs inside the form (no submit or reset buttons)
					return $(this.currentForm)
					.find("input, select, textarea")
					.not(":submit, :reset, :image, [disabled]")
					.not( this.settings.ignore )
					.filter(function() {
						if ( !this.name && validator.settings.debug && window.console ) {
							console.error( "%o has no name assigned", this);
						}

						// select only the first element for each name, and only those with rules specified
						if ( this.name in rulesCache || !validator.objectLength($(this).rules()) ) {
							return false;
						}

						rulesCache[this.name] = true;
						return true;
					});
				},

				clean: function( selector ) {
					return $(selector)[0];
				},

				errors: function() {
					var errorClass = this.settings.errorClass.replace(" ", ".");
					return $(this.settings.errorElement + "." + errorClass, this.errorContext);
				},

				reset: function() {
					this.successList = [];
					this.errorList = [];
					this.errorMap = {};
					this.toShow = $([]);
					this.toHide = $([]);
					this.currentElements = $([]);
				},

				prepareForm: function() {
					this.reset();
					this.toHide = this.errors().add( this.containers );
				},

				prepareElement: function( element ) {
					this.reset();
					this.toHide = this.errorsFor(element);
				},

				elementValue: function( element ) {
					var type = $(element).attr("type"),
						val = $(element).val();

					if ( type === "radio" || type === "checkbox" ) {
						return $("input[name='" + $(element).attr("name") + "']:checked").val();
					}

					if ( typeof val === "string" ) {
						return val.replace(/\r/g, "");
					}
					return val;
				},

				check: function( element ) {
					element = this.validationTargetFor( this.clean( element ) );

					var rules = $(element).rules();
					var dependencyMismatch = false;
					var val = this.elementValue(element);
					var result;

					for (var method in rules ) {
						var rule = { method: method, parameters: rules[method] };
						try {

							result = $.validator.methods[method].call( this, val, element, rule.parameters );

							// if a method indicates that the field is optional and therefore valid,
							// don't mark it as valid when there are no other rules
							if ( result === "dependency-mismatch" ) {
								dependencyMismatch = true;
								continue;
							}
							dependencyMismatch = false;

							if ( result === "pending" ) {
								this.toHide = this.toHide.not( this.errorsFor(element) );
								return;
							}

							if ( !result ) {
								this.formatAndAdd( element, rule );
								return false;
							}
						} catch(e) {
							if ( this.settings.debug && window.console ) {
								console.log( "Exception occurred when checking element " + element.id + ", check the '" + rule.method + "' method.", e );
							}
							throw e;
						}
					}
					if ( dependencyMismatch ) {
						return;
					}
					if ( this.objectLength(rules) ) {
						this.successList.push(element);
					}
					return true;
				},

				// return the custom message for the given element and validation method
				// specified in the element's HTML5 data attribute
				customDataMessage: function( element, method ) {
					return $(element).data("msg-" + method.toLowerCase()) || (element.attributes && $(element).attr("data-msg-" + method.toLowerCase()));
				},

				// return the custom message for the given element name and validation method
				customMessage: function( name, method ) {
					var m = this.settings.messages[name];
					return m && (m.constructor === String ? m : m[method]);
				},

				// return the first defined argument, allowing empty strings
				findDefined: function() {
					for(var i = 0; i < arguments.length; i++) {
						if ( arguments[i] !== undefined ) {
							return arguments[i];
						}
					}
					return undefined;
				},

				defaultMessage: function( element, method ) {
					return this.findDefined(
						this.customMessage( element.name, method ),
						this.customDataMessage( element, method ),
						// title is never undefined, so handle empty string as undefined
						!this.settings.ignoreTitle && element.title || undefined,
						$.validator.messages[method],
						"<strong>Warning: No message defined for " + element.name + "</strong>"
					);
				},

				formatAndAdd: function( element, rule ) {
					var message = this.defaultMessage( element, rule.method ),
						theregex = /\$?\{(\d+)\}/g;
					if ( typeof message === "function" ) {
						message = message.call(this, rule.parameters, element);
					} else if (theregex.test(message)) {
						message = $.validator.format(message.replace(theregex, "{$1}"), rule.parameters);
					}
					this.errorList.push({
						message: message,
						element: element
					});

					this.errorMap[element.name] = message;
					this.submitted[element.name] = message;
				},

				addWrapper: function( toToggle ) {
					if ( this.settings.wrapper ) {
						toToggle = toToggle.add( toToggle.parent( this.settings.wrapper ) );
					}
					return toToggle;
				},

				defaultShowErrors: function() {
					var i, elements;
					for ( i = 0; this.errorList[i]; i++ ) {
						var error = this.errorList[i];
						if ( this.settings.highlight ) {
							this.settings.highlight.call( this, error.element, this.settings.errorClass, this.settings.validClass );
						}
						this.showLabel( error.element, error.message );
					}
					if ( this.errorList.length ) {
						this.toShow = this.toShow.add( this.containers );
					}
					if ( this.settings.success ) {
						for ( i = 0; this.successList[i]; i++ ) {
							this.showLabel( this.successList[i] );
						}
					}
					if ( this.settings.unhighlight ) {
						for ( i = 0, elements = this.validElements(); elements[i]; i++ ) {
							this.settings.unhighlight.call( this, elements[i], this.settings.errorClass, this.settings.validClass );
						}
					}
					this.toHide = this.toHide.not( this.toShow );
					this.hideErrors();
					this.addWrapper( this.toShow ).show();
				},

				validElements: function() {
					return this.currentElements.not(this.invalidElements());
				},

				invalidElements: function() {
					return $(this.errorList).map(function() {
						return this.element;
					});
				},

				showLabel: function( element, message ) {
					var label = this.errorsFor( element );
					if ( label.length ) {
						// refresh error/success class
						label.removeClass( this.settings.validClass ).addClass( this.settings.errorClass );
						// replace message on existing label
						label.html(message);
					} else {
						// create label
						label = $("<" + this.settings.errorElement + ">")
							.attr("for", this.idOrName(element))
							.addClass(this.settings.errorClass)
							.html(message || "");
						if ( this.settings.wrapper ) {
							// make sure the element is visible, even in IE
							// actually showing the wrapped element is handled elsewhere
							label = label.hide().show().wrap("<" + this.settings.wrapper + "/>").parent();
						}
						if ( !this.labelContainer.append(label).length ) {
							if ( this.settings.errorPlacement ) {
								this.settings.errorPlacement(label, $(element) );
							} else {
								label.insertAfter(element);
							}
						}
					}
					if ( !message && this.settings.success ) {
						label.text("");
						if ( typeof this.settings.success === "string" ) {
							label.addClass( this.settings.success );
						} else {
							this.settings.success( label, element );
						}
					}
					this.toShow = this.toShow.add(label);
				},

				errorsFor: function( element ) {
					var name = this.idOrName(element);
					return this.errors().filter(function() {
						return $(this).attr("for") === name;
					});
				},

				idOrName: function( element ) {
					return this.groups[element.name] || (this.checkable(element) ? element.name : element.id || element.name);
				},

				validationTargetFor: function( element ) {
					// if radio/checkbox, validate first element in group instead
					if ( this.checkable(element) ) {
						element = this.findByName( element.name ).not(this.settings.ignore)[0];
					}
					return element;
				},

				checkable: function( element ) {
					return (/radio|checkbox/i).test(element.type);
				},

				findByName: function( name ) {
					return $(this.currentForm).find("[name='" + name + "']");
				},

				getLength: function( value, element ) {
					switch( element.nodeName.toLowerCase() ) {
					case "select":
						return $("option:selected", element).length;
					case "input":
						if ( this.checkable( element) ) {
							return this.findByName(element.name).filter(":checked").length;
						}
					}
					return value.length;
				},

				depend: function( param, element ) {
					return this.dependTypes[typeof param] ? this.dependTypes[typeof param](param, element) : true;
				},

				dependTypes: {
					"boolean": function( param, element ) {
						return param;
					},
					"string": function( param, element ) {
						return !!$(param, element.form).length;
					},
					"function": function( param, element ) {
						return param(element);
					}
				},

				optional: function( element ) {
					var val = this.elementValue(element);
					return !$.validator.methods.required.call(this, val, element) && "dependency-mismatch";
				},

				startRequest: function( element ) {
					if ( !this.pending[element.name] ) {
						this.pendingRequest++;
						this.pending[element.name] = true;
					}
				},

				stopRequest: function( element, valid ) {
					this.pendingRequest--;
					// sometimes synchronization fails, make sure pendingRequest is never < 0
					if ( this.pendingRequest < 0 ) {
						this.pendingRequest = 0;
					}
					delete this.pending[element.name];
					if ( valid && this.pendingRequest === 0 && this.formSubmitted && this.form() ) {
						$(this.currentForm).submit();
						this.formSubmitted = false;
					} else if (!valid && this.pendingRequest === 0 && this.formSubmitted) {
						$(this.currentForm).triggerHandler("invalid-form", [this]);
						this.formSubmitted = false;
					}
				},

				previousValue: function( element ) {
					return $.data(element, "previousValue") || $.data(element, "previousValue", {
						old: null,
						valid: true,
						message: this.defaultMessage( element, "remote" )
					});
				}

			},

			classRuleSettings: {
				required: {required: true},
				email: {email: true},
				url: {url: true},
				date: {date: true},
				dateISO: {dateISO: true},
				number: {number: true},
				digits: {digits: true},
				creditcard: {creditcard: true}
			},

			addClassRules: function( className, rules ) {
				if ( className.constructor === String ) {
					this.classRuleSettings[className] = rules;
				} else {
					$.extend(this.classRuleSettings, className);
				}
			},

			classRules: function( element ) {
				var rules = {};
				var classes = $(element).attr("class");
				if ( classes ) {
					$.each(classes.split(" "), function() {
						if ( this in $.validator.classRuleSettings ) {
							$.extend(rules, $.validator.classRuleSettings[this]);
						}
					});
				}
				return rules;
			},

			attributeRules: function( element ) {
				var rules = {};
				var $element = $(element);
				var type = $element[0].getAttribute("type");

				for (var method in $.validator.methods) {
					var value;

					// support for <input required> in both html5 and older browsers
					if ( method === "required" ) {
						value = $element.get(0).getAttribute(method);
						// Some browsers return an empty string for the required attribute
						// and non-HTML5 browsers might have required="" markup
						if ( value === "" ) {
							value = true;
						}
						// force non-HTML5 browsers to return bool
						value = !!value;
					} else {
						value = $element.attr(method);
					}

					// convert the value to a number for number inputs, and for text for backwards compability
					// allows type="date" and others to be compared as strings
					if ( /min|max/.test( method ) && ( type === null || /number|range|text/.test( type ) ) ) {
						value = Number(value);
					}

					if ( value ) {
						rules[method] = value;
					} else if ( type === method && type !== 'range' ) {
						// exception: the jquery validate 'range' method
						// does not test for the html5 'range' type
						rules[method] = true;
					}
				}

				// maxlength may be returned as -1, 2147483647 (IE) and 524288 (safari) for text inputs
				if ( rules.maxlength && /-1|2147483647|524288/.test(rules.maxlength) ) {
					delete rules.maxlength;
				}

				return rules;
			},

			dataRules: function( element ) {
				var method, value,
					rules = {}, $element = $(element);
				for (method in $.validator.methods) {
					value = $element.data("rule-" + method.toLowerCase());
					if ( value !== undefined ) {
						rules[method] = value;
					}
				}
				return rules;
			},

			staticRules: function( element ) {
				var rules = {};
				var validator = $.data(element.form, "validator");
				if ( validator.settings.rules ) {
					rules = $.validator.normalizeRule(validator.settings.rules[element.name]) || {};
				}
				return rules;
			},

			normalizeRules: function( rules, element ) {
				// handle dependency check
				$.each(rules, function( prop, val ) {
					// ignore rule when param is explicitly false, eg. required:false
					if ( val === false ) {
						delete rules[prop];
						return;
					}
					if ( val.param || val.depends ) {
						var keepRule = true;
						switch (typeof val.depends) {
						case "string":
							keepRule = !!$(val.depends, element.form).length;
							break;
						case "function":
							keepRule = val.depends.call(element, element);
							break;
						}
						if ( keepRule ) {
							rules[prop] = val.param !== undefined ? val.param : true;
						} else {
							delete rules[prop];
						}
					}
				});

				// evaluate parameters
				$.each(rules, function( rule, parameter ) {
					rules[rule] = $.isFunction(parameter) ? parameter(element) : parameter;
				});

				// clean number parameters
				$.each(['minlength', 'maxlength'], function() {
					if ( rules[this] ) {
						rules[this] = Number(rules[this]);
					}
				});
				$.each(['rangelength', 'range'], function() {
					var parts;
					if ( rules[this] ) {
						if ( $.isArray(rules[this]) ) {
							rules[this] = [Number(rules[this][0]), Number(rules[this][1])];
						} else if ( typeof rules[this] === "string" ) {
							parts = rules[this].split(/[\s,]+/);
							rules[this] = [Number(parts[0]), Number(parts[1])];
						}
					}
				});

				if ( $.validator.autoCreateRanges ) {
					// auto-create ranges
					if ( rules.min && rules.max ) {
						rules.range = [rules.min, rules.max];
						delete rules.min;
						delete rules.max;
					}
					if ( rules.minlength && rules.maxlength ) {
						rules.rangelength = [rules.minlength, rules.maxlength];
						delete rules.minlength;
						delete rules.maxlength;
					}
				}

				return rules;
			},

			// Converts a simple string to a {string: true} rule, e.g., "required" to {required:true}
			normalizeRule: function( data ) {
				if ( typeof data === "string" ) {
					var transformed = {};
					$.each(data.split(/\s/), function() {
						transformed[this] = true;
					});
					data = transformed;
				}
				return data;
			},

			// http://docs.jquery.com/Plugins/Validation/Validator/addMethod
			addMethod: function( name, method, message ) {
				$.validator.methods[name] = method;
				$.validator.messages[name] = message !== undefined ? message : $.validator.messages[name];
				if ( method.length < 3 ) {
					$.validator.addClassRules(name, $.validator.normalizeRule(name));
				}
			},

			methods: {

				// http://docs.jquery.com/Plugins/Validation/Methods/required
				required: function( value, element, param ) {
					// check if dependency is met
					if ( !this.depend(param, element) ) {
						return "dependency-mismatch";
					}
					if ( element.nodeName.toLowerCase() === "select" ) {
						// could be an array for select-multiple or a string, both are fine this way
						var val = $(element).val();
						return val && val.length > 0;
					}
					if ( this.checkable(element) ) {
						return this.getLength(value, element) > 0;
					}
					return $.trim(value).length > 0;
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/email
				email: function( value, element ) {
					// contributed by Scott Gonzalez: http://projects.scottsplayground.com/email_address_validation/
					return this.optional(element) || /^((([a-z]|\d|[!#\$%&'\*\+\-\/=\?\^_`{\|}~]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])+(\.([a-z]|\d|[!#\$%&'\*\+\-\/=\?\^_`{\|}~]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])+)*)|((\x22)((((\x20|\x09)*(\x0d\x0a))?(\x20|\x09)+)?(([\x01-\x08\x0b\x0c\x0e-\x1f\x7f]|\x21|[\x23-\x5b]|[\x5d-\x7e]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(\\([\x01-\x09\x0b\x0c\x0d-\x7f]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF]))))*(((\x20|\x09)*(\x0d\x0a))?(\x20|\x09)+)?(\x22)))@((([a-z]|\d|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(([a-z]|\d|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])*([a-z]|\d|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])))\.)+(([a-z]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(([a-z]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])*([a-z]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])))$/i.test(value);
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/url
				url: function( value, element ) {
					// contributed by Scott Gonzalez: http://projects.scottsplayground.com/iri/
					return this.optional(element) || /^(https?|s?ftp):\/\/(((([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(%[\da-f]{2})|[!\$&'\(\)\*\+,;=]|:)*@)?(((\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])\.(\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])\.(\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])\.(\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5]))|((([a-z]|\d|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(([a-z]|\d|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])*([a-z]|\d|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])))\.)+(([a-z]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(([a-z]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])*([a-z]|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])))\.?)(:\d*)?)(\/((([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(%[\da-f]{2})|[!\$&'\(\)\*\+,;=]|:|@)+(\/(([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(%[\da-f]{2})|[!\$&'\(\)\*\+,;=]|:|@)*)*)?)?(\?((([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(%[\da-f]{2})|[!\$&'\(\)\*\+,;=]|:|@)|[\uE000-\uF8FF]|\/|\?)*)?(#((([a-z]|\d|-|\.|_|~|[\u00A0-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF])|(%[\da-f]{2})|[!\$&'\(\)\*\+,;=]|:|@)|\/|\?)*)?$/i.test(value);
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/date
				date: function( value, element ) {
					return this.optional(element) || !/Invalid|NaN/.test(new Date(value).toString());
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/dateISO
				dateISO: function( value, element ) {
					return this.optional(element) || /^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}$/.test(value);
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/number
				number: function( value, element ) {
					return this.optional(element) || /^-?(?:\d+|\d{1,3}(?:,\d{3})+)?(?:\.\d+)?$/.test(value);
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/digits
				digits: function( value, element ) {
					return this.optional(element) || /^\d+$/.test(value);
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/creditcard
				// based on http://en.wikipedia.org/wiki/Luhn
				creditcard: function( value, element ) {
					if ( this.optional(element) ) {
						return "dependency-mismatch";
					}
					// accept only spaces, digits and dashes
					if ( /[^0-9 \-]+/.test(value) ) {
						return false;
					}
					var nCheck = 0,
						nDigit = 0,
						bEven = false;

					value = value.replace(/\D/g, "");

					for (var n = value.length - 1; n >= 0; n--) {
						var cDigit = value.charAt(n);
						nDigit = parseInt(cDigit, 10);
						if ( bEven ) {
							if ( (nDigit *= 2) > 9 ) {
								nDigit -= 9;
							}
						}
						nCheck += nDigit;
						bEven = !bEven;
					}

					return (nCheck % 10) === 0;
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/minlength
				minlength: function( value, element, param ) {
					var length = $.isArray( value ) ? value.length : this.getLength($.trim(value), element);
					return this.optional(element) || length >= param;
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/maxlength
				maxlength: function( value, element, param ) {
					var length = $.isArray( value ) ? value.length : this.getLength($.trim(value), element);
					return this.optional(element) || length <= param;
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/rangelength
				rangelength: function( value, element, param ) {
					var length = $.isArray( value ) ? value.length : this.getLength($.trim(value), element);
					return this.optional(element) || ( length >= param[0] && length <= param[1] );
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/min
				min: function( value, element, param ) {
					return this.optional(element) || value >= param;
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/max
				max: function( value, element, param ) {
					return this.optional(element) || value <= param;
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/range
				range: function( value, element, param ) {
					return this.optional(element) || ( value >= param[0] && value <= param[1] );
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/equalTo
				equalTo: function( value, element, param ) {
					// bind to the blur event of the target in order to revalidate whenever the target field is updated
					// TODO find a way to bind the event just once, avoiding the unbind-rebind overhead
					var target = $(param);
					if ( this.settings.onfocusout ) {
						target.unbind(".validate-equalTo").bind("blur.validate-equalTo", function() {
							$(element).valid();
						});
					}
					return value === target.val();
				},

				// http://docs.jquery.com/Plugins/Validation/Methods/remote
				remote: function( value, element, param ) {
					if ( this.optional(element) ) {
						return "dependency-mismatch";
					}

					var previous = this.previousValue(element);
					if (!this.settings.messages[element.name] ) {
						this.settings.messages[element.name] = {};
					}
					previous.originalMessage = this.settings.messages[element.name].remote;
					this.settings.messages[element.name].remote = previous.message;

					param = typeof param === "string" && {url:param} || param;

					if ( previous.old === value ) {
						return previous.valid;
					}

					previous.old = value;
					var validator = this;
					this.startRequest(element);
					var data = {};
					data[element.name] = value;
					$.ajax($.extend(true, {
						url: param,
						mode: "abort",
						port: "validate" + element.name,
						dataType: "json",
						data: data,
						success: function( response ) {
							validator.settings.messages[element.name].remote = previous.originalMessage;
							var valid = response === true || response === "true";
							if ( valid ) {
								var submitted = validator.formSubmitted;
								validator.prepareElement(element);
								validator.formSubmitted = submitted;
								validator.successList.push(element);
								delete validator.invalid[element.name];
								validator.showErrors();
							} else {
								var errors = {};
								var message = response || validator.defaultMessage( element, "remote" );
								errors[element.name] = previous.message = $.isFunction(message) ? message(value) : message;
								validator.invalid[element.name] = true;
								validator.showErrors(errors);
							}
							previous.valid = valid;
							validator.stopRequest(element, valid);
						}
					}, param));
					return "pending";
				}

			}

		});

		// deprecated, use $.validator.format instead
		$.format = $.validator.format;

		}(jQuery));

		// ajax mode: abort
		// usage: $.ajax({ mode: "abort"[, port: "uniqueport"]});
		// if mode:"abort" is used, the previous request on that port (port can be undefined) is aborted via XMLHttpRequest.abort()
		(function($) {
			var pendingRequests = {};
			// Use a prefilter if available (1.5+)
			if ( $.ajaxPrefilter ) {
				$.ajaxPrefilter(function( settings, _, xhr ) {
					var port = settings.port;
					if ( settings.mode === "abort" ) {
						if ( pendingRequests[port] ) {
							pendingRequests[port].abort();
						}
						pendingRequests[port] = xhr;
					}
				});
			} else {
				// Proxy ajax
				var ajax = $.ajax;
				$.ajax = function( settings ) {
					var mode = ( "mode" in settings ? settings : $.ajaxSettings ).mode,
						port = ( "port" in settings ? settings : $.ajaxSettings ).port;
					if ( mode === "abort" ) {
						if ( pendingRequests[port] ) {
							pendingRequests[port].abort();
						}
						pendingRequests[port] = ajax.apply(this, arguments);
						return pendingRequests[port];
					}
					return ajax.apply(this, arguments);
				};
			}
		}(jQuery));

		// provides delegate(type: String, delegate: Selector, handler: Callback) plugin for easier event delegation
		// handler is only called when $(event.target).is(delegate), in the scope of the jquery-object for event.target
		(function($) {
			$.extend($.fn, {
				validateDelegate: function( delegate, type, handler ) {
					return this.bind(type, function( event ) {
						var target = $(event.target);
						if ( target.is(delegate) ) {
							return handler.apply(target, arguments);
						}
					});
				}
			});
		}(jQuery));




/*
	Masked Input plugin for jQuery
	Copyright (c) 2007-2013 Josh Bush (digitalbush.com)
	Licensed under the MIT license (http://digitalbush.com/projects/masked-input-plugin/#license)
	Version: 1.3.1
*/
(function($) {
	function getPasteEvent() {
    var el = document.createElement('input'),
        name = 'onpaste';
    el.setAttribute(name, '');
    return (typeof el[name] === 'function')?'paste':'input';             
}

var pasteEventName = getPasteEvent() + ".mask",
	ua = navigator.userAgent,
	iPhone = /iphone/i.test(ua),
	android=/android/i.test(ua),
	caretTimeoutId;

$.mask = {
	//Predefined character definitions
	definitions: {
		'9': "[0-9]",
		'a': "[A-Za-z]",
		'*': "[A-Za-z0-9]"
	},
	dataName: "rawMaskFn",
	placeholder: '_'
};

$.fn.extend({
	//Helper Function for Caret positioning
	caret: function(begin, end) {
		var range;

		if (this.length === 0 || this.is(":hidden")) {
			return;
		}

		if (typeof begin == 'number') {
			end = (typeof end === 'number') ? end : begin;
			return this.each(function() {
				if (this.setSelectionRange) {
					this.setSelectionRange(begin, end);
				} else if (this.createTextRange) {
					range = this.createTextRange();
					range.collapse(true);
					range.moveEnd('character', end);
					range.moveStart('character', begin);
					range.select();
				}
			});
		} else {
			if (this[0].setSelectionRange) {
				begin = this[0].selectionStart;
				end = this[0].selectionEnd;
			} else if (document.selection && document.selection.createRange) {
				range = document.selection.createRange();
				begin = 0 - range.duplicate().moveStart('character', -100000);
				end = begin + range.text.length;
			}
			return { begin: begin, end: end };
		}
	},
	unmask: function() {
		return this.trigger("unmask");
	},
	mask: function(mask, settings) {
		var input,
			defs,
			tests,
			partialPosition,
			firstNonMaskPos,
			len;

		if (!mask && this.length > 0) {
			input = $(this[0]);
			return input.data($.mask.dataName)();
		}
		settings = $.extend({
			placeholder: $.mask.placeholder, // Load default placeholder
			completed: null
		}, settings);


		defs = $.mask.definitions;
		tests = [];
		partialPosition = len = mask.length;
		firstNonMaskPos = null;

		$.each(mask.split(""), function(i, c) {
			if (c == '?') {
				len--;
				partialPosition = i;
			} else if (defs[c]) {
				tests.push(new RegExp(defs[c]));
				if (firstNonMaskPos === null) {
					firstNonMaskPos = tests.length - 1;
				}
			} else {
				tests.push(null);
			}
		});

		return this.trigger("unmask").each(function() {
			var input = $(this),
				buffer = $.map(
				mask.split(""),
				function(c, i) {
					if (c != '?') {
						return defs[c] ? settings.placeholder : c;
					}
				}),
				focusText = input.val();

			function seekNext(pos) {
				while (++pos < len && !tests[pos]);
				return pos;
			}

			function seekPrev(pos) {
				while (--pos >= 0 && !tests[pos]);
				return pos;
			}

			function shiftL(begin,end) {
				var i,
					j;

				if (begin<0) {
					return;
				}

				for (i = begin, j = seekNext(end); i < len; i++) {
					if (tests[i]) {
						if (j < len && tests[i].test(buffer[j])) {
							buffer[i] = buffer[j];
							buffer[j] = settings.placeholder;
						} else {
							break;
						}

						j = seekNext(j);
					}
				}
				writeBuffer();
				input.caret(Math.max(firstNonMaskPos, begin));
			}

			function shiftR(pos) {
				var i,
					c,
					j,
					t;

				for (i = pos, c = settings.placeholder; i < len; i++) {
					if (tests[i]) {
						j = seekNext(i);
						t = buffer[i];
						buffer[i] = c;
						if (j < len && tests[j].test(t)) {
							c = t;
						} else {
							break;
						}
					}
				}
			}

			function keydownEvent(e) {
				var k = e.which,
					pos,
					begin,
					end;

				//backspace, delete, and escape get special treatment
				if (k === 8 || k === 46 || (iPhone && k === 127)) {
					pos = input.caret();
					begin = pos.begin;
					end = pos.end;

					if (end - begin === 0) {
						begin=k!==46?seekPrev(begin):(end=seekNext(begin-1));
						end=k===46?seekNext(end):end;
					}
					clearBuffer(begin, end);
					shiftL(begin, end - 1);

					e.preventDefault();
				} else if (k == 27) {//escape
					input.val(focusText);
					input.caret(0, checkVal());
					e.preventDefault();
				}
			}

			function keypressEvent(e) {
				var k = e.which,
					pos = input.caret(),
					p,
					c,
					next;

				if (e.ctrlKey || e.altKey || e.metaKey || k < 32) {//Ignore
					return;
				} else if (k) {
					if (pos.end - pos.begin !== 0){
						clearBuffer(pos.begin, pos.end);
						shiftL(pos.begin, pos.end-1);
					}

					p = seekNext(pos.begin - 1);
					if (p < len) {
						c = String.fromCharCode(k);
						if (tests[p].test(c)) {
							shiftR(p);

							buffer[p] = c;
							writeBuffer();
							next = seekNext(p);

							if(android){
								setTimeout($.proxy($.fn.caret,input,next),0);
							}else{
								input.caret(next);
							}

							if (settings.completed && next >= len) {
								settings.completed.call(input);
							}
						}
					}
					e.preventDefault();
				}
			}

			function clearBuffer(start, end) {
				var i;
				for (i = start; i < end && i < len; i++) {
					if (tests[i]) {
						buffer[i] = settings.placeholder;
					}
				}
			}

			function writeBuffer() { input.val(buffer.join('')); }

			function checkVal(allow) {
				//try to place characters where they belong
				var test = input.val(),
					lastMatch = -1,
					i,
					c;

				for (i = 0, pos = 0; i < len; i++) {
					if (tests[i]) {
						buffer[i] = settings.placeholder;
						while (pos++ < test.length) {
							c = test.charAt(pos - 1);
							if (tests[i].test(c)) {
								buffer[i] = c;
								lastMatch = i;
								break;
							}
						}
						if (pos > test.length) {
							break;
						}
					} else if (buffer[i] === test.charAt(pos) && i !== partialPosition) {
						pos++;
						lastMatch = i;
					}
				}
				if (allow) {
					writeBuffer();
				} else if (lastMatch + 1 < partialPosition) {
					input.val("");
					clearBuffer(0, len);
				} else {
					writeBuffer();
					input.val(input.val().substring(0, lastMatch + 1));
				}
				return (partialPosition ? i : firstNonMaskPos);
			}

			input.data($.mask.dataName,function(){
				return $.map(buffer, function(c, i) {
					return tests[i]&&c!=settings.placeholder ? c : null;
				}).join('');
			});

			if (!input.attr("readonly"))
				input
				.one("unmask", function() {
					input
						.unbind(".mask")
						.removeData($.mask.dataName);
				})
				.bind("focus.mask", function() {
					clearTimeout(caretTimeoutId);
					var pos,
						moveCaret;

					focusText = input.val();
					pos = checkVal();
					
					caretTimeoutId = setTimeout(function(){
						writeBuffer();
						if (pos == mask.length) {
							input.caret(0, pos);
						} else {
							input.caret(pos);
						}
					}, 10);
				})
				.bind("blur.mask", function() {
					checkVal();
					if (input.val() != focusText)
						input.change();
				})
				.bind("keydown.mask", keydownEvent)
				.bind("keypress.mask", keypressEvent)
				.bind(pasteEventName, function() {
					setTimeout(function() { 
						var pos=checkVal(true);
						input.caret(pos); 
						if (settings.completed && pos == input.val().length)
							settings.completed.call(input);
					}, 0);
				});
			checkVal(); //Perform initial check for existing values
		});
	}
});


})(jQuery);


		//Picklist
		jQuery.validator.addMethod("picklist", function( value, element ) {
			if(jQuery(element).hasClass("required")){
				return !(value == '' || value == '-- Please Select --');
			}else{
				return true;
			}

			}, "Please select an option");


		//Birthdate
		jQuery.validator.addMethod("birthdate", function( value, element ) {
			var result = this.optional(element) || (date_sanity(value) && check_bday(value));

			if (!result) {
				element.value = "";
				var validator = this;
			}
			return result;
			}, "Please enter a valid birthdate");


		//Date Sanity
		jQuery.validator.addMethod("date", function( value, element ) {

			var result = this.optional(element) || date_sanity(value);

			if (!result) {
				element.value = "";
				var validator = this;
			}
			return result;
			}, "Please enter a valid date.");



		jQuery.validator.addMethod("default_value", function( value, element ) {
			var result = this.optional(element) || default_value_check(element);

			if (!result) {
				element.value = "";
				var validator = this;
			}
			return result;
			}, "Please enter a valid value");



			function default_value_check(element){
				def = jQuery(element).attr("rel"), val = jQuery(element).val();
				return (def != val && val && def);
			}




		function date_sanity(value) {
			date = value.split("/");
			m = date[0], d = date[1], y = date[2];
			valid = /(0[1-9]|1[012])[\- \/.](0[1-9]|[12][0-9]|3[01])[\- \/.](19|20|21)[0-9]{2}/i.test(value);
			if(y < 1700 || y > 4000 || !valid) return false; //Salesforce check 1/1/1700 - 12/31/4000
			return m > 0 && m < 13 && y > 0 && y < 32768 && d > 0 && d <= (new Date(y, m, 0)).getDate()
		}

		function check_bday(value){
			date = value.split("/");
			checkm = date[0], checkd = date[1], checky = parseInt(date[2]);
			var today = new Date();
			nowm = today.getMonth(), nowd = today.getDay(), nowy = today.getFullYear();

			if( checky < (nowy - 110)) return false;
			else return true;
		}


		function comment_concat(){
			var c = jQuery("#"+ValidationSettings.commentId.replace(".", "\\."));
			var split = ' -- ';
			jQuery(".comment").each(function(x, el){
				element = jQuery(el);
				val = element.val() || false;
				if(element.attr("id")){
					name = element.attr("id").replace(/_/g, " ");
				}else{
					name = element.attr("name").replace(/_/g, " ");
				}

				if(val && name){
					value = jQuery(c).val();
					value = value.replace(ValidationSettings.commentId, '');
					jQuery(c).val( value + ' ' + name + ": " + val + split); 
				}
			});


			if(jQuery(c) && jQuery(c).length){
				//console.log(jQuery(c).val().substr(jQuery(c).val().length - split.length));
				if(jQuery(c).val() && jQuery(c).val().lastIndexOf(split) == jQuery(c).val().length - 4) {
					jQuery(c).val(jQuery(c).val().substring(0, jQuery(c).val().length - 4));
				}
			}
		}

		function radio_check(){
			var radios = new Array();
			jQuery("form input:radio").each(function(x, el){
				radios.push(jQuery(el).attr("name"));
			});
			radios = jQuery.unique(radios);
			selected = new Array();
			jQuery.each(radios, function(x, el){
				radio = document.getElementsByName(el);

				checked = 0, i = 0;
				for (i=0;i<=radio.length;i++){
					if(jQuery(radio[i]).is(":checked")){
						checked++;
					}
				}
				if(checked == 0) selected.push(x);
			});

			if(selected && selected.length > 0) return false;
			else return true;
		}

		function addCommentField(){
			var c = jQuery("#"+ValidationSettings.commentId.replace(".", "\\."));
			if (!c.length){
				jQuery("#"+ValidationSettings.formId).append('<textarea id="'+ValidationSettings.commentId+'" name="'+ValidationSettings.commentId+'" style="display:none"></textarea>');
			}
		}


	//jQuery = jQuery.noConflict();

	jQuery(function(){
		jQuery("input.phone").unmask().mask("(999) 999-9999");
		jQuery("input.zipcode, input.zip, input.postalcode").unmask().mask("99999");
	    jQuery("input.date").unmask().mask("99/99/9999");
		jQuery("input.birthdate").unmask().mask("99/99/9999");

		jQuery.validator.addClassRules({
		  name: {
			required: false,
			minlength: 2
		  },
		  string:{
			required: false
		  },
		  zip:{
			required: false,
			digits: true,
			minlength: 5,
			maxlength: 5
		  },
		  zipcode: {
			required: false,
			digits: true,
			minlength: 5,
			maxlength: 5
		  },
		  postalcode: {
			required: false,
			digits: true,
			minlength: 5,
			maxlength: 5
		  },
		  email: {
			required: false,
			email: "Please enter a valid email address, example: you@yourdomain.com"
		  }
		});



		if(typeof ValidationSettings  == 'undefined'){
			ValidationSettings = {};
			if(typeof ValidationSettings.formId == 'undefined'){
				var form = document.getElementById('DemandConnectForm');
				if(form.parentElement && form.parentElement.id){
					ValidationSettings.formId = form.parentElement.id;
				}else{
					ValidationSettings.formId = false;
				}
			}

			if(typeof ValidationSettings.commentId == 'undefined'){
				ValidationSettings.commentId = 'HC4__Inquiry__c.HC4__Comments__c';
			}

			addCommentField();
		}

		jQuery.validator.messages.required = "";


		if(typeof ValidationSettings.invalidHandler == 'undefined'){
			ValidationSettings.invalidHandler = function(e, validator) {
				var errors = validator.numberOfInvalids();
				if (errors) {
					if (typeof ValidationSettings.customMessage != "function" ) {
						var message = errors == 1
							? 'The form contains an error. Please correct the highlighted field(s) and submit the form again.'
							: 'The form contains ' + errors + ' errors. Please correct the highlighted field(s) and submit the form again.';
						alert(message);
					}else{
						ValidationSettings.customMessage(errors);
					}
				}
			}
		}

		if(typeof ValidationSettings.submitHandler == 'undefined'){
			ValidationSettings.submitHandler = function(form) {
					comment_concat();
					jQuery('.disableOnClick').attr('disabled','disabled');
					if(radio_check()){
						form.submit();
					}else{
						alert("Please be sure to fill in all the radio buttons");
						jQuery('.disableOnClick').removeAttr('disabled');
					}
			 }			
		}




		jQuery("#"+ValidationSettings.formId).validate({
			onkeyup: false,
			invalidHandler: function(e, validator) { 
				ValidationSettings.invalidHandler(e, validator);
			},
			submitHandler: function(form) {
				ValidationSettings.submitHandler(form);
			}
		});


	});
}
