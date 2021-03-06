.PHONY: lint test clean clean-dist update-deps list-outdated-deps dist \
	build-docker build-python3-docker build-pypy-docker push-docker \
	push-python3-docker push-pypy-docker push-latest-docker \
	deployment-test release-test

TESTFILES := $(wildcard test/test_*.py)
TESTS := $(subst test/,,$(subst .py,,${TESTFILES}))

CODEFILES := $(wildcard orm/*.py *.py)
LINTFILES := $(patsubst %.py,lint_%,${CODEFILES})

ACTIVATE_VENV := @. env/bin/activate &&

ORM_TAG := $(shell git describe --tags)

DOCKER ?= docker
DOCKER_IMAGE_BASE_NAME ?= svtwebcoreinfra/orm
PYPI_PACKAGE_NAME = origin-routing-machine

PYTHON ?= python3

env: requirements.txt
	virtualenv -p ${PYTHON} env
	. env/bin/activate && \
		pip install -r build_requirements.txt && \
		pip-sync build_requirements.txt requirements.txt && \
		touch env

update-deps:
	virtualenv -p ${PYTHON} update_deps
	@. update_deps/bin/activate && \
		CUSTOM_COMPILE_COMMAND="make $@" \
		  pip install 'pip-tools>=2.0,<3' && \
			pip-compile --upgrade --output-file requirements.txt setup.py && \
			pip-compile --upgrade --output-file build_requirements.txt build_requirements.in
	rm -rf update_deps

list-outdated-deps: env
	@. env/bin/activate && \
		pip list --outdated

lint: env
	@. env/bin/activate && \
		echo 'lint code' && pylint ${CODEFILES} && \
		echo 'lint tests' && pylint --disable=similarities ${TESTFILES}

${LINTFILES}:
	@. env/bin/activate && \
		pylint $(subst lint_,,$@).py

test: env ${TESTS}

${TESTS}:
	@echo "Test: $@"
	@. env/bin/activate && \
		PYTHONPATH=. python test/$@.py

dist: clean-dist env
	. env/bin/activate && \
		ORM_TAG=${ORM_TAG} python setup.py sdist

clean-deployment-test:
	rm -f orm-rules-tests/globals-test/cache.pkl
	rm -f orm-rules-tests/rules-test/cache.pkl

clean-dist:
	rm -rf dist *.egg-info

clean: clean-dist clean-deployment-test
	rm -rf env
	rm -rf out
	rm -rf orm/__pycache__
	@echo "all clean. here we go."

build-docker: build-python3-docker build-pypy-docker

build-python3-docker: clean-dist
	${DOCKER} build \
		--build-arg ORM_TAG=${ORM_TAG} \
		-t ${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG}-python3 \
		-f .docker/Dockerfile-python3 .

# Build the pypy image and tag it with latest and the ORM_TAG.
# This enables pypy to be the default docker image
build-pypy-docker: clean-dist
ifeq (,$(findstring -,$(ORM_TAG)))
	@echo "Building and tagging with latest."
	${DOCKER} build \
		--build-arg ORM_TAG=${ORM_TAG} \
		-t ${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG}-pypy \
		-t ${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG} \
		-t ${DOCKER_IMAGE_BASE_NAME}:latest \
		-f .docker/Dockerfile-pypy .
else
	@echo "Not tagging latest for pre-release versions"
	${DOCKER} build \
		--build-arg ORM_TAG=${ORM_TAG} \
		-t ${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG}-pypy \
		-t ${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG} \
		-f .docker/Dockerfile-pypy .
endif

push-docker: push-python3-docker push-pypy-docker push-latest-docker
	${DOCKER} push "${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG}"

push-python3-docker: build-python3-docker
	${DOCKER} push "${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG}-python3"

push-pypy-docker: build-pypy-docker
	${DOCKER} push "${DOCKER_IMAGE_BASE_NAME}:${ORM_TAG}-pypy"

# Only push the latest tag for non pre-release versions
# NOTICE: The following will only match "-" as part of the tag.
push-latest-docker: build-pypy-docker
ifeq (,$(findstring -,$(ORM_TAG)))
	@echo "Pushing latest tag to the hub"
	${DOCKER} push "${DOCKER_IMAGE_BASE_NAME}:latest"
else
	@echo "Not pushing latest for pre-release versions"
endif

dist/orm-%.tar.gz: orm
	make dist

build-orm-deployment:
	make -C lxd

lxd/dist/orm-image.tar.gz:
	mkdir lxd/dist
	make build-orm-deployment

start-orm-deployment: lxd/dist/orm-image.tar.gz
	lxc image show orm >/dev/null 2>&1 || lxc image import lxd/dist/orm-image.tar.gz --alias orm
	lxc info orm >/dev/null 2>&1 || lxc launch orm orm
	(lxc info orm | grep -q 'Status: Running') || lxc start orm

deployment-test: env dist/orm-${ORM_TAG}.tar.gz start-orm-deployment
	. env/bin/activate && \
		pip install dist/${PYPI_PACKAGE_NAME}-${ORM_TAG}.tar.gz
	@echo "Linting deployment test rules"
	. env/bin/activate && \
		yamllint -c orm-rules-tests/.yamllint orm-rules-tests/
	@echo "Testing rules without globals actions"
	orm-rules-tests/start_echo_servers.sh
	. env/bin/activate && \
    orm \
			-r 'orm-rules-tests/rules-test/rules/**/*.yml' \
			-G 'orm-rules-tests/rules-test/globals.yml' \
			--cache-path 'orm-rules-tests/rules-test/cache.pkl' \
			-o out
	lxd/update-orm-config.sh out
	orm-rules-tests/wait_for_orm.sh
	. env/bin/activate && \
		lxd/test-orm-config.sh 'orm-rules-tests/rules-test/rules/**/*.yml' && \
		lxc file push orm-rules-tests/test-maxconn-maxqueue-haproxy-output.sh orm/root/ && \
		lxc exec orm /root/test-maxconn-maxqueue-haproxy-output.sh

	@echo "Testing rules with globals actions"
	orm-rules-tests/start_echo_servers.sh
	. env/bin/activate && \
    orm \
			-r 'orm-rules-tests/globals-test/rules/**/*.yml' \
			-G 'orm-rules-tests/globals-test/globals.yml' \
				--cache-path 'orm-rules-tests/globals-test/cache.pkl' \
			-o out
	lxd/update-orm-config.sh out
	orm-rules-tests/wait_for_orm.sh
	. env/bin/activate && \
		lxd/test-orm-config.sh 'orm-rules-tests/globals-test/rules/**/*.yml'

release-test:
	make clean
	make lint
	make test
	make deployment-test
