# Restricting the node's network

As shipped, the node's outbound network is unrestricted, and agents are told so in their
system prompt, from the `network_policy` setting. That text must stay true. To let the node
reach only the model providers, put it on an internal Docker network whose only exits are
TCP relays, one per host (drop the ChatGPT ones if you don't use a subscription, and their
hosts from the text). Save this as `docker-compose.override.yml` next to
`docker-compose.yml`:

```yaml
services:
  nano:
    ports: !reset []
    networks: [sandbox]
    extra_hosts: ["openrouter.ai:10.99.0.2", "chatgpt.com:10.99.0.3", "auth.openai.com:10.99.0.4"]
  out: # the ways out: TCP relays to the providers' port 443 (TLS stays end to end)
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:openrouter.ai:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.2 }, default: {} }
  out-chatgpt:
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:chatgpt.com:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.3 }, default: {} }
  out-auth:
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:auth.openai.com:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.4 }, default: {} }
  in: # the way in: the host's localhost:4000, relayed to the node
    image: alpine/socat
    command: TCP-LISTEN:4000,fork,reuseaddr TCP:nano:4000
    restart: unless-stopped
    ports: ["127.0.0.1:4000:4000"]
    networks: [sandbox, default]
networks:
  sandbox:
    internal: true
    ipam: { config: [{ subnet: 10.99.0.0/24, ip_range: 10.99.0.128/25 }] }
```

and in `.env`:

```
NETWORK_POLICY=only openrouter.ai:443, chatgpt.com:443 and auth.openai.com:443 are reachable outside this container
```

Agents keep the text they started with, so start the agents that should see the new network
after changing both.

### Trusted-local API compatibility change
All unsafe `/api` requests, even bodyless POST and DELETE, require exactly one
`X-Nano-API-Intent: mutate` header. Without it the server returns HTTP 403
`api_intent_required`. An Origin, when present, must match configured trust;
Host and forwarded headers never establish trust. Payloads must be one JSON object;
queries, method overrides, duplicate JSON keys and path-key collisions are refused.
Bodyless actions accept no body or `{}`. There is no legacy grace path.

```sh
curl -s -X POST localhost:4000/api/users/me/inbox/consume -H 'X-Nano-API-Intent: mutate'
curl -s -X DELETE localhost:4000/api/settings/EXAMPLE -H 'X-Nano-API-Intent: mutate'
```

GET/HEAD inbox is read-only, and `?clear` is rejected. OAuth initiation is a
CSRF-protected browser POST; only the one-use PKCE GET callback may exchange.
This is an intent barrier, not authentication: authorized same-origin JavaScript,
local root clients and trusted proxies retain node authority. Keep loopback exposure.
Deployment trust is `NANO_API_PUBLIC_PORT` (default 4000),
`NANO_API_TRUSTED_ORIGINS` (JSON array; default localhost/127.0.0.1/[::1] HTTP at
that port) and `NANO_OPENROUTER_CALLBACK_URL` (fixed `/openrouter/callback`, default
http://localhost:4000/openrouter/callback). Proxies require explicit external trust
and callback configuration. Invalid policy blocks mutations/initiation with 503;
read-only repair remains available. Explicit empty origins trusts no Origin.
