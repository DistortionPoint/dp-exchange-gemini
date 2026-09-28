import Config

# Every socket no test aimed elsewhere dials this closed local port, never the venue. See the
# `:websocket_url` seam in this package's socket (or feed) for why.
config :dp_exchange_gemini, websocket_url: "ws://127.0.0.1:9/tier-1-never-dials-a-venue"
