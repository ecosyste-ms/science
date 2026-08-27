FROM ruby:4.0.6-alpine

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

ARG BRIEF_VERSION=0.12.1
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
 && wget -qO- "https://github.com/git-pkgs/brief/releases/download/v${BRIEF_VERSION}/brief_${BRIEF_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin brief \
 && brief --version

ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY . $APP_ROOT

RUN RAILS_ENV=production bundle exec rake assets:precompile

CMD ["bin/docker-start"]
