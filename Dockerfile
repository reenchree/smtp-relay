FROM ruby:4.0.7-alpine3.24@sha256:1ca7cb33e970630d571e0da6140e0bc925faec8f1f8f51f9f2cdf5e5f5eed7c9 AS build
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN apk add --no-cache build-base \
 && bundle config set without test \
 && bundle config set frozen true \
 && bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

FROM ruby:4.0.7-alpine3.24@sha256:1ca7cb33e970630d571e0da6140e0bc925faec8f1f8f51f9f2cdf5e5f5eed7c9
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY lib lib
COPY bin bin
USER 65534:65534
EXPOSE 2525 9090
ENTRYPOINT ["bundle", "exec", "ruby", "/app/bin/relay"]
