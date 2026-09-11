   
$(function() {
	$(document).on('focusin', '.fieldInput, textarea', function() {
		if(this.title==this.value) {
			this.value = '';
		}
	}).on('focusout', '.fieldInput, textarea', function(){
		if(this.value=='') {
			this.value = this.title;
		}
	});

	//if( $('select').length ){
	//	$('select').c2Selectbox();
	//}

	$('.i-btn').click(function(){
		$(this).toggleClass('active').next('div, form').slideToggle();
		return false;
	})
	
});
