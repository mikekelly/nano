# Dedicated Nano VM

Install Colima, Lima, Docker CLI with Compose/Buildx, Python 3 and OpenSSH on the host.
Colima supports macOS and Linux. Linux also needs QEMU and working KVM: `/dev/kvm`
must be readable and writable by your user (usually through the `kvm` group).
macOS needs native Virtualization.framework support (macOS 13 or newer).

Provisioning is an explicit operator step; your coding agent can carry it out using these
instructions. `bin/up` never creates a VM or falls back to another Docker daemon.

From the repository root, create the shared directory and a **new** profile:

```sh
mkdir -p .mounts
# macOS:
colima start nano --vm-type vz --mount-type virtiofs --runtime docker \
  --hostname nano --cpus 4 --memory 6 --disk 100 --activate=false \
  --mount "$PWD/.mounts:w" --ssh-agent=false --kubernetes=false \
  --network-address=false --network-host-addresses=false --port-forwarder none --template=false
# Linux: same command, replacing --vm-type vz --mount-type virtiofs with:
# --vm-type qemu --mount-type 9p
```

Do not repurpose an existing profile that shares your home directory. Inspect its generated
configuration before use. `bin/vm` checks the running VM and generated Lima configuration:
Docker runtime/socket, a single writable mount at this repo's `.mounts`, no SSH-agent
forwarding, no bridged networking, and no automatic application-port forwards. Linux also
requires accessible KVM and evidence of KVM in the running QEMU command. These checks guard
against accidental misconfiguration; they do not attest a compromised host or VM.

Then run `bin/up`. It creates `.mounts/checkout` from the host repository's committed HEAD
on first use, with independent Git objects; ignored, untracked and uncommitted files are
not copied. Existing checkouts are preserved. Commit your doc customizations before the
first start. `.mounts/data` holds logs, state and artifacts. Both paths are writable by
the agents; nothing else on the host is shared. Do not replace them with symlinks outside
`.mounts`. The container image is built from the host repository using Docker's build
context, which excludes `.mounts`, `.env`, logs and archives.

The checkout's origin is the repository's origin URL, not a host directory inaccessible
inside the VM. To preserve run branches locally before reset, fetch them from the checkout
into the host repo, for example:

```sh
git fetch .mounts/checkout 'refs/heads/seedling/*:refs/heads/seedling/*'
```

Publish those branches and record the run on `runs`. `bin/reset` checks that branch tips
are preserved in the host repo, archives `.mounts/data` to `archive/<time>/`, retains
credentials/settings, and resets the checkout to the host repo's current `main`.

## Ports and commands

Only TCP port 4000 is forwarded: container → guest loopback → host `127.0.0.1:4000`.
`bin/up` establishes a dedicated SSH forwarding session and fails if it cannot bind the
port. Colima still forwards its Docker/containerd management sockets and maintains its
SSH connection; these are not container mounts. Application ports are not automatically
forwarded. `http://127.0.0.1:4000` serves both dashboard and API; the guest hostname `nano`
is not assumed to resolve on your host. Never expose this unauthenticated API to the LAN.

Use `bin/docker` for host-side operations, such as `bin/docker logs nano` or
`bin/docker exec nano bin/rpc '1 + 1'`. It validates and explicitly targets the nano
socket, overriding Docker target and builder environment variables. `bin/reset` uses
it too. Direct `docker` commands still use your own chosen context and bypass these checks.
Stop the profile with `colima stop nano`; the dashboard SSH forward then closes.
Restart it with `colima start nano`, then run `bin/up` again.

An existing run in another profile is not migrated automatically. Finish and archive it
before moving its data or replacing the deployment. A profile is dedicated by convention
and verified configuration, not by its name alone; do not run unrelated workloads in it.

References: [Colima profiles](https://colima.run/docs/profiles/),
[configuration](https://colima.run/docs/configuration/),
[Lima QEMU](https://lima-vm.io/docs/config/vmtype/qemu/).
