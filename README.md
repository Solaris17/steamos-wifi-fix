# SteamOS Wifi Fix

This is a quick and dirty script that is meant for MSI Claws.

This script will attempt to detect your wifi cards pcie address (lspci) and the card name.

It will then grab the upstream linux wifi firmware for your card and install it.

This is needed because steamOS releases trail upstream linux in regards to bundled FW.

Tested on:

MSI Claw 7 AI+
Intel BE200

Branch: Main
Channel: Beta

## How to use

1: Get internet via external dongle or ethernet
2: Download the script
3: ```chmod a+x steamos-wifi-fix.sh```
4: ```./steamos-wifi-fix.sh```
5: Should work
