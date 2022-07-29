install: configure

configure:

	@echo "⚙️ Configuring Wordpress parameters..."
	wp core install \
		--url=${URL_WITHOUT_HTTP} \
		--title=$(WP_TITLE) \
		--admin_user=${WP_ADMIN_USER} \
		--admin_password=${WP_ADMIN_TEMP_PASS} \
		--admin_email=${WP_ADMIN_MAIL}

	wp option update siteurl ${PRIMARY_URL}
	wp rewrite structure $(WP_PERMA_STRUCTURE)
