# Deploy Minecraft Plugin (SFTP)

A public, reusable GitHub Action that uploads a **prebuilt** Minecraft plugin
jar to a server's `plugins/` folder over **SFTP** (e.g. [Bisect Hosting]).
It is upload-only - the jar loads on the server's next restart.

- You build the jar (Gradle/Maven) in your own workflow.
- This action uploads it. No build step, no server restart.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Build your plugin however you normally do:
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "21" }
      - run: ./gradlew build

      - name: Deploy to server
        uses: EduardoLobo23/plugin-deploy-action@v1
        with:
          host: ${{ secrets.SFTP_HOST }}
          port: ${{ secrets.SFTP_PORT }}          # optional, default 22
          username: ${{ secrets.SFTP_USER }}
          password: ${{ secrets.SFTP_PASSWORD }}  # OR private-key, not both
          local-path: build/libs/*.jar
          remote-path: plugins/                   # optional, default plugins/
          clean-pattern: MyPlugin-*.jar           # optional, delete old jars first
          known-hosts: ${{ secrets.SFTP_KNOWN_HOSTS }}  # strongly recommended
```
## Inputs

| Input           | Required           | Default    | Description |
|-----------------|--------------------|------------|-------------|
| `host`          | yes                | -          | SFTP host. |
| `port`          | no                 | `22`       | SFTP port. |
| `username`      | yes                | -          | SFTP username. |
| `password`      | one of pw/key      | -          | SFTP password. Mutually exclusive with `private-key`. |
| `private-key`   | one of pw/key      | -          | SSH private key (PEM contents). Mutually exclusive with `password`. |
| `local-path`    | yes                | -          | Path or glob to the jar(s), e.g. `build/libs/*.jar`. |
| `remote-path`   | no                 | `plugins/` | Remote target directory (relative to the SFTP login home). |
| `clean-pattern` | no                 | -          | Remote glob to delete before upload, e.g. `MyPlugin-*.jar`. Prevents Bukkit "duplicate plugin" crashes from stale versioned jars. |
| `known-hosts`   | no                 | -          | `known_hosts` entry pinning the server's host key. Omit and the connection runs **unverified** (a loud warning is logged). |
| `dry-run`       | no                 | `false`    | Validate inputs and test the connection without writing anything. |

## Outputs

| Output              | Description |
|---------------------|-------------|
| `uploaded-files`    | Space-separated list of jar filenames uploaded. |
| `remote-path`       | The resolved remote directory. |
| `bytes-transferred` | Total bytes uploaded. |

## Setting up secrets

Add these under **Settings -> Secrets and variables -> Actions** in your plugin repo:

- `SFTP_HOST`, `SFTP_PORT`, `SFTP_USER`
- `SFTP_PASSWORD` **or** a `SFTP_PRIVATE_KEY` (prefer a key for automation)
- `SFTP_KNOWN_HOSTS` - get it once with:
  ```bash
  ssh-keyscan -p <port> <host>
  ```
  Paste the output as the secret's value.

### Bisect Hosting notes

- Find `host`, `port`, and `username` under **Files -> SFTP** / **FTP File Access**
  in the panel. Bisect's default credential is your **panel password**.
- SSH keys are safer for CI - add your public key to the server and use
  `private-key` instead of `password`.
- The SFTP login typically lands in the server root, so `plugins/` is the
  correct default `remote-path`.

## How it works

1. Validates inputs (exactly one auth method; `local-path` matches ≥1 file).
2. Masks all secrets in the log.
3. Pins the host key from `known-hosts`, or warns that the host is unverified.
4. Optionally deletes remote jars matching `clean-pattern`.
5. Uploads each jar to `<name>.jar.part`, then atomically renames it over the
   final name - a dropped connection never leaves a truncated, crashing jar.
6. Emits outputs.

## Non-goals (v1)

Building the jar; restarting/reloading the server; FTP/FTPS; rollback.

## License

[MIT](LICENSE)

[Bisect Hosting]: https://www.bisecthosting.com/
