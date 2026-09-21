#!/usr/bin/with-contenv bashio
export LOG_LEVEL="$(bashio::config 'log_level')"
bashio::log.info "Starting SNOF Firebase Bridge..."
exec python3 -m bridge.main
