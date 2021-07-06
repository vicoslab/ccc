ARG ROOT_IMAGE
FROM ${ROOT_IMAGE}
LABEL maintainer "Luka Cehovin Zajc <luka.cehovin@fri.uni-lj.si>"

RUN apt-get clean && \
    apt-get update --fix-missing && \
    apt-get install -y python3-pip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install jupyterlab notebook ipywidgets jupyter-server-proxy

COPY etc /etc/

ENV JUPYTER_PORT 8080

EXPOSE $JUPYTER_PORT
LABEL frp.$JUPYTER_PORT="http"

