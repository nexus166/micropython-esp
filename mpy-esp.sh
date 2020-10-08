#!/usr/bin/env bash

set -eo pipefail

FROM="debian:bullseye-slim"

BOARD="${BOARD:-TINYPICO}"
MPY_CROSS_PORT="${MPY_CROSS_PORT:-esp32}"
TTY_DEV="${TTY_DEV:-/dev/ttyUSB0}"

REGISTRY="${REGISTRY:-docker.io/nexus166}"
REPO="${REPO}"
PULL_PUSH=0

ESPIDF_VERSION="${ESPIDF_VERSION}"
ESPIDF_VCS="${ESPIDF_VCS:-https://github.com/espressif/esp-idf.git}"
MICROPYTHON_VERSION="${MICROPYTHON_VERSION}"
MICROPYTHON_VCS="${MICROPYTHON_VCS:-https://github.com/micropython/micropython.git}"

_help() {
	local _h1=$'
.
[_SELF_]
MicroPython build/flash tool for Espressif boards
.
'
	local _h2=$'
.
# USAGE
.
BUILD: TINYPICO (M5STICK-C) using ESP-IDF v4.2-dev
#> _SELF_ -p esp32 -b TINYPICO -e v4.2-dev build
FLASH: latest image from registry
#> _SELF_ -p esp32 -b GENERIC_SPIRAM flash
SHELL: start rshell on /dev/ttyUSB0
$> _SELF_ -p esp32 shell
.
OPTION\tEXAMPLE\tDESC
-f\tubuntu:bionic\tdockerfile FROM for build environment
-e\tv4.2-dev\tESP-IDF version (branch/tag/git_commit)
-E\thttps://github.com/espressif/esp-idf.git\trepository to clone the espressif-idf from
-m\tv1.13\tMicroPython version
-M\thttps://github.com/micropython/micropython.git\trepository to clone MicroPython from
-p\tesp32\tMicroPython port
-b\tTINYPICO\tMicroPython board
-P\t<bool>\tbuild: push built image to target registry, flash: pull latest image from target registry
-r\tdocker.io/nexus166\ttarget registry
-t\t/dev/ttyUSB1\tserial port
'
	sed "s/_SELF_/$(basename ${0})/g" <<<"${_h1}"
	column -t -s $'\t' <<<"${_h2}" | sed "s/_SELF_/$(basename ${0})/g"
}

while getopts ":e:E:b:p:m:M:r:R:f:t:Ph" _opt; do
	case "${_opt}" in
		f) FROM="${OPTARG}" ;;
		b) BOARD="${OPTARG}" ;;
		p) MPY_CROSS_PORT="${OPTARG}" ;;
		e) ESPIDF_VERSION="${OPTARG}" ;;
		E) ESPIDF_VCS="${OPTARG}" ;;
		m) MICROPYTHON_VERSION="${OPTARG}" ;;
		M) MICROPYTHON_VCS="${OPTARG}" ;;
		r) REGISTRY="${OPTARG}" ;;
		R) REPO="${OPTARG}" ;;
		P) PULL_PUSH=1 ;;
		t) TTY_DEV="${OPTARG}" ;;
		h)
			_help
			exit 0
			;;
	esac
done
shift $((OPTIND - 1))

MODE=build
case "${1}" in
	"b"* | "B"*) MODE=build ;;
	"f"* | "F"*) MODE=flash ;;
	"s"* | "S"*) MODE=shell ;;
	"h"* | "H"*)
		_help
		exit 0
		;;
	*)
		_help
		exit 127
		;;
esac

REPO="${REPO:-micropython-esp/$(tr '[:upper:]' '[:lower:]' <<<"${MPY_CROSS_PORT}")-$(tr '[:upper:]' '[:lower:]' <<<"${BOARD}")}"

if [[ ${ESPIDF_VERSION} == "latest" ]]; then
	ESPIDF_VERSION=$(wget -qO- "https://api.github.com/repos/espressif/esp-idf/tags" | jq -r .[].name | sort -Vu | grep -vE 'beta|dev|rc' | tail -1)
fi

if [[ -z ${MICROPYTHON_VERSION} ]]; then
	MICROPYTHON_VERSION=$(wget -qO- "https://api.github.com/repos/micropython/micropython/tags" | jq -r .[].name | sort -Vu | grep -vE 'beta|dev|rc' | tail -1)
fi

TAG="${MICROPYTHON_VERSION}"
if [[ -n ${ESPIDF_VERSION} ]]; then
	TAG+="_idf-${ESPIDF_VERSION}"
fi

_build_args() {
	set +x
	if [[ -n ${ESPIDF_VERSION} ]]; then
		printf ' --build-arg ESPIDF_VERSION="%s"' "${ESPIDF_VERSION}"
	fi
	if [[ -n ${ESPIDF_VCS} ]]; then
		printf ' --build-arg ESPIDF_VCS="%s"' "${ESPIDF_VCS}"
	fi
	if [[ -n ${MICROPYTHON_VERSION} ]]; then
		printf ' --build-arg MICROPYTHON_VERSION="%s"' "${MICROPYTHON_VERSION}"
	fi
	if [[ -n ${MICROPYTHON_VCS} ]]; then
		printf ' --build-arg MICROPYTHON_VCS="%s"' "${MICROPYTHON_VCS}"
	fi
	sort -Vu build-args.env | while read i; do
		case "${i}" in
			"" | $'\n') continue ;;
			*)
				local _n="$(cut -d'=' -f1 <<<"${i}")"
				local _v="$(cut -d'=' -f2 <<<"${i}")"
				if [[ -n ${_n} ]]; then
					printf ' --build-arg %s="%s"' "${_n}" "${_v}"
				fi
				;;
		esac
	done
	if [[ -n ${CFLAGS} ]]; then
		printf ' --build-arg CFLAGS="%s"' "${CFLAGS}"
	fi
	if [[ -n ${CXXFLAGS} ]]; then
		printf ' --build-arg CXXFLAGS="%s"' "${CXXFLAGS}"
	fi
	if [[ -n ${LDFLAGS} ]]; then
		printf ' --build-arg LDFLAGS="%s"' "${LDFLAGS}"
	fi
	set -x
}

_stage="release"

set -x
case "${MODE}" in
	build)
		_run_after=1
		case "${2}" in
			"" | $'\n') _run_after=0 ;;
			*) _stage="${2}" ;;
		esac
		DOCKER_BUILDKIT=1 eval "docker build --progress plain \
                --target "${_stage}" \
                --compress --squash --pull \
                --rm --force-rm \
                --build-arg FROM="${FROM}" \
                --build-arg BOARD="${BOARD}" \
                --build-arg MPY_CROSS_PORT="${MPY_CROSS_PORT}" \
                --build-arg TTY_DEV="${TTY_DEV}" \
                --build-arg USER_C_MODULES="${USER_C_MODULES}" \
                $(_build_args) \
                --tag "${REGISTRY}/${REPO}:${TAG}" \
                --file Dockerfile ."
		if [[ ${_run_after} == 1 ]]; then
			docker run -ti --env BOARD="${BOARD}" --env MPY_CROSS_PORT="${MPY_CROSS_PORT}" ${@:3} "${REGISTRY}/${REPO}:${TAG}"
		elif [[ ${PULL_PUSH} == 1 ]]; then
			docker push "${REGISTRY}/${REPO}:${TAG}"
		fi
		;;
	flash)
		if [[ ${PULL_PUSH} == 1 ]]; then
			docker pull "${REGISTRY}/${REPO}:${TAG}"
		fi
		docker run -ti --rm --privileged -v "${TTY_DEV}:${TTY_DEV}" "${REGISTRY}/${REPO}:${TAG}"
		;;
	shell) docker run -ti --rm --privileged -v "${TTY_DEV}:${TTY_DEV}" "${REGISTRY}/${REPO}:${TAG}" rshell -p "${TTY_DEV}" --editor nano ;;
esac
set +x
