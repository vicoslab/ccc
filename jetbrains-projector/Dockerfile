ARG ROOT_IMAGE
FROM ${ROOT_IMAGE}

ENV DEBIAN_FRONTEND noninteractive

LABEL maintainer "Domen Tabernik <domen.tabernik@fri.uni-lj.si>"

RUN apt-get clean && \
    apt-get update --fix-missing && \
    apt-get install -y --no-install-recommends less libxext6 libxrender1 libxtst6 libfreetype6 libxi6 -y && \
    apt-get auto-remove -y && \
    rm -rf /var/lib/apt/lists/*
    
COPY etc /etc/

WORKDIR /
