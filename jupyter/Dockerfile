ARG ROOT_IMAGE
FROM ${ROOT_IMAGE}
LABEL maintainer "Luka Cehovin Zajc <luka.cehovin@fri.uni-lj.si>"

RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y python3-pip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04+ ships PEP 668 "externally managed" Python environments, which refuse
# system-wide `pip install`. Allow it so these packages install into the system
# interpreter as before. This option is honoured by recent pip and ignored by the
# older pip on 22.04, so the image keeps building across all releases.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN pip3 install setuptools --upgrade
RUN pip3 install jupyterlab notebook ipywidgets jupyter-server-proxy

COPY etc /etc/

ENV JUPYTER_PORT 8080

EXPOSE $JUPYTER_PORT
LABEL frp.$JUPYTER_PORT="http"

