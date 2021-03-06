FROM ruby:2.6-alpine

RUN apk update
RUN apk update && apk add --virtual build-dependencies build-base git openssl
RUN rm -rf /var/cache/apk/*

RUN mkdir -p /src/follower-syncer
WORKDIR /src/follower-syncer

COPY ./ /src/follower-syncer
RUN bundle install
