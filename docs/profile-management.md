# Package Installation Profiles

CX profiles save named package sets so a host can switch between repeatable
installation targets such as `development`, `production`, or `gpu-workstation`.

Profiles are stored as JSON. By default the CLI writes to
`~/.config/cx/profiles.json`. Set `CX_PROFILE_STATE` to point at a different
state file for tests, automation, or system-wide provisioning.

## Commands

Create a profile:

```bash
cortex profile create development --package nodejs --package python3 --package docker.io
```

Show the active profile:

```bash
cortex profile active
```

Copy and edit a profile:

```bash
cortex profile copy development production
cortex profile edit production --remove nodejs --add nginx --add certbot
```

Validate before switching:

```bash
cortex profile validate production
```

Switch profiles:

```bash
cortex profile switch production
```

The switch command validates the destination and prints the package delta:

```text
development -> production:
  - nodejs
  + certbot
  + nginx
```

Compare profiles without switching:

```bash
cortex profile diff development production
```

Export and import profiles for sharing:

```bash
cortex profile export production production.cx-profile.json
cortex profile import production.cx-profile.json --name staging
```

Inspect version history:

```bash
cortex profile history production
```

Each create, copy, import, and edit operation appends a version snapshot with the
package list at that point in time. These snapshots make profile changes auditable
and provide a base for future rollback commands.

## Example Workflow

```bash
cortex profile create development -p nodejs -p python3 -p docker.io
cortex profile copy development production
cortex profile edit production --remove nodejs --add nginx --add certbot
cortex profile diff development production
cortex profile switch production
cortex profile export production ./production.cx-profile.json
```

## Validation Rules

- Profile names must be 1-64 characters.
- Profile names may contain letters, numbers, dot, underscore, and dash.
- Package names must be 1-128 characters.
- Package names must start with a letter or number.
- Package names may then contain letters, numbers, plus, dot, underscore, colon, and dash.
- Duplicate package names are removed automatically.
- Import files must use the `cx-profile` export format.
