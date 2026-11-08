FROM golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS brief-notebooks-build

ARG BRIEF_REVISION=5ae39885f9f39b82be60851103d2a0e35d33ca82
RUN CGO_ENABLED=0 GOBIN=/out go install github.com/git-pkgs/brief/cmd/brief@${BRIEF_REVISION} \
 && /out/brief --version

FROM scratch AS brief-notebooks
COPY --from=brief-notebooks-build /out/brief /brief-notebooks

FROM ruby:4.0.9-alpine

ENV APP_ROOT=/usr/src/app
ENV DATABASE_PORT=5432
ENV PIP_BREAK_SYSTEM_PACKAGES=1
WORKDIR $APP_ROOT

COPY Gemfile Gemfile.lock .ruby-version $APP_ROOT/

RUN apk add --no-cache \
    build-base \
    netcat-openbsd \
    git \
    tzdata \
    curl-dev \
    libc6-compat \
    tar \
    libarchive-tools \
    icu-dev \
    cmake \
    perl \
    libidn-dev \
    py-pip \
    nodejs \
    npm \
    yaml-dev \
    libffi-dev \
    jemalloc \
 && gem update --system \
 && gem install bundler foreman \
 && bundle config set without 'test development' \
 && bundle install --jobs 8 \
 && pip install docutils \
 && npm install -g repomix

ARG BRIEF_VERSION=0.14.2
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
 && wget -qO- "https://github.com/git-pkgs/brief/releases/download/v${BRIEF_VERSION}/brief_${BRIEF_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin brief \
 && brief --version

ARG SCC_VERSION=4.1.0
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') \
 && case "$ARCH" in \
      x86_64) SCC_SHA256=c7328436d3027f4357d3d7853f7dc3ac2bbcb4ca08f1adad91a27c593884079b ;; \
      arm64) SCC_SHA256=6e0d2a1f8d3540ba7df185477dec40bb7340f1b214bfd303147de5cad2bd7b8b ;; \
      *) exit 1 ;; \
    esac \
 && wget -qO /tmp/scc.tar.gz "https://github.com/boyter/scc/releases/download/v${SCC_VERSION}/scc_Linux_${ARCH}.tar.gz" \
 && echo "${SCC_SHA256}  /tmp/scc.tar.gz" | sha256sum -c - \
 && tar -xz -f /tmp/scc.tar.gz -C /usr/local/bin scc \
 && rm /tmp/scc.tar.gz \
 && scc --version

ARG SWHID_VERSION=0.1.0
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
 && wget -qO- "https://github.com/andrew/swhid-go/releases/download/v${SWHID_VERSION}/swhid_${SWHID_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin swhid \
 && swhid --version

COPY --from=brief-notebooks /brief-notebooks /usr/local/bin/brief-notebooks

ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY . $APP_ROOT

RUN RAILS_ENV=production bundle exec rake assets:precompile

CMD ["bin/docker-start"]
