# Redis RPM packaging -- reproducible build and test.
#
#   make sources   regenerate the three generated tarballs (needs network)
#   make download  fetch the six RediSearch FetchContent deps
#   make srpm      build the source RPM
#   make mock      build binary RPMs locally in a clean chroot
#   make copr      submit the SRPM to Copr
#   make smoke     install from Copr and test every module
#   make lint      rpmlint the spec and any built RPMs
#   make all       sources + download + srpm + mock + lint
#
# Run `make help` for the full list.

NAME        := redis
SPEC        := $(NAME).spec
VERSION     := $(shell awk '/^Version:/{print $$2; exit}' $(SPEC))
RELEASE     := $(shell awk '/^Release:/{print $$2; exit}' $(SPEC) | sed 's/%{?dist}//')
ARCH        := $(shell uname -m)
DIST        ?= fc43
MOCK_CFG    ?= fedora-43-$(ARCH)
COPR_PROJECT?= @redis/redis

SOURCEDIR   := $(shell rpm --eval %{_sourcedir})
SRPMDIR     := $(shell rpm --eval %{_srcrpmdir})
SRPM        := $(SRPMDIR)/$(NAME)-$(VERSION)-$(RELEASE).$(DIST).src.rpm
MOCK_RESULT ?= $(HOME)/mock-results/$(NAME)-$(VERSION)-$(RELEASE)

.PHONY: all help sources download srpm mock copr smoke smoke-local lint clean distclean check-tools

## Show this help
help:
	@echo "Redis RPM packaging -- $(NAME) $(VERSION)-$(RELEASE)"
	@echo
	@grep -B1 -E '^[a-z][a-z-]*:' $(MAKEFILE_LIST) \
	  | grep -A1 '^##' \
	  | sed -E 's/^## (.*)/@@\1/' \
	  | awk -F: '/^@@/{d=substr($$0,3)} /^[a-z]/{printf "  \033[1m%-14s\033[0m %s\n", $$1, d}'
	@echo
	@echo "Variables: MOCK_CFG=$(MOCK_CFG)  COPR_PROJECT=$(COPR_PROJECT)"

## Verify the tools this Makefile needs are installed
check-tools:
	@missing=""; \
	for t in rpmbuild rpmlint mock copr-cli spectool git cargo createrepo_c; do \
	  command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "Missing tools:$$missing"; \
	  echo "Install with: sudo dnf install rpm-build rpmlint mock copr-cli rpmdevtools git cargo createrepo_c"; \
	  exit 1; \
	fi; \
	echo "All required tools present."

## Regenerate the generated tarballs: redis+modules, and both cargo vendors
sources:
	@scripts/make-sources.sh $(VERSION)

## Fetch the RediSearch FetchContent dependencies (Source3-Source8)
download:
	@cp -f sources/* $(SOURCEDIR)/
	@spectool -g -S $(SPEC) --define "_sourcedir $(SOURCEDIR)" 2>/dev/null \
	  | grep -E "Downloading|already exists" || true

## Build the source RPM
srpm: download
	@rpmbuild -bs $(SPEC)
	@echo "SRPM: $(SRPM)"

## Build binary RPMs locally in a clean chroot (slow: ~1h on 2 cores)
mock: srpm
	@echo "Building in $(MOCK_CFG) -- this takes a while (RediSearch is ~40 min)."
	@sg mock -c "mock -r $(MOCK_CFG) --resultdir=$(MOCK_RESULT) $(SRPM)"
	@ls -1 $(MOCK_RESULT)/*.rpm | grep -v src.rpm

## Submit the SRPM to Copr (builds all configured chroots)
copr: srpm
	@copr-cli build $(COPR_PROJECT) $(SRPM)

## Install from Copr and run the full module test suite
smoke:
	@scripts/smoke-test.sh copr $(MOCK_CFG)

## Same, but against locally built RPMs (run `make mock` first)
smoke-local:
	@scripts/smoke-test.sh local $(MOCK_RESULT)

## Run rpmlint on the spec, and on built RPMs if present
lint:
	@rpmlint -r sources/$(NAME).rpmlintrc --ignore-unused-rpmlintrc $(SPEC)
	@if ls $(MOCK_RESULT)/*.rpm >/dev/null 2>&1; then \
	  rpmlint -r sources/$(NAME).rpmlintrc --ignore-unused-rpmlintrc $(MOCK_RESULT)/*.rpm; \
	fi

## Full local pipeline: sources, srpm, mock build, lint
all: check-tools sources srpm mock lint

## Remove build artefacts for this version
clean:
	@rm -f $(SRPM)
	@rm -rf $(MOCK_RESULT)
	@echo "Cleaned SRPM and mock results for $(VERSION)-$(RELEASE)."

## Also remove generated tarballs and the cached upstream clone
distclean: clean
	@rm -f $(SOURCEDIR)/redis-*-full.tar.gz \
	       $(SOURCEDIR)/redisjson-vendor-*.tar.gz \
	       $(SOURCEDIR)/redisearch-vendor-*.tar.gz
	@rm -rf $(HOME)/.cache/redis-sources $(HOME)/.cache/redis-smoke
	@echo "Cleaned generated sources and caches."
