#!/bin/bash
# Doppio clic su questo file per avviare la Mediateca.
# Modifica le cartelle qui sotto se tieni i video altrove.
cd "$(dirname "$0")"
exec python3 mediateca.py ~/Movies ~/Downloads --port 8777
