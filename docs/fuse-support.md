# FUSE support

All CCC images support FUSE through
[`ccc-fuse-sidecar`](https://github.com/vicoslab/ccc-fuse-sidecar) so compute
containers do not need privileged access or `SYS_ADMIN`.

The image includes a static `fusermount3` shim under `/opt/ccc-fuse-sidecar/bin`
and relinks the `fusermount3`/`fusermount` helper names during startup. Startup
also places an `umount` wrapper in `/usr/local/bin` so normal user shells can run
`umount /path/to/fuse-mount`; the wrapper execs `fusermount3 -u "$@"`, and the
FUSE shim sends the request to the sidecar instead of requiring app-side
`SYS_ADMIN`. The real system `/bin/umount` is left in place for root/system
scripts that call it explicitly.

The shim reads `CONTAINER_NAME` from the container environment and forwards it to
the sidecar, allowing Docker-inspect path translation to identify the calling
compute container.

## Deployment requirements

For this to work, the CCC deployment must provide the runtime pieces, not the
image itself:

```bash
--device /dev/fuse:/dev/fuse:rw
-v /run/ccc-fuse-sidecar/<container>:/run/ccc-fuse-sidecar:rw
--label ccc.fuse=enabled
-e CONTAINER_NAME=<container-name>
```

You do not need `--privileged` or app-side `--cap-add SYS_ADMIN`.
