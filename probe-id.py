#!/usr/bin/env python3
"""Read the Betterlife BF63112 sensor ID over spidev.

Read-only: reads three registers, enrolls nothing, captures no image, writes
nothing to the sensor.

Protocol taken from dedbin/libfprint-bf63112, libfprint/drivers/bf63112.c:
  read   : write one byte (reg & 0x3f) << 1, then read N bytes   (bf63112_read_register)
  SPI    : mode 0, 8 bits/word, 1 MHz max                        (lines 40-42)
  ID     : reg 0x37 high byte, reg 0x36 low byte                 (lines 48-49)
  rev    : reg 0x3e                                               (line 50)

Run only after spidev is bound to the sensor:
  echo spidev | sudo tee /sys/bus/spi/devices/spi-BF63112:00/driver_override
  echo spi-BF63112:00 | sudo tee /sys/bus/spi/drivers/spidev/bind
"""

import sys

try:
    import spidev
except ImportError:
    sys.exit("missing python3-spidev:  sudo apt install python3-spidev")

BUS, CHIP_SELECT = 0, 0

spi = spidev.SpiDev()
spi.open(BUS, CHIP_SELECT)
spi.mode = 0
spi.bits_per_word = 8
spi.max_speed_hz = 1_000_000


def rd(reg, n=1):
    tx = [(reg & 0x3F) << 1] + [0] * n
    return spi.xfer2(tx)[1:]


hi = rd(0x37)[0]
lo = rd(0x36)[0]
rev = rd(0x3E)[0]
sid = (hi << 8) | lo

print(f"Sensor ID 0x{sid:04x}   revision 0x{rev:02x}")

if sid == 0x5F83:
    print("VERDICT: Route B (dedbin) drives exactly this ID.")
elif sid in (0x6583, 0x6683):
    print("VERDICT: Route B refuses this ID (hardcoded 0x5f83). Route A only.")
elif sid in (0x0000, 0xFFFF):
    print("VERDICT: no valid answer. Sensor is probably held in reset;")
    print("         find the GpioIo line in the sensor _CRS (see runbook).")
else:
    print("VERDICT: unknown ID. No published driver. Stop and report it.")

spi.close()
