<h1 align="center">SteamOS Wifi Fix</h1>

> [!NOTE]
> *This tool and its author are not affiliated with Valve in any way.*

> [!TIP]
> **Please do not request install help in this repo!**

## About

This is a quick and dirty script that is meant for MSI Claws.

This script will attempt to detect your wifi cards pcie address (lspci) and the card name.

It will then grab the upstream linux wifi firmware for your card and install it.

This is needed because steamOS releases trail upstream linux in regards to bundled FW.

-----

## Tested on

MSI Claw 7 AI+ (A2VM)
Intel BE200

OS Update Channel: Main
Steam Client Update Channel: Beta

This is not exclusive to handhelds and may work on other devices.

-----

## How to use

- Get internet via external dongle or ethernet
- Download the script
- ```chmod a+x steamos-wifi-fix.sh```
- ```./steamos-wifi-fix.sh```
- Should work
