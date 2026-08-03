FROM opensuse/tumbleweed

# Align container with current TW repos before installing extras (Hub image lag).
RUN zypper --non-interactive refresh && \
    zypper --non-interactive dup -y && \
    zypper --non-interactive install --allow-downgrade -y \
      curl wget rsync git \
      e2fsprogs dosfstools mtools zip unzip \
      util-linux gawk \
      dracut grub2 \
      android-tools \
      xz gzip cpio kmod \
      which hostname python3 \
    && zypper clean -a

WORKDIR /build
COPY . /build/
RUN chmod +x build-image.sh

ENTRYPOINT ["/bin/bash", "./build-image.sh"]
