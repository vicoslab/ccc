ARG ROOT_IMAGE
FROM ${ROOT_IMAGE}
LABEL maintainer "Luka Cehovin Zajc <luka.cehovin@fri.uni-lj.si>"

# Install jupyter into a dedicated virtualenv instead of the system Python.
# Ubuntu 24.04 (noble, Python 3.12) marks the system environment as
# externally-managed (PEP 668), so a system-wide `pip install` aborts with
# "error: externally-managed-environment". A venv sidesteps this and works
# identically on older releases (22.04/20.04), keeping the image portable.
ENV JUPYTER_VENV=/opt/jupyter-venv
RUN apt-get clean && \
    apt-get -o Acquire::Retries=3 update --fix-missing && \
    apt-get install -y python3 python3-venv && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv ${JUPYTER_VENV} && \
    ${JUPYTER_VENV}/bin/pip install --no-cache-dir --upgrade pip setuptools wheel && \
    ${JUPYTER_VENV}/bin/pip install --no-cache-dir jupyterlab notebook ipywidgets jupyter-server-proxy

# Put the venv first on PATH so `jupyter` resolves to it for the runit service
# and the setup hook. Also symlink the launchers into /usr/local/bin (always on
# PATH, including non-login SSH sessions that don't inherit this ENV); the venv
# entrypoint scripts use absolute shebangs, so the symlinks resolve correctly.
ENV PATH=${JUPYTER_VENV}/bin:$PATH
RUN for bin in ${JUPYTER_VENV}/bin/jupyter*; do \
        ln -sf "$bin" /usr/local/bin/"$(basename "$bin")"; \
    done

COPY etc /etc/

ENV JUPYTER_PORT 8080

EXPOSE $JUPYTER_PORT
LABEL frp.$JUPYTER_PORT="http"

