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
			libglib2.0-0 libxext6 libsm6 libxrender1 libgl1 libglu1-mesa libxt6 libxtst6 libxi6 \
			nano htop tmux curl git cmake \
			runit rsyslog cron  openssh-server && \
    mkdir -p /run/ccc-fuse-sidecar && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/imklog/s/^/#/' /etc/rsyslog.conf

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

EXPOSE 22
LABEL frp.enabled="true" frp.22="tcp"

# Fixed CUDA device order to match nvidia-smi order
ENV CUDA_DEVICE_ORDER PCI_BUS_ID
# Disable device visibility by default
ENV CUDA_VISIBLE_DEVICES -1


ENTRYPOINT ["/sbin/start_wrapped"]

