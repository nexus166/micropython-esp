### initial dependencies, set up environment
ARG	FROM="debian:bullseye-slim"
FROM	$FROM as depsenv
RUN	set -ex; \
	if which apk; then \
		apk update; \
		apk upgrade --no-cache; \
		apk add --no-cache alpine-sdk bash bison build-base cmake flex gcc git gperf jq libc-dev libffi-dev make musl-dev nano ncurses-dev openssl-dev openssl-d-dev python2-dev py3-pip python3-dev wget; \
		addgroup -g 1000 -S mpy-esp; \
		adduser -S -G mpy-esp -h /opt -s /sbin/nologin -u 1000 mpy-esp; \
		adduser mpy-esp dialout; \
		mkdir -vp /lib64; \
		ln -vs /lib/libc.musl-"$(uname -m)".so.1 /lib64/ld-linux-"$(uname -m | tr '_' '-')".so.2; \
		ln -vs /lib/libc.musl-"$(uname -m)".so.1 /lib/ld64.so.1; \
	elif which apt-get; then \
		export DEBIAN_FRONTEND=noninteractive; \
		apt-get update; \
		apt-get dist-upgrade -yqq; \
		apt-get install -yqq bison cmake flex gcc git gperf jq libffi-dev libncurses-dev libssl-dev make nano python2 python3 python3-pip python3-setuptools wget; \
		rm -fv /usr/bin/python; \
		ln -vs $(command -v python3) "$(dirname $(command -v python3))/python"; \
		apt-get clean; \
		rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
		groupadd -g 1000 -r mpy-esp; \
		useradd -r -g mpy-esp -G dialout -d /opt -s /sbin/nologin -u 1000 mpy-esp; \		
	else exit 2; fi; \
	chown -R mpy-esp:mpy-esp /opt
SHELL	["/bin/bash", "-xeuo", "pipefail", "-c"]
USER	mpy-esp
# this is necessary because https://git.savannah.gnu.org/r/lwip does not support shallow submodule cloning
ARG	LWIP_FORK="https://github.com/nexus166/lwIP"
RUN     git config --global url."${LWIP_FORK}".insteadOf https://git.savannah.gnu.org/r/lwip
WORKDIR	/opt

### flash environment
FROM	alpine:edge as flashenv
SHELL	["/bin/ash", "-xeuo", "pipefail", "-c"]
RUN	apk update; \
	apk upgrade --no-cache; \
	apk add --no-cache bash nano py3-pip py-udev; \
	pip3 install --upgrade --no-cache-dir esptool rshell


### install build dependencies
FROM	depsenv as buildenv
# branch or tag to clone, last release if not provided
ARG	MICROPYTHON_VERSION
ARG	MICROPYTHON_VCS="https://github.com/micropython/micropython.git"
ENV	MICROPYTHON_VERSION="${MICROPYTHON_VERSION}" \
	MICROPYTHON_VCS="${MICROPYTHON_VCS}" \
	MICROPYTHON_PATH="/opt/micropython"
RUN     if [[ ! -d ${MICROPYTHON_PATH} ]]; then \
		git clone --branch=${MICROPYTHON_VERSION:-$(wget -qO- "https://api.github.com/repos/micropython/micropython/tags" | jq -r .[].name | sort -Vu | grep -vE 'beta|dev|rc' | tail -1)} \
			--depth=1 --recurse-submodules -j$(nproc) --shallow-submodules \
	                "${MICROPYTHON_VCS}" "${MICROPYTHON_PATH}"; \
	else \
		printf 'Skipping MicroPython repo cloning\n'; \
	fi

# bare-arm  cc3200  esp32  esp8266  javascript  mimxrt  minimal  nrf  pic16bit  powerpc  qemu-arm  samd  stm32  teensy  unix  windows  zephyr ...
ARG     MPY_CROSS_PORT=esp32
ARG	ESPIDF_VERSION
ARG	ESPIDF_VCS="https://github.com/espressif/esp-idf.git"
ENV	MPY_CROSS_PORT="${MPY_CROSS_PORT}" \
	ESPIDF_VERSION="${ESPIDF_VERSION}" \
	ESPIDF_VCS="${ESPIDF_VCS}" \
	ESPIDF="/opt/esp-idf" \
	IDF_PATH="/opt/esp-idf"
RUN	if [[ ! -d ${ESPIDF} ]]; then \
		git clone "${ESPIDF_VCS}" "${ESPIDF}"; \
		cd "${ESPIDF}"; \
		git checkout ${ESPIDF_VERSION:-$(awk '/ESPIDF_SUPHASH_V4 :=/ {print $3}' "${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"/Makefile)}; \
		git submodule update --init --recursive; \
		chown -R mpy-esp:mpy-esp "${ESPIDF}"; \
	else \
		printf 'Skipping ESP-IDF repo cloning\n'; \
	fi
USER	root
RUN	cd "${ESPIDF}"; \
	pip3 install --upgrade --no-cache-dir --requirement requirements.txt; \
	export IDF_PATH=$(pwd); \
	if [[ -f ./tools/idf_tools.py ]]; then \
		./tools/idf_tools.py install; \
	elif [[ -f ./install.sh ]]; then \
		./install.sh; \
	else \
		_tmpdir=$(mktemp -d); \
		python ./docs/gen-toolchain-links.py "$(find . -type f -name toolchain_versions.mk)" "https://dl.espressif.com/dl/" "${_tmpdir}"; \
		wget -qO- $(grep -Eo 'https://[^"]+linux64.*' "${_tmpdir}/download-links.inc") | tar zx --strip-components=1 -C /usr; \
		exit 0; \
	fi; \
	cd /root/.espressif/tools; \
	find . -maxdepth 3 -type d | tail -n +2 | while read; do \
		read; \
		read _d; \
		_d="$(realpath "$_d")"; \
		mv -fv "${_d}" "/usr/local/$(basename "${_d}")"; \
	done; \
	rm -fr /root/.espressif
ENV	PATH="/usr/local/xtensa-esp32-elf/bin:/usr/local/bin:$PATH"
RUN	cd "${MICROPYTHON_PATH}"; \
	_mpycross="$(find . -type d -name mpy-cross | head -1)"; \
	if [[ -d ${_mpycross} ]]; then \
		cd ${_mpycross}; \
		make -j$(nproc); \
		cp mpy-cross /usr/bin/; \
	fi
USER	mpy-esp

### compile
FROM	buildenv AS compile

ARG     HAS_BT=1
ARG	CONFIG_MICROPY_PY_FRAMEBUF=y
ARG	CONFIG_MICROPY_PY_USE_BTREE=y
ARG	CONFIG_MICROPY_USE_WEBSOCKETS=y
ARG	CONFIG_MICROPY_USE_DISPLAY=y
ARG	CONFIG_MICROPY_USE_TFT=y
ARG	CONFIG_MICROPY_USE_EPD=
ARG	CONFIG_MICROPY_USE_EVE=
ARG	CONFIG_MICROPY_USE_GSM=
ARG	CONFIG_MICROPY_USE_GPS=
ARG	CONFIG_MICROPY_USE_ETHERNET=
ARG	CONFIG_MICROPY_USE_MDNS=y
ARG	CONFIG_MICROPY_USE_REQUESTS=y
ARG	CONFIG_MICROPY_USE_CURL=
ARG	CONFIG_MICROPY_USE_SSH=y
ARG	CONFIG_MICROPY_USE_MQTT=

# GENERIC  GENERIC_D2WD  GENERIC_OTA  GENERIC_SPIRAM  TINYPICO ...
ARG	BOARD=TINYPICO
ENV	BOARD="${BOARD}"

ARG	USER_C_MODULES
ENV	USER_C_MODULES="${USER_C_MODULES}"

ARG	CFLAGS
ARG	CXXFLAGS
ARG	LDFLAGS
ENV	CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" LDFLAGS="${LDFLAGS}"

COPY	--chown=mpy-esp:mpy-esp	./boards/"${BOARD}"/extra.mk	/tmp/"${BOARD}".mk
COPY	--chown=mpy-esp:mpy-esp	./boards/"${BOARD}"/		"${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"/
COPY	--chown=mpy-esp:mpy-esp	./modules/*.py			"${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"/modules/
COPY	--chown=mpy-esp:mpy-esp	./modules/micropython/		"${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"/modules/
COPY	--chown=mpy-esp:mpy-esp	./modules/"${BOARD}"/		"${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"/modules/
COPY	--chown=mpy-esp:mpy-esp ./modules/frozen_extras/	/opt/frozen_extras/
RUN	cd "${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"; \
	ls -lt *; \
	mkdir -vp boards/${BOARD}/; \
	if [[ -f ./modules/_boot_extra.py ]]; then cat ./modules/_boot_extra.py >> ./modules/_boot.py; rm ./modules/_boot_extra.py; fi; \
	SDKCONFIG="boards/${BOARD}/sdkconfig.board"; \
	tee -a "${SDKCONFIG}" <<<'CONFIG_OPTIMIZATION_LEVEL_DEBUG='; \
	tee -a "${SDKCONFIG}" <<<'CONFIG_OPTIMIZATION_LEVEL_RELEASE=y'; \
	tee -a "${SDKCONFIG}" <<<'CONFIG_MICROPY_USE_RFCOMM=y'; \
	{ \
		printf 'CONFIG_MICROPY_PY_FRAMEBUF=%s\n' "${CONFIG_MICROPY_PY_FRAMEBUF}"; \
		printf 'CONFIG_MICROPY_PY_USE_BTREE=%s\n' "${CONFIG_MICROPY_PY_USE_BTREE}"; \
		printf 'CONFIG_MICROPY_USE_WEBSOCKETS=%s\n' "${CONFIG_MICROPY_USE_WEBSOCKETS}"; \
		printf 'CONFIG_MICROPY_USE_DISPLAY=%s\n' "${CONFIG_MICROPY_USE_DISPLAY}"; \
		printf 'CONFIG_MICROPY_USE_TFT=%s\n' "${CONFIG_MICROPY_USE_TFT}"; \
		printf 'CONFIG_MICROPY_USE_EPD=%s\n' "${CONFIG_MICROPY_USE_EPD}"; \
		printf 'CONFIG_MICROPY_USE_EVE=%s\n' "${CONFIG_MICROPY_USE_EVE}"; \
		printf 'CONFIG_MICROPY_USE_GSM=%s\n' "${CONFIG_MICROPY_USE_GSM}"; \
		printf 'CONFIG_MICROPY_USE_GPS=%s\n' "${CONFIG_MICROPY_USE_GPS}"; \
		printf 'CONFIG_MICROPY_USE_ETHERNET=%s\n' "${CONFIG_MICROPY_USE_ETHERNET}"; \
		printf 'CONFIG_MICROPY_USE_MDNS=%s\n' "${CONFIG_MICROPY_USE_MDNS}"; \
		printf 'CONFIG_MICROPY_USE_REQUESTS=%s\n' "${CONFIG_MICROPY_USE_REQUESTS}"; \
		printf 'CONFIG_MICROPY_USE_CURL=%s\n' "${CONFIG_MICROPY_USE_CURL}"; \
		printf 'CONFIG_MICROPY_USE_SSH=%s\n' "${CONFIG_MICROPY_USE_SSH}"; \
		printf 'CONFIG_MICROPY_USE_MQTT=%s\n' "${CONFIG_MICROPY_USE_MQTT}"; \
	} | tee -a "${SDKCONFIG}"; \
	if [[ ${HAS_BT} == 1 ]] && [[ -f boards/sdkconfig.ble ]]; then \
		tee -a "${SDKCONFIG}" <<<'SDKCONFIG += boards/sdkconfig.ble'; \
	fi; \
	_chip_upper="$(tr '[:lower:]' '[:upper:]' <<<"${MPY_CROSS_PORT}")"; \
	printf 'CONFIG_MICROPY_HW_BOARD_NAME="%s board"\nCONFIG_MICROPY_HW_MCU_NAME="%s"\nCONFIG_MICROPY_TIMEZONE="%s"\n' "${_chip_upper}" "${_chip_upper}" "$(date +%Z)" | tee -a "${SDKCONFIG}"; \
	tee -a "${SDKCONFIG}" <<<"$(</tmp/${BOARD}.mk)"; \
	make clean BOARD="${BOARD}" || true; \
	make -j$(nproc) USER_C_MODULES="${USER_C_MODULES}" BOARD="${BOARD}" all || make -j$(nproc) USER_C_MODULES="${USER_C_MODULES}" BOARD="${BOARD}" all V=1; \
	if [[ $(find /opt/frozen_extras -type f -name '*.py' | wc -l) -gt 0 ]]; then \
		"${MICROPYTHON_PATH}"/tools/mpy_cross_all.py -mcache-lookup-bc -o /opt/frozen_extras/out --target xtensa /opt/frozen_extras; \
	fi
USER	root
RUN	mkdir -vp /out; \
	cd "${MICROPYTHON_PATH}"/ports/"${MPY_CROSS_PORT}"/build-"${BOARD}"/; \
	mv -f *.bin frozen_content.c sdkconfig.combined /out/; \
	if [[ -d /opt/frozen_extras/out ]] && [[ $(find /opt/frozen_extras/out -type f | wc -l) -gt 0 ]]; then \
		mv -f /opt/frozen_extras/out /out/frozen_extras; \
	fi

FROM	flashenv AS release
COPY	--from=compile /etc/passwd /etc/group /etc/
ARG     MPY_CROSS_PORT=esp32
ARG     BOARD=TINYPICO
COPY	--from=compile /out /out/
WORKDIR	/out
ARG     FLASH_COMPRESSED
ARG     FLASH_MODE=keep
ARG     FLASH_FREQ=keep
ARG     FLASH_SIZE=detect
ARG	TTY_DEV="/dev/ttyUSB0"
ENV     FLASH_COMPRESSED="${FLASH_COMPRESSED}" \
        FLASH_MODE="${FLASH_MODE}" \
        FLASH_FREQ="${FLASH_FREQ}" \
        FLASH_SIZE="${FLASH_SIZE}" \
	TTY_DEV="${TTY_DEV}"
RUN	_esptool="$(command -v esptool.py)"; \
	_rshell="$(command -v rshell)"; \
	{ \
		printf '#!/bin/bash -xe\nsha256sum -c sha256.txt\n'; \
		printf '%s --chip %s image_info firmware.bin\n' "$_esptool" "$MPY_CROSS_PORT"; \
		printf '%s --chip %s --before default_reset --after hard_reset erase_flash\n' "$_esptool" "$MPY_CROSS_PORT"; \
		printf '%s --chip %s --before default_reset --after hard_reset write_flash %s --flash_mode %s --flash_freq %s --flash_size %s 0x1000 firmware.bin\n' "$_esptool" "$MPY_CROSS_PORT" "${FLASH_COMPRESSED}" "${FLASH_MODE}" "${FLASH_FREQ}" "${FLASH_SIZE}"; \
		if [[ -d /out/frozen_extras ]]; then printf '%s -p %s cp -r frozen_extras/* /pyboard/\n' "${_rshell}" "${TTY_DEV}"; fi; \
	} | tee /usr/bin/entrypoint.sh; \
	chmod -v +x /usr/bin/entrypoint.sh; \
	sha256sum *bin | tee sha256.txt; \
	chmod -v o+r /out/*; \
	cat sdkconfig.combined
USER	mpy-esp
CMD	[ "/usr/bin/entrypoint.sh" ]
