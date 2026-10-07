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
