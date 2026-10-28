#!/bin/bash
# ABOUTME: The oracle project's Stop hook: reads its input and exits at once, so every launch has a Stop hook phase as spike Q3's project did.
# ABOUTME: It never blocks the stop.
cat >/dev/null
exit 0
