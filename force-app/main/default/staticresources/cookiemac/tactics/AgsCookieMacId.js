/*!
 * jQuery Cookie Plugin v1.4.1
 * https://github.com/carhartl/jquery-cookie
 *
 * Copyright 2006, 2014 Klaus Hartl
 * Released under the MIT license
 */
( function(factory) {
		if ( typeof define === 'function' && define.amd) {
			// AMD (Register as an anonymous module)
			define(['jquery'], factory);
		} else if ( typeof exports === 'object') {
			// Node/CommonJS
			module.exports = factory(require('jquery'));
		} else {
			// Browser globals
			factory(jQuery);
		}
	}(function($) {

		var pluses = /\+/g;

		function encode(s) {
			return config.raw ? s : encodeURIComponent(s);
		}

		function decode(s) {
			return config.raw ? s : decodeURIComponent(s);
		}

		function stringifyCookieValue(value) {
			return encode(config.json ? JSON.stringify(value) : String(value));
		}

		function parseCookieValue(s) {
			if (s.indexOf('"') === 0) {
				// This is a quoted cookie as according to RFC2068, unescape...
				s = s.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
			}

			try {
				// Replace server-side written pluses with spaces.
				// If we can't decode the cookie, ignore it, it's unusable.
				// If we can't parse the cookie, ignore it, it's unusable.
				s = decodeURIComponent(s.replace(pluses, ' '));
				return config.json ? JSON.parse(s) : s;
			} catch(e) {
			}
		}

		function read(s, converter) {
			var value = config.raw ? s : parseCookieValue(s);
			return $.isFunction(converter) ? converter(value) : value;
		}

		var config = $.cookie = function(key, value, options) {

			// Write

			if (arguments.length > 1 && !$.isFunction(value)) {
				options = $.extend({}, config.defaults, options);

				if ( typeof options.expires === 'number') {
					var days = options.expires, t = options.expires = new Date();
					t.setMilliseconds(t.getMilliseconds() + days * 864e+5);
				}

				return (document.cookie = [encode(key), '=', stringifyCookieValue(value), options.expires ? '; expires=' + options.expires.toUTCString() : '', // use expires attribute, max-age is not supported by IE
				options.path ? '; path=' + options.path : '', options.domain ? '; domain=' + options.domain : '', options.secure ? '; secure' : ''].join(''));
			}

			// Read

			var result = key ? undefined : {},
			// To prevent the for loop in the first place assign an empty array
			// in case there are no cookies at all. Also prevents odd result when
			// calling $.cookie().
			cookies = document.cookie ? document.cookie.split('; ') : [], i = 0, l = cookies.length;

			for (; i < l; i++) {
				var parts = cookies[i].split('='), name = decode(parts.shift()), cookie = parts.join('=');

				if (key === name) {
					// If second argument (value) is a function it's a converter...
					result = read(cookie, value);
					break;
				}

				// Prevent storing a cookie that we couldn't decode.
				if (!key && ( cookie = read(cookie)) !== undefined) {
					result[name] = cookie;
				}
			}

			return result;
		};

		config.defaults = {};

		$.removeCookie = function(key, options) {
			// Must not alter options, thus extending a fresh object...
			$.cookie(key, '', $.extend({}, options, {
				expires : -1
			}));
			return !$.cookie(key);
		};

	}));

//---------------------------------------------------------------------------------------------------------------------------

function getParameterByName(name) {
	name = name.replace(/[\[]/, "\\[").replace(/[\]]/, "\\]");
	var regex = new RegExp("[\\?&]" + name + "=([^&#]*)"), results = regex.exec(location.search);
	return results === null ? "" : decodeURIComponent(results[1].replace(/\+/g, " "));
}

function removeURLParameter(url, parameter) {
    //prefer to use l.search if you have a location/link object
    var urlparts= url.split('?');   
    if (urlparts.length>=2) {

        var prefix= encodeURIComponent(parameter)+'=';
        var pars= urlparts[1].split(/[&;]/g);

        //reverse iteration as may be destructive
        for (var i= pars.length; i-- > 0;) {    
            //idiom for string.startsWith
            if (pars[i].lastIndexOf(prefix, 0) !== -1) {  
                pars.splice(i, 1);
            }
        }

        url= urlparts[0]+'?'+pars.join('&');
        return url;
    } else {
        return url;
    }
}

var hcmac = getParameterByName('hcmacid');
if ($.cookie('hcmacid') != null) {
	if (hcmac == "") {
		var url = window.location.href;
		if (url.indexOf('?') > -1) {
			url += '&' + $.cookie('hcmacid');
		} else {
			url += '?' + $.cookie('hcmacid');
		}
		window.location.href = url;
	}
	else if($.cookie('hcmacid').indexOf(hcmac) == -1){
		var url = window.location.href;
		url = removeURLParameter(url, 'hcmacid');
		if (url.indexOf('?') > -1) {
			url += '&' + $.cookie('hcmacid');
		} else {
			url += '?' + $.cookie('hcmacid');
		}
		window.location.href = url;				
	}
}


if (getParameterByName('hcmacid') != "" && $.cookie('hcmacid') == null) {
	full_query =  window.location.search.replace("?", "");
	
	$.cookie('hcmacid', full_query, {
		expires : 1/48
	});
}

