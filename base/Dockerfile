ARG ROOT_IMAGE="ubuntu:18.04"
FROM ${ROOT_IMAGE}
LABEL maintainer "Luka Cehovin Zajc <luka.cehovin@fri.uni-lj.si>"

ENV DEBIAN_FRONTEND noninteractive

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV BASE=/home
env LOCAL_SSD_STORAGE /storage/local/ssd

RUN apt-get update --fix-missing && \
    apt-get install -y build-essential wget bzip2 ca-certificates \
			libglib2.0-0 libxext6 libsm6 libxrender1 libgl1-mesa-glx libglu1-mesa libxt6 libxtst6 libxi6 \
			nano htop tmux curl git cmake \
			runit rsyslog cron  openssh-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/imklog/s/^/#/' /etc/rsyslog.conf

# remove any smylinkg for service which can sometimes cause issued during copy
RUN rm -f /etc/service 2> /dev/null || true

COPY start_runit /sbin/
COPY etc/ /etc/

EXPOSE 22
LABEL frp.enabled="true" frp.22="tcp"

ENV CUDA_DEVICE_ORDER PCI_BUS_ID	# Fixed CUDA device order
ENV CUDA_VISIBLE_DEVICES -1			# Disable device visibility by default


ENTRYPOINT ["/sbin/start_runit"]

