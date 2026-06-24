ARG ROOT_IMAGE="ubuntu:18.04"
ARG CCC_FUSE_CLIENT_IMAGE="vicoslab/ccc-fuse-sidecar:client-latest"

FROM ${CCC_FUSE_CLIENT_IMAGE} AS ccc_fuse_client
FROM ${ROOT_IMAGE}
LABEL maintainer "Luka Cehovin Zajc <luka.cehovin@fri.uni-lj.si>"

ENV DEBIAN_FRONTEND noninteractive

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV BASE=/home
env LOCAL_SSD_STORAGE /storage/local/ssd
ENV CCC_FUSE_SIDECAR_SOCKET=/run/ccc-fuse-sidecar/fuse.sock

RUN apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y build-essential wget bzip2 ca-certificates \
			libglib2.0-0 libxext6 libsm6 libxrender1 libgl1 libglx-mesa0 libglu1-mesa libxt6 libxtst6 libxi6 \
			nano htop tmux curl git cmake \
			runit rsyslog cron  openssh-server && \
    mkdir -p /run/ccc-fuse-sidecar && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    for f in /etc/rsyslog.conf /etc/rsyslog.d/*.conf; do \
        [ -f "$f" ] || continue; \
        sed -i \
            -e '/imklog/s/^/#/' \
            -e '/^[[:space:]]*\$KLogPermitNonKernelFacility\>/s/^/#/' \
            -e '/^[[:space:]]*KLogPermitNonKernelFacility\>/s/^/#/' \
            -e '/\/dev\/xconsole/s/^/#/' \
            "$f"; \
    done

# remove any smylinkg for service which can sometimes cause issued during copy
RUN rm -f /etc/service 2> /dev/null || true

COPY start_runit /sbin/
COPY start_wrapped /sbin/
COPY etc/ /etc/
COPY --from=ccc_fuse_client /usr/local/bin/fusermount3 /opt/ccc-fuse-sidecar/bin/fusermount3
RUN set -eux; \
    for dir in /usr/local/bin /usr/bin /bin; do \
        mkdir -p "$dir"; \
        ln -sfn /opt/ccc-fuse-sidecar/bin/fusermount3 "$dir/fusermount3"; \
        ln -sfn /opt/ccc-fuse-sidecar/bin/fusermount3 "$dir/fusermount"; \
        ln -sfn /opt/ccc-fuse-sidecar/bin/fusermount3 "$dir/fusemount3"; \
        ln -sfn /opt/ccc-fuse-sidecar/bin/fusermount3 "$dir/fusemount"; \
    done

# Optionally bake the ccc-agent-containment runtime (bwrap + branchfs binary +
# the ccc-agent-containment pip package) into the image so an enabled container
# starts instantly instead of building rust/branchfs on first boot.  Off by
# default to keep base images lean; build with
#   --build-arg CCC_AGENT_CONTAINMENT_PREINSTALL=1
# The runit startup (etc/runit_init.d/06_ccc_agent_containment.sh) still runs at
# boot and reinstalls/updates only when a NEWER ref is requested via env
# (CCC_AGENT_CONTAINMENT_REF / _BRANCHFS_REF, or *_UPDATE=1).  Keep these ref
# defaults in sync with setup_ccc_agents.sh so a stock container is a no-op.
ARG CCC_AGENT_CONTAINMENT_PREINSTALL=0
ARG CCC_AGENT_CONTAINMENT_REF=master
ARG CCC_AGENT_CONTAINMENT_BRANCHFS_REF=feat/ccc-agent-containment
RUN set -eux; \
    case "${CCC_AGENT_CONTAINMENT_PREINSTALL}" in \
        1|true|TRUE|yes|YES|on|ON) \
            CCC_AGENT_CONTAINMENT_REF="${CCC_AGENT_CONTAINMENT_REF}" \
            CCC_AGENT_CONTAINMENT_BRANCHFS_REF="${CCC_AGENT_CONTAINMENT_BRANCHFS_REF}" \
                sh /etc/setup_ccc_agents.sh --install-only; \
            apt-get clean; \
            rm -rf /var/lib/apt/lists/*; \
            ;; \
        *) echo "ccc-agent-containment: PREINSTALL off; runtime install at first boot"; ;; \
    esac

EXPOSE 22
LABEL frp.enabled="true" frp.22="tcp"

# Fixed CUDA device order to match nvidia-smi order
ENV CUDA_DEVICE_ORDER PCI_BUS_ID
# Disable device visibility by default
ENV CUDA_VISIBLE_DEVICES -1


ENTRYPOINT ["/sbin/start_wrapped"]

