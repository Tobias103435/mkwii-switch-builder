# Afgeleide van devkitpro/devkita64 met de gereedschappen die de Deko3D-route
# (Dawn + libuam) en de WiiCompiled-vertaling nodig hebben.
FROM devkitpro/devkita64
USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      meson bison flex python3-mako python3-pip \
      ca-certificates curl unzip ccache \
 && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
 && bash /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/local/dotnet \
 && ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet \
 && rm /tmp/dotnet-install.sh

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_ROOT=/usr/local/dotnet

RUN meson --version && bison --version | head -1 && flex --version && dotnet --version
