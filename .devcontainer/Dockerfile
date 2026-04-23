FROM mcr.microsoft.com/playwright:v1.58.2-noble

# Build dependencies required by kerl (used by erlang-asdf feature) to compile OTP.
# See https://github.com/asdf-vm/asdf-erlang#before-asdf-install
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      autoconf \
      m4 \
      libncurses-dev \
      libssl-dev \
      libssh-dev \
      unixodbc-dev \
      libgmp-dev \
      libffi-dev \
      libyaml-dev \
      libreadline-dev \
      xsltproc \
      fop \
      libxml2-utils \
      curl \
      git \
 && rm -rf /var/lib/apt/lists/*
