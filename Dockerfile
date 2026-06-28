# Written with assistance from Google Gemini

# Use Ubuntu 22.04 (Jammy Jellyfish) as the base image
FROM ubuntu:22.04

# Set DEBIAN_FRONTEND to noninteractive to avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install System Dependencies, Pandoc, Git LFS, and Google Chrome
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    software-properties-common wget unzip gnupg ca-certificates locales \
    pandoc git git-lfs \
    libudunits2-dev libmysqlclient-dev libcurl4-openssl-dev libsodium-dev \
    libgdal-dev libgeos-dev libproj-dev libssl-dev libxml2-dev zlib1g-dev \
    libjq-dev libprotobuf-dev protobuf-compiler cmake libfontconfig1-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev libwebp-dev \
    libharfbuzz-dev libfribidi-dev libgit2-dev libssh2-1-dev && \
    wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
    apt-get install -y --no-install-recommends ./google-chrome-stable_current_amd64.deb && \
    rm ./google-chrome-stable_current_amd64.deb && \
    git lfs install && \
    rm -rf /var/lib/apt/lists/*

# Configure locale to support UTF-8
RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Add CRAN repo for R 4.x
RUN wget -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc | tee -a /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc && \
    add-apt-repository "deb https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/"

# Install R
RUN apt-get update && \
    apt-get install -y r-base r-base-dev r-recommended && \
    rm -rf /var/lib/apt/lists/*

# Create a Chrome Wrapper Script
# pagedown ignores CHROMOTE_EXTRA_ARGS, so Chrome crashes immediately in Docker without sandboxing.
# This wrapper intercepts calls to Chrome and forces the required Docker flags on every execution.
RUN echo '#!/bin/bash\nexec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage "$@"' > /usr/local/bin/google-chrome && \
    chmod +x /usr/local/bin/google-chrome && \
    echo 'CHROMOTE_CHROME=/usr/local/bin/google-chrome' >> /etc/R/Renviron.site

# EJAM version: this ARG is the ONE place that sets which tagged EJAM release is installed.
# Override at build time without editing this file, e.g.:
#   docker build --build-arg EJAM_VERSION=v3.2024.0 .
# A CI build can supply it from a repo variable (see README "Choosing the EJAM version").
ARG EJAM_VERSION=v3.2022.0
# Record the version in the image so the running API can report which EJAM it was built with.
ENV EJAM_VERSION=${EJAM_VERSION}

# Clone EJAM into a fixed scratch dir (its name is arbitrary; it is removed after install).
RUN git clone --branch "${EJAM_VERSION}" --depth 1 https://github.com/Public-Environmental-Data-Partners/EJAM.git /EJAM_src && \
    cd /EJAM_src && \
    git lfs pull

# Install Dependencies & EJAM
RUN MAKEFLAGS="-j$(nproc)" R -e " \
    options(HTTPUserAgent = sprintf('R/%s R (%s)', getRversion(), paste(getRversion(), R.version\$platform, R.version\$arch, R.version\$os))); \
    \
    # Use 'latest' to get pre-compiled binaries \
    options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest')); \
    \
    # Pre-install key dependencies first \
    install.packages(c('remotes', 'plumber', 'sf', 'mapview', 'tidycensus', 'magrittr', 'openssl')); \
    \
    # Install a fixed fork of AOI \
    remotes::install_github('ericnost/AOI', upgrade='never'); \
    \
    # Install EJAM using upgrade='never' so it doesn't break the stable environment \
    remotes::install_local('/EJAM_src', dependencies=TRUE, upgrade='never', build=FALSE, INSTALL_opts=c('--preclean', '--no-multiarch', '--with-keep.source')); \
    \
    # Verify installation \
    if (!('EJAM' %in% installed.packages()[, 'Package'])) stop('EJAM FAILED TO INSTALL!'); \
    " && \
    # Clean up the cloned source directory \
    rm -rf /EJAM_src

# Reset frontend
ENV DEBIAN_FRONTEND=dialog

# Application setup
COPY / /
EXPOSE 8080
ENTRYPOINT ["Rscript", "main.r"]