FROM opensuse/tumbleweed

RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y \
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
