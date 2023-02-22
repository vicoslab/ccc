#!/bin/bash -e

wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh && \
/bin/bash ~/miniconda.sh -b -p ~/conda && \
rm ~/miniconda.sh && \
~/conda/bin/conda clean -tipy && \
echo ". ~/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
echo "conda activate base" >> ~/.bashrc && \
find ~/conda/ -follow -type f -name '*.a' -delete && \
find ~/conda/ -follow -type f -name '*.js.map' -delete && \
~/conda/bin/conda clean -afy && ~/conda/bin/conda install mamba -n base -c conda-forge -y

