# The personal, minimalist, super-fast, database free, bookmarking service.
# Makefile for PHP code analysis & testing, documentation and release generation

BIN = vendor/bin
PHP_SOURCE = index.php application tests plugins
PHP_COMMA_SOURCE = index.php,application,tests,plugins

all: static_analysis_summary check_permissions test

##
# Docker test adapter
#
# Shaarli sources and vendored libraries are copied from a shared volume
# to a user-owned directory to enable running tests as a non-root user.
##
docker_%:
	rsync -az /shaarli/ ~/shaarli/
	cd ~/shaarli && make $*

##
# Concise status of the project
# These targets are non-blocking: || exit 0
##

static_analysis_summary: code_sniffer_source copy_paste mess_detector_summary
	@echo

##
# PHP_CodeSniffer
# Detects PHP syntax errors
# Documentation (usage, output formatting):
# - http://pear.php.net/manual/en/package.php.php-codesniffer.usage.php
# - http://pear.php.net/manual/en/package.php.php-codesniffer.reporting.php
##

code_sniffer: code_sniffer_full

### - errors filtered by coding standard: PEAR, PSR1, PSR2, Zend...
PHPCS_%:
	@$(BIN)/phpcs $(PHP_SOURCE) --report-full --report-width=200 --standard=$*

### - errors by Git author
code_sniffer_blame:
	@$(BIN)/phpcs $(PHP_SOURCE) --report-gitblame

### - all errors/warnings
code_sniffer_full:
	@$(BIN)/phpcs $(PHP_SOURCE) --report-full --report-width=200

### - errors grouped by kind
code_sniffer_source:
	@$(BIN)/phpcs $(PHP_SOURCE) --report-source || exit 0

##
# PHP Copy/Paste Detector
# Detects code redundancy
# Documentation: https://github.com/sebastianbergmann/phpcpd
##

copy_paste:
	@echo "-----------------------"
	@echo "PHP COPY/PASTE DETECTOR"
	@echo "-----------------------"
	@$(BIN)/phpcpd $(PHP_SOURCE) || exit 0
	@echo

##
# PHP Mess Detector
# Detects PHP syntax errors, sorted by category
# Rules documentation: http://phpmd.org/rules/index.html
##
MESS_DETECTOR_RULES = cleancode,codesize,controversial,design,naming,unusedcode

mess_title:
	@echo "-----------------"
	@echo "PHP MESS DETECTOR"
	@echo "-----------------"

###  - all warnings
mess_detector: mess_title
	@$(BIN)/phpmd $(PHP_COMMA_SOURCE) text $(MESS_DETECTOR_RULES) | sed 's_.*\/__'

### - all warnings + HTML output contains links to PHPMD's documentation
mess_detector_html:
	@$(BIN)/phpmd $(PHP_COMMA_SOURCE) html $(MESS_DETECTOR_RULES) \
	--reportfile phpmd.html || exit 0

### - warnings grouped by message, sorted by descending frequency order
mess_detector_grouped: mess_title
	@$(BIN)/phpmd $(PHP_SOURCE) text $(MESS_DETECTOR_RULES) \
	| cut -f 2 | sort | uniq -c | sort -nr

### - summary: number of warnings by rule set
mess_detector_summary: mess_title
	@for rule in $$(echo $(MESS_DETECTOR_RULES) | tr ',' ' '); do \
		warnings=$$($(BIN)/phpmd $(PHP_COMMA_SOURCE) text $$rule | wc -l); \
		printf "$$warnings\t$$rule\n"; \
	done;

##
# Checks source file & script permissions
##
check_permissions:
	@echo "----------------------"
	@echo "Check file permissions"
	@echo "----------------------"
	@for file in `git ls-files | grep -v docker`; do \
		if [ -x $$file ]; then \
			errors=true; \
			echo "$${file} is executable"; \
		fi \
	done; [ -z $$errors ] || false

##
# PHPUnit
# Runs unitary and functional tests
# Generates an HTML coverage report if Xdebug is enabled
#
# See phpunit.xml for configuration
# https://phpunit.de/manual/current/en/appendixes.configuration.html
##
test: translate
	@echo "-------"
	@echo "PHPUNIT"
	@echo "-------"
	@mkdir -p sandbox coverage
	@$(BIN)/phpunit --coverage-php coverage/main.cov --bootstrap tests/bootstrap.php --testsuite unit-tests

locale_test_%:
	@UT_LOCALE=$*.utf8 \
		$(BIN)/phpunit \
		--coverage-php coverage/$(firstword $(subst _, ,$*)).cov \
		--bootstrap tests/languages/bootstrap.php \
		--testsuite language-$(firstword $(subst _, ,$*))

all_tests: test locale_test_de_DE locale_test_en_US locale_test_fr_FR
	@$(BIN)/phpcov merge --html coverage coverage
	@# --text doesn't work with phpunit 4.* (v5 requires PHP 5.6)
	@#$(BIN)/phpcov merge --text coverage/txt coverage

##
# Custom release archive generation
#
# For each tagged revision, GitHub provides tar and zip archives that correspond
# to the output of git-archive
#
# These targets produce similar archives, featuring 3rd-party dependencies
# to ease deployment on shared hosting.
##
ARCHIVE_VERSION := shaarli-$$(git describe)-full
ARCHIVE_PREFIX=Shaarli/

release_archive: release_tar release_zip

### download 3rd-party PHP libraries
composer_dependencies: clean
	composer install --no-dev --prefer-dist
	find vendor/ -name ".git" -type d -exec rm -rf {} +

### download 3rd-party frontend libraries
frontend_dependencies:
	yarn install

### Build frontend dependencies
build_frontend: frontend_dependencies
	yarn run build

### generate a release tarball and include 3rd-party dependencies and translations
release_tar: composer_dependencies htmldoc translate build_frontend
	git archive --prefix=$(ARCHIVE_PREFIX) -o $(ARCHIVE_VERSION).tar HEAD
	tar rvf $(ARCHIVE_VERSION).tar --transform "s|^vendor|$(ARCHIVE_PREFIX)vendor|" vendor/
	tar rvf $(ARCHIVE_VERSION).tar --transform "s|^doc/html|$(ARCHIVE_PREFIX)doc/html|" doc/html/
	gzip $(ARCHIVE_VERSION).tar

### generate a release zip and include 3rd-party dependencies and translations
release_zip: composer_dependencies htmldoc translate build_frontend
	git archive --prefix=$(ARCHIVE_PREFIX) -o $(ARCHIVE_VERSION).zip -9 HEAD
	mkdir -p $(ARCHIVE_PREFIX)/{doc,vendor}
	rsync -a doc/html/ $(ARCHIVE_PREFIX)doc/html/
	zip -r $(ARCHIVE_VERSION).zip $(ARCHIVE_PREFIX)doc/
	rsync -a vendor/ $(ARCHIVE_PREFIX)vendor/
	zip -r $(ARCHIVE_VERSION).zip $(ARCHIVE_PREFIX)vendor/
	rm -rf $(ARCHIVE_PREFIX)

##
# Targets for repository and documentation maintenance
##

### remove all unversioned files
clean:
	@git clean -df
	@rm -rf sandbox

### generate the AUTHORS file from Git commit information
authors:
	@cp .github/mailmap .mailmap
	@git shortlog -sne > AUTHORS
	@rm .mailmap

### generate Doxygen documentation
doxygen: clean
	@rm -rf doxygen
	@doxygen Doxyfile

### generate HTML documentation from Markdown pages with MkDocs
htmldoc:
	python3 -m venv venv/
	bash -c 'source venv/bin/activate; \
	pip install mkdocs; \
	mkdocs build'
	find doc/html/ -type f -exec chmod a-x '{}' \;
	rm -r venv


### Generate Shaarli's translation compiled file (.mo)
translate:
	@find inc/languages/ -name shaarli.po -execdir msgfmt shaarli.po -o shaarli.mo \;

### Run ESLint check against Shaarli's JS files
eslint:
	@yarn run eslint assets/vintage/js/
	@yarn run eslint assets/default/js/
