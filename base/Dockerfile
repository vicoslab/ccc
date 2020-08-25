ARG ROOT_IMAGE="ubuntu:18.04"
FROM ${ROOT_IMAGE}
LABEL maintainer "Luka Cehovin Zajc <luka.cehovin@fri.uni-lj.si>"

ENV DEBIAN_FRONTEND noninteractive

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV PATH /opt/conda/bin:$PATH
ENV BASE=/home

RUN apt-get update --fix-missing && \
    apt-get install -y build-essential wget bzip2 ca-certificates libglib2.0-0 libxext6 libsm6 libxrender1 git runit rsyslog cron cmake openssh-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/imklog/s/^/#/' /etc/rsyslog.conf

COPY start_runit /sbin/
COPY etc /etc/

EXPOSE 22
LABEL frp.enabled="true" frp.22="tcp"

ENTRYPOINT ["/sbin/start_runit"]

