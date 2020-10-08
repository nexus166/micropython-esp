
## [mpy-esp.sh]
MicroPython build/flash tool for Espressif boards
```sh
# USAGE

BUILD: TINYPICO (M5STICK-C) using ESP-IDF v4.2-dev
#> mpy-esp.sh -p esp32 -b TINYPICO -e v4.2-dev build
FLASH: latest image from registry
#> mpy-esp.sh -p esp32 -b GENERIC_SPIRAM flash
SHELL: start rshell on /dev/ttyUSB0
$> mpy-esp.sh -p esp32 shell

OPTION	EXAMPLE						DESC
-f	ubuntu:bionic					dockerfile FROM for build environment
-e	v4.2-dev					ESP-IDF version (branch/tag/git_commit)
-E	https://github.com/espressif/esp-idf.git	repository to clone the espressif-idf from
-m	v1.13						MicroPython version
-M	https://github.com/micropython/micropython.git	repository to clone MicroPython from
-p	esp32						MicroPython port
-b	TINYPICO					MicroPython board
-P	<bool>						build: push built image to target registry, flash: pull latest image from target registry
-r	docker.io/nexus166				target registry
-t	/dev/ttyUSB1					serial port
```
